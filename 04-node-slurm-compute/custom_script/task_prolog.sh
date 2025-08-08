#!/bin/bash

NODE_HOSTNAME=$(hostname)

# 设置锁文件，防止程序多次执行
LOCK_DIR="/tmp/slurm_locks_${USER}"
mkdir -p "$LOCK_DIR"
PROLOG_LOCK_FILE="${LOCK_DIR}/prolog-${SLURM_JOB_ID}-${NODE_HOSTNAME}.lock"

(
    flock -n 200 || { echo "[Prolog on ${NODE_HOSTNAME}]: Another instance is already running. Exiting."; exit 0; }

    LOG_DIR="${HOME}/.slurm"
    MONITOR_DIR="${HOME}/.monitor"
    DROPBEAR_KEY_DIR="$HOME/.dropbear"

    mkdir -p "$MONITOR_DIR" "$LOG_DIR" "$DROPBEAR_KEY_DIR"


    # =======================================
    # ============= 监控程序系统 ==============
    # =======================================
    (
        HELPER_PATH="/usr/local/bin/job_helper"
        INFO_LOG_PATH="${LOG_DIR}/info-${SLURM_JOB_ID}.log"

        # --- 注册任务信息 ---
        $HELPER_PATH register $INFO_LOG_PATH
        if [ $? -ne 0 ]; then
            echo "[Prolog on ${NODE_HOSTNAME}] Error: Job registration with monitoring daemon failed. Aborting."
            exit 1
        fi
        echo "[Prolog on ${NODE_HOSTNAME}] Registration successful."

        # --- 监控进程交给 at 管理 ---
        AT_JOB_ID=$(echo "$HELPER_PATH monitor" | at now 2>&1 | grep "job" | awk '{print $2}' | tail -n 1)
        echo "[Prolog on ${NODE_HOSTNAME}] Monitor process scheduled with 'at' job ID: $AT_JOB_ID."

    ) >> "${MONITOR_DIR}/monitor-${SLURM_JOB_ID}-${NODE_HOSTNAME}.log" 2>&1




    # =======================================
    # =========== Dropbear 服务器 ============
    # =======================================
    (
        generate_random_port() {
            local port
            while true; do
                port=$((RANDOM % 10001 + 50000))  # 生成 50000 到 60000 之间的随机端口
                if ! netstat -tuln | grep -q ":$port "; then
                    echo "$port"
                    return
                fi
            done
        }

        LOGIN_NODE_ADDRESS="10.10.20.2"
        JOB_ID=$SLURM_JOB_ID
        LOGIN_NODE_ALIAS="Slurm-Login"

        COMPUTE_NODE_ALIAS="Job-${JOB_ID}-${NODE_HOSTNAME}"

        PORT=$(generate_random_port)
        PID_FILE="${HOME}/.dropbear/dropbear-${SLURM_JOB_ID}-${NODE_HOSTNAME}.pid"

        # --- Dropbear SSH Server Setup ---
        HOST_KEY="$DROPBEAR_KEY_DIR/dropbear_rsa_host_key"
        if [ ! -f "$HOST_KEY" ]; then
            dropbearkey -t rsa -f "$HOST_KEY"
        fi
        dropbear -r "$HOST_KEY" -p "$PORT" -P "$PID_FILE" -w -s


        echo "================================================================================"
        echo "--- SSH CONFIGURATION FOR NODE: ${NODE_HOSTNAME} ---"
        echo "--- User: ${USER} | Job ID: ${JOB_ID} ---"
        echo "================================================================================"

        cat << EOF

# Block for HPC Login Node (Jump Host)
Host ${LOGIN_NODE_ALIAS}
    HostName ${LOGIN_NODE_ADDRESS}
    User ${USER}
    IdentityFile ~/.ssh/id_rsa

# Block for your Job (Connect through the Login Node)
Host ${COMPUTE_NODE_ALIAS}
    HostName ${NODE_HOSTNAME}
    User ${USER}
    IdentityFile ~/.ssh/id_rsa
    Port ${PORT}
    ProxyJump ${LOGIN_NODE_ALIAS}
    ServerAliveInterval 60

EOF
        echo "================================================================================"
        echo ""

    ) >> "${LOG_DIR}/connect-${SLURM_JOB_ID}.log" 2>&1

) 200>"$PROLOG_LOCK_FILE"
# flock 会将文件描述符 200 指向锁文件，在括号内的命令执行期间保持锁定
# 当命令结束时，文件描述符关闭，锁被自动释放



exit 0