#!/bin/bash
#
# 构建管理节点的最终镜像 (node-slurm-control)。
# 功能：
# 1. 基于 ohpc/base-ohpc:1.0 镜像。
# 2. 安装 Slurm 服务器端组件 (slurm-server, slurmrestd)。
# 3. 复制所有相关的 Slurm、脚本等配置文件。
# 4. 设置日志文件、用户和权限。
# 5. 启用所需的服务，并设置容器启动命令为 /usr/sbin/init。
#
set -e # 任何命令失败则立即退出

# --- 配置 ---
BASE_IMAGE="ohpc/base-ohpc:1.0"
NEW_IMAGE_NAME="ohpc/node-slurm-control:1.0"
MAINTAINER="pushihao@njust.edu.cn"

echo "--- Building ${NEW_IMAGE_NAME} from ${BASE_IMAGE} ---"

# 1. 从基础镜像创建工作容器
ctr=$(buildah from "${BASE_IMAGE}")

# 2. 设置镜像元数据
buildah config --label maintainer="${MAINTAINER}" --created-by "Buildah" "${ctr}"

# 3. 安装服务器组件以及一些通用包，可能会用到
buildah run "${ctr}" -- bash -c '
  set -ex
  echo ">>> Installing packages..."
  dnf install -y ohpc-slurm-server
  dnf install -y slurm-ohpc-slurmrestd

  dnf install -y git
  
  echo ">>> Cleaning up package cache..."
  dnf clean all
  rm -rf /var/cache/dnf/*
'

# 4. 从宿主机复制所有配置文件
echo "--- Copying configuration files ---"
# Slurm 配置
buildah copy "${ctr}" ./slurm_config/cgroup.conf ./slurm_config/slurm.conf ./slurm_config/gres.conf ./slurm_config/slurmdbd.conf /etc/slurm/
# 自定义脚本
buildah copy "${ctr}" ./custom_script/mail_wrapper.sh /usr/local/bin/mail_wrapper.sh
buildah copy "${ctr}" ./custom_script/job_submit.lua /etc/slurm/job_submit.lua

# 5. 设置日志文件和相关权限
buildah run "${ctr}" -- bash -c '
  set -ex
  echo ">>> Setting up log files and permissions..."
  touch /var/log/slurmctld.log && chown slurm:slurm /var/log/slurmctld.log && chmod 640 /var/log/slurmctld.log
  touch /var/log/munge/munged.log && chown -R munge:munge /var/log/munge && chmod 640 /var/log/munge/munged.log
  touch /var/log/slurmdbd.log
  chmod +x /usr/local/bin/mail_wrapper.sh
  chown slurm:slurm /etc/slurm/slurmdbd.conf && chmod 600 /etc/slurm/slurmdbd.conf
'

# 6. 配置 slurmrestd 参考 https://slurm.schedmd.com/rest_quickstart.html
buildah run "${ctr}" -- bash -c '
  set -ex
  echo ">>> Setting up slurmrestd user and JWT key..."
  useradd -M -r -s /usr/sbin/nologin -U slurmrestd
  mkdir -p /var/spool/slurm/statesave
  dd if=/dev/random of=/var/spool/slurm/statesave/jwt_hs256.key bs=32 count=1
  chown slurm:slurm /var/spool/slurm/statesave/jwt_hs256.key
  chmod 0600 /var/spool/slurm/statesave/jwt_hs256.key
  chown slurm:slurm /var/spool/slurm/statesave
  chmod 0755 /var/spool/slurm/statesave
'

# 7. 清除 nologin 文件，否则容器环境下有时候会报错
buildah run "${ctr}" -- bash -c '
  echo "rm -f /var/run/nologin" >> /etc/rc.local
  chmod +x /etc/rc.local
'

# 8. 复制 systemd 服务覆写配置
echo "--- Copying systemd override files ---"
buildah copy "${ctr}" ./systemd_config/slurmctld_override.conf /etc/systemd/system/slurmctld.service.d/override.conf
buildah copy "${ctr}" ./systemd_config/slurmdbd_override.conf /etc/systemd/system/slurmdbd.service.d/override.conf
buildah copy "${ctr}" ./systemd_config/slurmrestd_override.conf /etc/systemd/system/slurmrestd.service.d/override.conf

# 9. 启用所需服务
buildah run "${ctr}" -- systemctl enable munge slurmctld slurmdbd slurmrestd nslcd

# 10. 设置容器默认启动命令
buildah config --cmd '["/usr/sbin/init"]' "${ctr}"

# 11. 提交工作容器为新镜像
echo "--- Committing ${NEW_IMAGE_NAME} ---"
buildah commit "${ctr}" "${NEW_IMAGE_NAME}"

# 12. 清理临时工作容器
buildah rm "${ctr}"

echo "--- Build complete for ${NEW_IMAGE_NAME} ---"