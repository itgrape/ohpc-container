#!/bin/bash
#
# 构建最终的 Slurm 登录节点镜像。
# 功能：
# 1. 基于 ohpc/base-compute:1.0 镜像。
# 2. 安装需要的开发工具、HPC 库和编译器。
# 3. 配置 Slurm, Systemd 等服务。
#
set -e # 任何命令失败则立即退出

# --- 配置 ---
BASE_IMAGE="ohpc/base-compute:1.0"
NEW_IMAGE_NAME="ohpc/node-slurm-login:1.0"
MAINTAINER="pushihao@njust.edu.cn"

echo "--- Building ${NEW_IMAGE_NAME} from ${BASE_IMAGE} ---"

# 1. 从基础镜像创建工作容器
ctr=$(buildah from "${BASE_IMAGE}")

# 2. 设置镜像元数据
buildah config --label maintainer="${MAINTAINER}" --created-by "Buildah" "${ctr}"

# 3. 安装登录节点特定的软件包
buildah run "${ctr}" -- bash -c '
  set -ex
  echo ">>> Installing login node specific packages..."
  dnf swap -y curl-minimal curl
  dnf install -y unzip jq procps-ng iproute iputils bind-utils findutils vim rsync git tmux screen openssh-server cockpit

  echo ">>> Cleaning up package cache..."
  dnf clean all
  rm -rf /var/cache/dnf/*
'

# 4. 从宿主机复制配置文件
echo ">>> Copying configuration files..."
buildah copy "${ctr}" ./ssh_config/sshd_config /etc/ssh/sshd_config

# 5. 设置 root 密码
buildah run "${ctr}" -- bash -c 'usermod -p "$(openssl passwd -1 -stdin <<< root)" root'

# 6. 配置开机任务
buildah run "${ctr}" -- bash -c '
  echo "rm -f /var/run/nologin" >> /etc/rc.local
  chmod +x /etc/rc.local
'

# 7. 复制并启用 systemd 服务
buildah copy "${ctr}" ./systemd_config/slurmd_override.conf /etc/systemd/system/slurmd.service.d/override.conf
buildah run "${ctr}" -- systemctl enable munge dbus.socket slurmd sshd nslcd cockpit.socket

# 8. 设置容器默认启动命令
buildah config --cmd '["/usr/sbin/init"]' "${ctr}"

# 9. 提交工作容器为新镜像
echo "--- Committing ${NEW_IMAGE_NAME} ---"
buildah commit "${ctr}" "${NEW_IMAGE_NAME}"

# 10. 清理临时工作容器
buildah rm "${ctr}"

echo "--- Build complete for ${NEW_IMAGE_NAME} ---"