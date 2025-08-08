use std::env;
use std::path::PathBuf;
use std::process::Command;
use std::str;
use std::time::Duration;

use anyhow::{Context, Result, anyhow};
use clap::Parser;
use log::{error, info, warn};
use serde::{Deserialize, Serialize};
use sysinfo::System;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

// ============================================================================
// 常量定义 (Constants)
// ============================================================================
const SOCKET_PATH: &str = "/var/run/node_monitor.sock";

// 发送监控信息间隔
const METRICS_SEND_INTERVAL: Duration = Duration::from_secs(60);

// 各种卡取样次数
const RTX_5090_CHECK_COUNT: i32 = 20;
const RTX_A6000_CHECK_COUNT: i32 = 20;
const RTX_4090_CHECK_COUNT: i32 = 20;
const RTX_3090_CHECK_COUNT: i32 = 60;
const RTX_A10_CHECK_COUNT: i32 = 60;

// 默认取样次数
const DEFAULT_GPU_CHECK_COUNT: i32 = 60;
const DEFAULT_CPU_CHECK_COUNT: i32 = 60;

// 对无限次取样的定义 (约 100 天)
const INFINITE_CHECK_COUNT: i32 = 144000;

// ============================================================================
// 数据结构定义 (Data Structures)
// ============================================================================

// 使用与服务端一致的 enum，更加类型安全和易于使用
#[derive(Serialize, Debug)]
#[serde(tag = "type", content = "payload")]
enum Message {
    #[serde(rename = "REGISTER")]
    Register(RegisterPayload),
    #[serde(rename = "METRICS")]
    Metrics(MetricsPayload),
    #[serde(rename = "CANCEL")]
    Cancel(CancelPayload),
}

#[derive(Serialize, Debug)]
struct RegisterPayload {
    job_id: String,
    gpu_monitor_count: i32,
    cpu_monitor_count: i32,
    log_path: PathBuf,
}

#[derive(Serialize, Debug)]
struct MetricsPayload {
    job_id: String,
    gpu_utilization: f64,
    gpu_memory_utilization: f64,
    cpu_utilization: f64,
}

#[derive(Serialize, Debug)]
struct CancelPayload {
    job_id: String,
}

#[derive(Deserialize, Debug)]
struct DaemonResponse {
    status: String,
}

// ============================================================================
// 命令行接口定义 (Command-Line Interface)
// ============================================================================

#[derive(Parser, Debug)]
#[command(author, version, about = "Slurm job monitor client", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(clap::Subcommand, Debug)]
enum Commands {
    Register {
        #[arg(value_name = "LOG_PATH")]
        log_path: PathBuf,
    },
    Monitor,
    Cancel,
}

// ============================================================================
// 主函数 (Main Function)
// ============================================================================

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let cli = Cli::parse();

    let job_id = env::var("SLURM_JOB_ID")
        .context("SLURM_JOB_ID environment variable not set. This must be run inside a Slurm job.")?;

    match cli.command {
        Commands::Register { log_path } => register(&job_id, log_path).await?,
        Commands::Monitor => monitor(&job_id).await?,
        Commands::Cancel => cancel(&job_id).await?,
    }

    Ok(())
}

// ============================================================================
// 命令处理函数 (Command Handlers)
// ============================================================================

async fn register(job_id: &str, log_path: PathBuf) -> Result<()> {
    let job_partition = env::var("SLURM_JOB_PARTITION").unwrap_or_default();
    let lower_job_partition = job_partition.to_lowercase();

    let (gpu_monitor_count, cpu_monitor_count) = if lower_job_partition.contains("debug") {
        info!(
            "Detected debug partition: {}. Setting CPU and GPU check count to {}.",
            job_partition, INFINITE_CHECK_COUNT
        );
        (INFINITE_CHECK_COUNT, INFINITE_CHECK_COUNT)
    } else if lower_job_partition.contains("gpu") {
        let gpu_count = determine_gpu_check_count()?;
        info!(
            "Dynamically determined GPU monitoring count: {}, CPU monitoring count: {}",
            gpu_count, INFINITE_CHECK_COUNT
        );
        (gpu_count, INFINITE_CHECK_COUNT)
    } else {
        let gpu_count = determine_gpu_check_count()?;
        info!(
            "Dynamically determined GPU monitoring count: {}, CPU monitoring count: {}",
            gpu_count, DEFAULT_CPU_CHECK_COUNT
        );
        (gpu_count, DEFAULT_CPU_CHECK_COUNT)
    };

    // 创建消息
    let reg_payload = RegisterPayload {
        job_id: job_id.to_string(),
        gpu_monitor_count,
        cpu_monitor_count,
        log_path: log_path.clone(),
    };
    let msg = Message::Register(reg_payload);

    // 序列化消息并添加换行符
    let mut msg_bytes = serde_json::to_vec(&msg)?;
    msg_bytes.push(b'\n');

    let stream = UnixStream::connect(SOCKET_PATH)
        .await
        .context("Failed to connect to node monitor daemon")?;

    // 使用 BufReader 来读取带缓冲的行
    let mut reader = BufReader::new(stream);

    reader.write_all(&msg_bytes).await?;

    // 使用 read_line 读取响应
    let mut response_buf = String::new();
    reader
        .read_line(&mut response_buf)
        .await
        .context("Failed to read response from daemon")?;

    info!("Received response from daemon: {}", response_buf.trim());
    let resp: DaemonResponse = serde_json::from_str(&response_buf).context("Failed to decode daemon response")?;

    if resp.status != "ok" {
        return Err(anyhow!("Registration failed. Daemon response: {:?}", resp));
    }

    info!(
        "Job {} registered successfully. GPU_Count={}, CPU_Count={}, Log file: {}",
        job_id,
        gpu_monitor_count,
        cpu_monitor_count,
        log_path.display()
    );

    Ok(())
}

async fn monitor(job_id: &str) -> Result<()> {
    write_pid_file(job_id).context("Failed to write PID file")?;

    let mut stream = UnixStream::connect(SOCKET_PATH)
        .await
        .context("Monitor failed to connect to daemon")?;

    let mut interval = tokio::time::interval(METRICS_SEND_INTERVAL);
    let mut sys = System::new();

    info!("Starting monitoring for job {job_id}...");

    loop {
        interval.tick().await;

        let gpu_util = get_gpu_utilization().unwrap_or_else(|e| {
            warn!("Could not get GPU utilization: {}", e);
            0.0
        });
        let gpu_mem_util = get_gpu_memory_utilization().unwrap_or_else(|e| {
            warn!("Could not get GPU memory utilization: {}", e);
            0.0
        });
        let cpu_util = get_cpu_utilization(&mut sys).unwrap_or_else(|e| {
            warn!("Could not get CPU utilization: {}", e);
            0.0
        });

        // 直接创建 MetricsPayload 和 Message enum
        let metrics_payload = MetricsPayload {
            job_id: job_id.to_string(),
            gpu_utilization: gpu_util,
            gpu_memory_utilization: gpu_mem_util,
            cpu_utilization: cpu_util,
        };
        let msg = Message::Metrics(metrics_payload);

        // 序列化消息并添加换行符
        let mut msg_bytes = serde_json::to_vec(&msg)?;
        msg_bytes.push(b'\n');

        if let Err(e) = stream.write_all(&msg_bytes).await {
            error!(
                "Failed to send metrics, daemon may have terminated the job or is down. Exiting. Error: {}",
                e
            );
            break;
        }

        info!(
            "Sent metrics: GPU_Util={:.1}%, GPU_Mem={:.1}%, CPU_Util={:.1}%",
            gpu_util, gpu_mem_util, cpu_util
        );
    }

    Ok(())
}

async fn cancel(job_id: &str) -> Result<()> {
    let cancel_payload = CancelPayload {
        job_id: job_id.to_string(),
    };
    let msg = Message::Cancel(cancel_payload);

    // 序列化消息并添加换行符
    let mut msg_bytes = serde_json::to_vec(&msg)?;
    msg_bytes.push(b'\n');

    match UnixStream::connect(SOCKET_PATH).await {
        Ok(mut stream) => {
            if let Err(e) = stream.write_all(&msg_bytes).await {
                warn!("Failed to send cancellation request for job {}: {}", job_id, e);
            } else {
                info!("Successfully sent cancellation request for job {}.", job_id);
            }
        }
        Err(e) => {
            warn!(
                "Could not connect to node monitor daemon to cancel job {}: {}. The daemon might be down.",
                job_id, e
            );
        }
    }
    Ok(())
}

// ============================================================================
// 辅助函数 (Helper Functions)
// ============================================================================

fn run_command(program: &str, args: &[&str]) -> Result<String> {
    let output = Command::new(program)
        .args(args)
        .output()
        .with_context(|| format!("Failed to execute '{}'", program))?;

    if !output.status.success() {
        let stderr = str::from_utf8(&output.stderr).unwrap_or("Non-UTF8 error output");
        return Err(anyhow!(
            "'{}' command failed with status {}: {}",
            program,
            output.status,
            stderr
        ));
    }

    Ok(str::from_utf8(&output.stdout)?.trim().to_string())
}

fn get_gpu_check_count(gpu_name: &str) -> i32 {
    let upper_name = gpu_name.to_uppercase();
    match upper_name {
        s if s.contains("5090") => RTX_5090_CHECK_COUNT,
        s if s.contains("A6000") => RTX_A6000_CHECK_COUNT,
        s if s.contains("4090") => RTX_4090_CHECK_COUNT,
        s if s.contains("3090") => RTX_3090_CHECK_COUNT,
        s if s.contains("A10") => RTX_A10_CHECK_COUNT,
        _ => DEFAULT_GPU_CHECK_COUNT,
    }
}

fn determine_gpu_check_count() -> Result<i32> {
    let output = match run_command(
        "nvidia-smi",
        &["--query-gpu=index,name", "--format=csv,noheader,nounits"],
    ) {
        Ok(out) => out,
        Err(e) => {
            warn!(
                "'nvidia-smi' command failed: {}. Assuming no GPUs or driver issue. Setting GPU check count to infinite.",
                e
            );
            return Ok(INFINITE_CHECK_COUNT);
        }
    };

    if output.is_empty() {
        info!("No GPUs detected by nvidia-smi. Setting GPU check count to infinite.");
        return Ok(INFINITE_CHECK_COUNT);
    }

    let min_check_count = output
        .lines()
        .filter_map(|line| line.split(',').nth(1))
        .map(|gpu_name| {
            let count = get_gpu_check_count(gpu_name.trim());
            info!("  - Detected GPU: {} -> Check Count: {}", gpu_name.trim(), count);
            count
        })
        .min()
        .unwrap_or(DEFAULT_GPU_CHECK_COUNT);

    info!("Setting monitoring count to: {}", min_check_count);
    Ok(min_check_count)
}

fn get_gpu_utilization() -> Result<f64> {
    let output = run_command(
        "nvidia-smi",
        &["--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"],
    )?;

    let utils: Vec<f64> = output
        .lines()
        .filter_map(|line| line.trim().parse::<f64>().ok())
        .collect();

    if utils.is_empty() {
        return Err(anyhow!("No valid GPU utilization data found"));
    }

    Ok(utils.iter().sum::<f64>() / utils.len() as f64)
}

fn get_gpu_memory_utilization() -> Result<f64> {
    let output = run_command(
        "nvidia-smi",
        &["--query-gpu=memory.used,memory.total", "--format=csv,noheader,nounits"],
    )?;

    let percentages: Vec<f64> = output
        .lines()
        .filter_map(|line| {
            let parts: Vec<&str> = line.split(',').map(str::trim).collect();
            if parts.len() == 2 {
                let used = parts[0].parse::<f64>().ok()?;
                let total = parts[1].parse::<f64>().ok()?;
                if total > 0.0 {
                    return Some((used / total) * 100.0);
                }
            }
            None
        })
        .collect();

    if percentages.is_empty() {
        return Err(anyhow!("No valid GPU memory usage data found"));
    }

    Ok(percentages.iter().sum::<f64>() / percentages.len() as f64)
}

fn get_cpu_utilization(sys: &mut System) -> Result<f64> {
    sys.refresh_cpu_all();
    std::thread::sleep(Duration::from_secs(1));
    sys.refresh_cpu_all();

    Ok(sys.global_cpu_usage() as f64)
}

fn write_pid_file(job_id: &str) -> Result<()> {
    let pid = std::process::id();
    let home_dir = env::var("HOME").context("Failed to get HOME directory")?;
    let hostname = run_command("hostname", &[]).context("Failed to get hostname")?;

    let pid_dir = PathBuf::from(home_dir).join(".monitor");
    std::fs::create_dir_all(&pid_dir)
        .with_context(|| format!("Failed to create PID directory: {}", pid_dir.display()))?;

    let pid_file_path = pid_dir.join(format!("monitor-{}-{}.pid", job_id, hostname));

    std::fs::write(&pid_file_path, pid.to_string())
        .with_context(|| format!("Failed to write PID file: {}", pid_file_path.display()))?;

    info!("PID file written to {}", pid_file_path.display());
    Ok(())
}
