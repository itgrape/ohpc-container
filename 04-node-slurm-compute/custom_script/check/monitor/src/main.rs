use std::collections::{HashMap, VecDeque};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use chrono::Local;
use log::{error, info, warn};
use serde::{Deserialize, Serialize};
use tokio::fs::{self, OpenOptions};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::Mutex;
use tokio::time::{self, Instant};

// ============================================================================
// 常量定义 (Constants)
// ============================================================================
const SOCKET_PATH: &str = "/var/run/node_monitor.sock";

// 心跳超时时间 (秒)
const HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(180);

// 心跳检测间隔 (秒)
const HEARTBEAT_CHECK_INTERVAL: Duration = Duration::from_secs(60);

// 利用率阈值 (百分比)
const GPU_UTILIZATION_THRESHOLD: f64 = 70.0;
const GPU_MEMORY_UTILIZATION_THRESHOLD: f64 = 30.0;
const CPU_UTILIZATION_THRESHOLD: f64 = 50.0;

// 丢弃前多少个数据 (个) (用于给用户加载模型或单纯墨迹的时间)
const BUFFER_PERIOD: usize = 30;

// ============================================================================
// 数据结构定义 (Data Structures)
// ============================================================================

#[derive(Serialize, Deserialize, Debug)]
#[serde(tag = "type", content = "payload")]
enum Message {
    #[serde(rename = "REGISTER")]
    Register(RegisterPayload),
    #[serde(rename = "METRICS")]
    Metrics(MetricsPayload),
    #[serde(rename = "CANCEL")]
    Cancel(CancelPayload),
}

#[derive(Serialize, Deserialize, Debug)]
struct RegisterPayload {
    job_id: String,
    gpu_monitor_count: usize,
    cpu_monitor_count: usize,
    log_path: PathBuf,
}

#[derive(Serialize, Deserialize, Debug)]
struct MetricsPayload {
    job_id: String,
    gpu_utilization: f64,
    gpu_memory_utilization: f64,
    cpu_utilization: f64,
}

#[derive(Serialize, Deserialize, Debug)]
struct CancelPayload {
    job_id: String,
}

struct JobInfo {
    last_heartbeat: Instant,
    gpu_monitor_count: usize,
    cpu_monitor_count: usize,
    gpu_utilizations: VecDeque<f64>,
    gpu_memory_utilizations: VecDeque<f64>,
    cpu_utilizations: VecDeque<f64>,
    metrics_received: usize,
    log_path: PathBuf,
}

struct JobTracker {
    jobs: HashMap<String, JobInfo>,
}

impl JobTracker {
    fn new() -> Self {
        Self { jobs: HashMap::new() }
    }
    fn remove_job(&mut self, job_id: &str) -> Option<JobInfo> {
        self.jobs.remove(job_id)
    }
}

// ============================================================================
// 主函数 (Main Function)
// ============================================================================
type SharedTracker = Arc<Mutex<JobTracker>>;

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .format(|buf, record| {
            writeln!(
                buf,
                "{} [{}] - {}",
                Local::now().format("%Y-%m-%dT%H:%M:%S"),
                record.level(),
                record.args()
            )
        })
        .init();

    info!("Starting Node Monitor Daemon...");

    setup_socket(SOCKET_PATH).await?;

    let tracker = Arc::new(Mutex::new(JobTracker::new()));
    let tracker_clone_for_checker = tracker.clone();
    tokio::spawn(run_status_checker(tracker_clone_for_checker));

    let listener =
        UnixListener::bind(SOCKET_PATH).with_context(|| format!("Failed to listen on unix socket {}", SOCKET_PATH))?;

    let perms = PermissionsExt::from_mode(0o777);
    fs::set_permissions(SOCKET_PATH, perms).await?;
    info!("Set socket {} permissions to 0777", SOCKET_PATH);

    info!("Listening on {}", SOCKET_PATH);
    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                let tracker_clone_for_handler = tracker.clone();
                tokio::spawn(handle_connection(stream, tracker_clone_for_handler));
            }
            Err(e) => {
                error!("Failed to accept connection: {}", e);
            }
        }
    }
}

async fn setup_socket(path_str: &str) -> Result<()> {
    let path = Path::new(path_str);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .await
            .with_context(|| format!("Failed to create socket directory: {:?}", parent))?;
    }
    if fs::metadata(path).await.is_ok() {
        fs::remove_file(path)
            .await
            .with_context(|| format!("Failed to remove existing socket: {:?}", path))?;
    }
    Ok(())
}

// ============================================================================
// 处理客户端连接函数 (Handle Client Connection Function)
// ============================================================================

async fn handle_connection(stream: UnixStream, tracker: SharedTracker) {
    info!("Accepted new connection");
    let mut reader = BufReader::new(stream);
    let mut line = String::new();

    loop {
        match reader.read_line(&mut line).await {
            Ok(0) => {
                info!("Connection closed by peer");
                break;
            }
            Ok(_) => {
                let trimmed_line = line.trim();
                if trimmed_line.is_empty() {
                    line.clear();
                    continue;
                }

                let should_break = match serde_json::from_str::<Message>(trimmed_line) {
                    Ok(Message::Register(payload)) => {
                        handle_register(payload, tracker.clone(), &mut reader.get_mut()).await;
                        false // Continue connection
                    }
                    Ok(Message::Metrics(payload)) => {
                        if let Some((job_id, reason)) = handle_metrics(payload, tracker.clone()).await {
                            kill_slurm_job(&job_id, &reason).await;
                            info!("Killed job {} and closing its connection.", job_id);
                            true // Break connection
                        } else {
                            false // Continue connection
                        }
                    }
                    Ok(Message::Cancel(payload)) => {
                        handle_cancel(payload, tracker.clone()).await;
                        true // Break connection after cancel
                    }
                    Err(e) => {
                        error!("Failed to parse message: {}. Raw: '{}'", e, trimmed_line);
                        false // Continue, wait for next message
                    }
                };

                if should_break {
                    break;
                }

                line.clear();
            }
            Err(e) => {
                error!("Failed to read from stream: {}", e);
                break;
            }
        }
    }
    info!("Connection handler finished.");
}

async fn handle_register(payload: RegisterPayload, tracker: SharedTracker, stream: &mut UnixStream) {
    let job_id = payload.job_id;
    info!(
        "Registering job {} with GPU-Count: {}, CPU-Count: {}",
        job_id, payload.gpu_monitor_count, payload.cpu_monitor_count
    );

    if let Some(parent) = payload.log_path.parent() {
        if let Err(e) = fs::create_dir_all(parent).await {
            error!("Failed to create log directory for job {}: {}", job_id, e);
            return;
        }
    }
    if OpenOptions::new()
        .create(true)
        .append(true)
        .open(&payload.log_path)
        .await
        .is_err()
    {
        error!("Failed to open or create log file for job {}", job_id);
        return;
    }

    let job_info = JobInfo {
        last_heartbeat: Instant::now(),
        gpu_monitor_count: payload.gpu_monitor_count,
        cpu_monitor_count: payload.cpu_monitor_count,
        gpu_utilizations: VecDeque::with_capacity(payload.gpu_monitor_count),
        gpu_memory_utilizations: VecDeque::with_capacity(payload.gpu_monitor_count),
        cpu_utilizations: VecDeque::with_capacity(payload.cpu_monitor_count),
        metrics_received: 0,
        log_path: payload.log_path,
    };

    tracker.lock().await.jobs.insert(job_id.clone(), job_info);

    if let Err(e) = stream.write_all(b"{\"status\": \"ok\"}\n").await {
        error!("Error writing OK status to client for job {}: {}", job_id, e);
    }
}

async fn handle_cancel(payload: CancelPayload, tracker: SharedTracker) {
    let job_id = payload.job_id;
    info!("Received cancellation request for job {}", &job_id);
    let mut tracker_lock = tracker.lock().await;

    if let Some(removed_job) = tracker_lock.remove_job(&job_id) {
        let reason = "Job cancelled by user request";
        log_to_job_file(&removed_job.log_path, reason).await;
        info!("Successfully cancelled and removed job {}.", &job_id);
    } else {
        warn!(
            "Received cancellation for an unknown or already removed job: {}",
            &job_id
        );
    }
}

async fn handle_metrics(payload: MetricsPayload, tracker: SharedTracker) -> Option<(String, String)> {
    let job_id = payload.job_id;
    let mut tracker_lock = tracker.lock().await;

    let job = if let Some(j) = tracker_lock.jobs.get_mut(&job_id) {
        j
    } else {
        warn!("Received metrics for unknown or already removed job: {}", job_id);
        return None;
    };

    job.last_heartbeat = Instant::now();
    job.metrics_received += 1;
    info!(
        "Metrics received: JobID={}, CPU={:.1}%, GPU_Util={:.1}%, GPU_Mem={:.1}%",
        job_id, payload.cpu_utilization, payload.gpu_utilization, payload.gpu_memory_utilization
    );

    if job.metrics_received <= BUFFER_PERIOD {
        info!(
            "Discarding metrics during buffer period for job {} (Received: {}, Buffer: {})",
            job_id, job.metrics_received, BUFFER_PERIOD
        );
        return None;
    }

    let mut reason: Option<String> = None;

    if job.gpu_monitor_count > 0 && reason.is_none() {
        job.gpu_utilizations.push_back(payload.gpu_utilization);
        if job.gpu_utilizations.len() > job.gpu_monitor_count {
            job.gpu_utilizations.pop_front();
        }
        if job.gpu_utilizations.len() == job.gpu_monitor_count {
            let avg = calculate_average(&job.gpu_utilizations);
            info!("Job {}, Average GPU Utilization: {:.2}%", job_id, avg);
            if avg < GPU_UTILIZATION_THRESHOLD {
                reason = Some(format!(
                    "Average GPU utilization {:.2}% is below threshold {:.0}%",
                    avg, GPU_UTILIZATION_THRESHOLD
                ));
            }
        }
    }

    if job.gpu_monitor_count > 0 && reason.is_none() {
        job.gpu_memory_utilizations.push_back(payload.gpu_memory_utilization);
        if job.gpu_memory_utilizations.len() > job.gpu_monitor_count {
            job.gpu_memory_utilizations.pop_front();
        }
        if job.gpu_memory_utilizations.len() == job.gpu_monitor_count {
            let avg = calculate_average(&job.gpu_memory_utilizations);
            info!("Job {}, Average GPU Memory Utilization: {:.2}%", job_id, avg);
            if avg < GPU_MEMORY_UTILIZATION_THRESHOLD {
                reason = Some(format!(
                    "Average GPU Memory utilization {:.2}% is below threshold {:.0}%",
                    avg, GPU_MEMORY_UTILIZATION_THRESHOLD
                ));
            }
        }
    }

    if job.cpu_monitor_count > 0 && reason.is_none() {
        job.cpu_utilizations.push_back(payload.cpu_utilization);
        if job.cpu_utilizations.len() > job.cpu_monitor_count {
            job.cpu_utilizations.pop_front();
        }
        if job.cpu_utilizations.len() == job.cpu_monitor_count {
            let avg = calculate_average(&job.cpu_utilizations);
            info!("Job {}, Average CPU Utilization: {:.2}%", job_id, avg);
            if avg < CPU_UTILIZATION_THRESHOLD {
                reason = Some(format!(
                    "Average CPU utilization {:.2}% is below threshold {:.0}%",
                    avg, CPU_UTILIZATION_THRESHOLD
                ));
            }
        }
    }

    if let Some(r) = reason {
        if let Some(removed_job) = tracker_lock.remove_job(&job_id) {
            log_to_job_file(
                &removed_job.log_path,
                &format!("Removing job {}. Reason: {}", job_id, r),
            )
            .await;
        }
        return Some((job_id.clone(), r));
    }

    None
}

// ============================================================================
// 心跳检测 (Heartbeat Check)
// ============================================================================

async fn run_status_checker(tracker: SharedTracker) {
    let mut interval = time::interval(HEARTBEAT_CHECK_INTERVAL);
    loop {
        interval.tick().await;

        let mut jobs_to_kill = Vec::new();
        let mut tracker_lock = tracker.lock().await;

        tracker_lock.jobs.retain(|job_id, job| {
            if job.last_heartbeat.elapsed() > HEARTBEAT_TIMEOUT {
                let reason = format!(
                    "Heartbeat Timeout. Last heartbeat was {:.0} seconds ago.",
                    job.last_heartbeat.elapsed().as_secs_f64()
                );
                jobs_to_kill.push((job_id.clone(), reason, job.log_path.clone()));
                return false; // Remove from map
            }
            true // Keep in map
        });

        for (_, reason, log_path) in &jobs_to_kill {
            log_to_job_file(log_path, reason).await;
        }
        drop(tracker_lock);

        if !jobs_to_kill.is_empty() {
            info!("Found {} jobs to kill due to timeout.", jobs_to_kill.len());
            for (job_id, reason, _) in jobs_to_kill {
                kill_slurm_job(&job_id, &reason).await;
            }
        }
    }
}

// ============================================================================
// 辅助函数 (Helper Functions)
// ============================================================================

async fn kill_slurm_job(job_id: &str, reason: &str) {
    info!("[KILL] Executing 'scancel' for job {}, Reason: {}", job_id, reason);

    let mut cmd = tokio::process::Command::new("scancel");
    cmd.arg(job_id);
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());

    match cmd.spawn() {
        // **FIX**: Removed `mut` from `child` as it's not needed.
        Ok(child) => match child.wait_with_output().await {
            Ok(output) => {
                if output.status.success() {
                    info!("Successfully ran scancel for job {}.", job_id);
                } else {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    error!(
                        "'scancel' for job {} failed with status {}: {}",
                        job_id, output.status, stderr
                    );
                }
            }
            Err(e) => error!("Error waiting for 'scancel' command for job {}: {}", job_id, e),
        },
        Err(e) => error!("Failed to spawn 'scancel' for job {}: {}", job_id, e),
    }
}

fn calculate_average(data: &VecDeque<f64>) -> f64 {
    if data.is_empty() {
        return 0.0;
    }
    let sum: f64 = data.iter().sum();
    sum / data.len() as f64
}

async fn log_to_job_file(log_path: &Path, message: &str) {
    match OpenOptions::new().append(true).create(true).open(log_path).await {
        Ok(mut file) => {
            let timestamp = Local::now().format("%Y-%m-%dT%H:%M:%S");
            let log_line = format!("[{}] JOB-LOG: {}\n", timestamp, message);
            if let Err(e) = file.write_all(log_line.as_bytes()).await {
                error!("Failed to write to job log file {:?}: {}", log_path, e);
            }
        }
        Err(e) => {
            error!("Failed to open job log file {:?} for writing: {}", log_path, e);
        }
    }
}
