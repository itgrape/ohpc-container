#!/bin/bash
#
# 构建管理节点的基础镜像 (base-master)。
# 功能：
# 1. 基于 ohpc/base-ohpc:1.0 镜像。
# 2. 安装 Slurm 服务器端组件 (slurm-server, slurmrestd)。
#
set -e # 任何命令失败则立即退出

# --- 配置 ---
BASE_IMAGE="ohpc/base-ohpc:1.0"
NEW_IMAGE_NAME="ohpc/base-master:1.0"
MAINTAINER="pushihao@njust.edu.cn"

echo "--- Building ${NEW_IMAGE_NAME} from ${BASE_IMAGE} ---"

# 1. 从基础镜像创建工作容器
ctr=$(buildah from "${BASE_IMAGE}")

# 2. 设置镜像元数据
buildah config --label maintainer="${MAINTAINER}" --created-by "Buildah" "${ctr}"

# 3. 安装 Slurm 服务器端软件包
buildah run "${ctr}" -- bash -c '
  set -ex

  echo ">>> Installing Slurm server components..."
  dnf install -y ohpc-slurm-server

  dnf install -y slurm-ohpc-slurmrestd
'

# 4. 提交工作容器为新镜像
echo "--- Committing ${NEW_IMAGE_NAME} ---"
buildah commit "${ctr}" "${NEW_IMAGE_NAME}"

# 5. 清理临时工作容器
buildah rm "${ctr}"

echo "--- Build complete for ${NEW_IMAGE_NAME} ---"