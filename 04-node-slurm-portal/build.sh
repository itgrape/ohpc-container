#!/bin/bash
#
# 构建最终的 Slurm 门户节点 (slurm-portal) 镜像。
# 这是一个多阶段构建过程：
# 1. Frontend Builder: 使用 Node.js 镜像编译前端静态文件。
# 2. Backend Builder: 使用 Go 镜像编译后端服务器二进制文件。
# 3. Final Image: 基于 ohpc/base-compute:1.0，安装软件包，并从前两个阶段复制编译好的产物，最后进行配置。
#
set -e # 任何命令失败则立即退出

# --- 配置 ---
BASE_IMAGE="ohpc/base-compute:1.0"
NEW_IMAGE_NAME="ohpc/node-slurm-portal:1.0"
MAINTAINER="pushihao@njust.edu.cn"

# Builder 镜像配置
FRONTEND_BUILDER_IMAGE="docker.io/library/node:24-alpine"
BACKEND_BUILDER_IMAGE="docker.io/library/golang:1.24"
DASHBOARD_REPO="https://github.com/itgrape/slurm-dashboard.git"

# --- 第 1 部分: 前端构建阶段 ---
echo "--- Part 1: Build Frontend in a dedicated Node.js builder ---"
frontend_builder_ctr=$(buildah from "${FRONTEND_BUILDER_IMAGE}")
buildah run "${frontend_builder_ctr}" -- sh -c '
  set -ex
  apk add --no-cache git
  git clone '"${DASHBOARD_REPO}"' /app
  cd /app/frontend
  npm install
  npm run build
'
echo "--- Frontend build complete. ---"
echo

# --- 第 2 部分: 后端构建阶段 ---
echo "--- Part 2: Build Backend in a dedicated Go builder ---"
backend_builder_ctr=$(buildah from "${BACKEND_BUILDER_IMAGE}")
buildah run "${backend_builder_ctr}" -- bash -c '
  set -ex
  # Go 镜像基于 Debian，使用 apt-get
  apt-get update && apt-get install -y git
  git clone '"${DASHBOARD_REPO}"' /app
  cd /app/backend
  go mod download
  # 编译静态链接的二进制文件
  CGO_ENABLED=1 GOOS=linux go build -a -ldflags "-extldflags \"-static\"" -o /app/server ./cmd/server
'
echo "--- Backend build complete. ---"
echo

# --- 第 3 部分: 最终镜像组装 ---
echo "--- Part 3: Assemble the final portal node image ---"
final_ctr=$(buildah from "${BASE_IMAGE}")
buildah config --label maintainer="${MAINTAINER}" --created-by "Buildah" "${final_ctr}"

# 安装软件包
buildah run "${final_ctr}" -- bash -c '
  set -ex
  dnf install -y unzip jq procps-ng iproute iputils bind-utils findutils vim rsync git tmux screen
  dnf clean all
  rm -rf /var/cache/dnf/*
'

# --- 第 4 部分: 从 Builder 复制产物 ---
echo "--- Part 4: Copy artifacts from builders to the final image ---"
echo ">>> Copying backend server..."
buildah copy --from "${backend_builder_ctr}" "${final_ctr}" /app/server /usr/local/dashboard/server

echo ">>> Copying frontend static files..."
buildah copy --from "${frontend_builder_ctr}" "${final_ctr}" /app/frontend/dist /usr/local/dashboard/static

# --- 第 5 部分: 最终配置 ---
echo "--- Part 5: Final configuration ---"

# 配置开机任务
buildah run "${final_ctr}" -- bash -c '
  echo "rm -f /var/run/nologin" >> /etc/rc.local
  chmod +x /etc/rc.local
'

# 复制并启用 systemd 服务
buildah copy "${final_ctr}" ./systemd_config/slurmd_override.conf /etc/systemd/system/slurmd.service.d/override.conf
buildah copy "${final_ctr}" ./systemd_config/dashboard.service /etc/systemd/system/dashboard.service
buildah run "${final_ctr}" -- systemctl enable munge dbus.socket slurmd nslcd dashboard

# 设置默认启动命令
buildah config --cmd '["/usr/sbin/init"]' "${final_ctr}"

# --- 第 6 部分: 提交与清理 ---
echo "--- Part 6: Committing final image and cleaning up ---"
echo ">>> Removing builder containers..."
buildah rm "${frontend_builder_ctr}"
buildah rm "${backend_builder_ctr}"

echo ">>> Committing final image: ${NEW_IMAGE_NAME}..."
buildah commit "${final_ctr}" "${NEW_IMAGE_NAME}"
buildah rm "${final_ctr}"

echo "--- Build complete for ${NEW_IMAGE_NAME} ---"