#!/bin/bash
#
# 构建最终的 Slurm 计算节点镜像。
# 功能：
# 1. (Builder Stage) 在一个临时的 Rust 容器中编译自定义的监控程序。
# 2. (Final Stage) 基于 ohpc/base-compute:1.0 镜像。
# 3. 安装所有计算节点需要的开发工具、HPC 库和编译器。
# 4. 从 Builder Stage 复制编译好的二进制文件。
# 5. 配置 Slurm, Systemd 等服务。
#
set -e # 任何命令失败则立即退出

# --- 配置 ---
BASE_IMAGE="ohpc/base-compute:1.0"
NEW_IMAGE_NAME="ohpc/node-slurm-compute:1.0"
MAINTAINER="pushihao@njust.edu.cn"
BUILDER_IMAGE="docker.io/library/rust:1.85-slim"

# --- 第 1 部分: 在专用的 builder 容器中编译 Rust 应用 ---
echo "--- Part 1: Build Rust applications in a dedicated builder ---"
echo ">>> Creating Rust builder container from ${BUILDER_IMAGE}..."
builder_ctr=$(buildah from "${BUILDER_IMAGE}")

echo ">>> Copying source code to builder..."
buildah copy "${builder_ctr}" ./custom_script/check /app

echo ">>> Compiling Rust applications..."
buildah run "${builder_ctr}" -- bash -c '
  set -ex
  mkdir -p /app/bin

  cd /app/client
  cargo build --release
  mv target/release/client /app/bin/job_helper
  
  cd /app/monitor
  cargo build --release
  mv target/release/monitor /app/bin/node_monitor
'
echo "--- Builder stage complete. Artifacts are ready. ---"
echo

# --- 第 2 部分: 构建最终的计算节点镜像 ---
echo "--- Part 2: Build the final compute node image ---"
echo ">>> Creating final image container from ${BASE_IMAGE}..."
final_ctr=$(buildah from "${BASE_IMAGE}")

# 设置元数据
buildah config --label maintainer="${MAINTAINER}" --created-by "Buildah" "${final_ctr}"

# 安装所有软件包
buildah run "${final_ctr}" -- bash -c '
  set -ex
  echo ">>> Installing development tools and HPC libraries..."
  dnf -y groupinstall "Development Tools"
  dnf install -y lmod-ohpc ohpc-autotools EasyBuild-ohpc hwloc-ohpc lmod-defaults-gnu13-openmpi5-ohpc \
                 ohpc-gnu13-runtimes gnu13-compilers-ohpc ohpc-gnu13-perf-tools \
                 openblas-gnu13-ohpc netcdf-gnu13-openmpi5-ohpc \
                 ohpc-gnu13-python-libs
  dnf install -y patch file zstd bzip2 xz  \
                 git tmux screen \
                 procps-ng \
                 openssh-server dropbear at

  echo ">>> Cleaning up package cache..."
  dnf clean all
  rm -rf /var/cache/dnf/*
'

# 复制配置文件
echo ">>> Copying configuration files..."
buildah copy "${final_ctr}" ./ssh_config/sshd_config /etc/ssh/sshd_config
buildah copy "${final_ctr}" ./pam.d/sshd ./pam.d/system-auth ./pam.d/password-auth /etc/pam.d/
buildah copy "${final_ctr}" ./custom_script/epilog.sh ./custom_script/prolog.sh ./custom_script/task_epilog.sh ./custom_script/task_prolog.sh /etc/slurm/

# --- 第 3 部分: 从 builder 复制编译产物到最终镜像 ---
echo "--- Part 3: Copy artifacts from builder to final image ---"
echo ">>> Mounting builder container filesystem..."
builder_mnt=$(buildah mount "${builder_ctr}")

echo ">>> Copying compiled binaries from ${builder_mnt}..."
buildah copy --from "${builder_ctr}" "${final_ctr}" /app/bin/job_helper /usr/local/bin/
buildah copy --from "${builder_ctr}" "${final_ctr}" /app/bin/node_monitor /usr/local/bin/

# --- 第 4 部分: 最终配置和清理 ---
echo "--- Part 4: Final configuration and cleanup ---"
# 设置脚本权限
buildah run "${final_ctr}" -- bash -c '
  set -ex
  mkdir -p /var/log/slurm
  chmod +x /etc/slurm/prolog.sh /etc/slurm/epilog.sh /etc/slurm/task_epilog.sh /etc/slurm/task_prolog.sh /usr/local/bin/job_helper /usr/local/bin/node_monitor
'

# 设置 root 密码
buildah run "${final_ctr}" -- bash -c 'usermod -p "$(openssl passwd -1 -stdin <<< root)" root'

# 配置开机任务
buildah run "${final_ctr}" -- bash -c '
  echo "rm -f /var/run/nologin" >> /etc/rc.local
  chmod +x /etc/rc.local
'

# 复制并启用 systemd 服务
buildah copy "${final_ctr}" ./systemd_config/slurmd_override.conf /etc/systemd/system/slurmd.service.d/override.conf
buildah copy "${final_ctr}" ./systemd_config/node_monitor.service /etc/systemd/system/node_monitor.service
buildah run "${final_ctr}" -- systemctl enable munge dbus.socket slurmd sshd nslcd node_monitor atd

# 设置默认启动命令
buildah config --cmd '["/usr/sbin/init"]' "${final_ctr}"

# --- 提交与清理 ---
echo ">>> Unmounting and removing builder container..."
buildah unmount "${builder_ctr}"
buildah rm "${builder_ctr}"

echo ">>> Committing final image: ${NEW_IMAGE_NAME}..."
buildah commit "${final_ctr}" "${NEW_IMAGE_NAME}"
buildah rm "${final_ctr}"

echo "--- Build complete for ${NEW_IMAGE_NAME} ---"