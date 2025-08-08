#!/bin/bash
#
# 构建计算节点的基础镜像 (base-compute)。
# 功能：
# 1. 基于 ohpc/base-ohpc:1.0 镜像。
# 2. 安装 Slurm 客户端组件 (ohpc-slurm-client)，其中包含 slurmd。
# 3. 设置 slurmd 的日志文件和权限。
#
set -e # 任何命令失败则立即退出

# --- 配置 ---
BASE_IMAGE="ohpc/base-ohpc:1.0"
NEW_IMAGE_NAME="ohpc/base-compute:1.0"
MAINTAINER="pushihao@njust.edu.cn"

echo "--- Building ${NEW_IMAGE_NAME} from ${BASE_IMAGE} ---"

# 1. 从基础镜像创建工作容器
ctr=$(buildah from "${BASE_IMAGE}")

# 2. 设置镜像元数据
buildah config --label maintainer="${MAINTAINER}" --created-by "Buildah" "${ctr}"

# 3. 安装 Slurm 客户端软件包
buildah run "${ctr}" -- bash -c '
  set -ex
  echo ">>> Installing Slurm client components..."
  dnf install -y ohpc-base-compute
  dnf install -y ohpc-slurm-client
'

# 5. 设置 slurmd 日志文件和权限
buildah run "${ctr}" -- bash -c '
  set -ex
  echo ">>> Setting up slurmd log file..."
  touch /var/log/slurmd.log
  chown slurm:slurm /var/log/slurmd.log
  chmod 640 /var/log/slurmd.log
'

# 6. 创建空的脚本文件
buildan run "${ctr}" -- bash -c '
  set -ex
  echo ">>> Creating empty script file..."
  touch /etc/slurm/prolog.sh /etc/slurm/epilog.sh /etc/slurm/task_prolog.sh /etc/slurm/task_epilog.sh
  chmod +x /etc/slurm/prolog.sh /etc/slurm/epilog.sh /etc/slurm/task_epilog.sh /etc/slurm/task_prolog.sh
'

# 7. 提交工作容器为新镜像
echo "--- Committing ${NEW_IMAGE_NAME} ---"
buildah commit "${ctr}" "${NEW_IMAGE_NAME}"

# 8. 清理临时工作容器
buildah rm "${ctr}"

echo "--- Build complete for ${NEW_IMAGE_NAME} ---"