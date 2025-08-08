#!/bin/bash

NODE_HOSTNAME=$(hostname)

echo "[Epilog on ${NODE_HOSTNAME}] Cleaning up job processes..."

# =======================================
# =============== 注销任务 ===============
# =======================================
HELPER_PATH="/usr/local/bin/job_helper"
$HELPER_PATH cancel >> "${HOME}/.monitor/monitor-${SLURM_JOB_ID}-${NODE_HOSTNAME}.log" 2>&1

# =======================================
# ============= 清理监控进程 ==============
# =======================================
MONITOR_PID_FILE="${HOME}/.monitor/monitor-${SLURM_JOB_ID}-${NODE_HOSTNAME}.pid"

if [ -f "$MONITOR_PID_FILE" ]; then
    MONITOR_PID=$(cat "$MONITOR_PID_FILE")
    if [ -n "$MONITOR_PID" ] && ps -p "$MONITOR_PID" > /dev/null; then
        echo "[Epilog on ${NODE_HOSTNAME}] Stopping monitor process with PID ${MONITOR_PID}."
        kill "$MONITOR_PID"
        sleep 1
        # Force kill if it's still running
        if ps -p "$MONITOR_PID" > /dev/null; then
            kill -9 "$MONITOR_PID"
        fi
    fi
    rm -f "$MONITOR_PID_FILE"
else
    echo "[Epilog on ${NODE_HOSTNAME}] monitor PID file not found. Nothing to clean."
fi


# ========================================
# ========== 清理 Dropbear 进程 ===========
# ========================================
DROPBEAR_PID_FILE="${HOME}/.dropbear/dropbear-${SLURM_JOB_ID}-${NODE_HOSTNAME}.pid"

if [ -f "$DROPBEAR_PID_FILE" ]; then
    DROPBEAR_PID=$(cat "$DROPBEAR_PID_FILE")
    if [ -n "$DROPBEAR_PID" ] && ps -p "$DROPBEAR_PID" > /dev/null; then
        echo "[Epilog on ${NODE_HOSTNAME}] Stopping Dropbear process with PID ${DROPBEAR_PID}."
        kill "$DROPBEAR_PID"
        sleep 1
        # Force kill if it's still running
        if ps -p "$DROPBEAR_PID" > /dev/null; then
            kill -9 "$DROPBEAR_PID"
        fi
    fi
    rm -f "$DROPBEAR_PID_FILE"
else
    echo "[Epilog on ${NODE_HOSTNAME}] Dropbear PID file not found. Nothing to clean."
fi

echo "[Epilog on ${NODE_HOSTNAME}] Cleanup finished."

exit 0


# ========================================
# ============== 清理日志文件 ==============
# ========================================
echo "rm -rf ${HOME}/.slurm/connect-${SLURM_JOB_ID}.log" | at now + 1 hour
echo "rm -rf ${HOME}/.slurm/info-${SLURM_JOB_ID}.log" | at now + 7 day
