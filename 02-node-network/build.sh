#!/bin/bash
#
# 构建唯一可以上网的镜像，并且镜像不与 slurm 集群进行通信 (node-network)。
# 功能：
# 1. 基于 ohpc/bos:1.0 镜像。
# 2. 安装 openssh 以及一些核心软件包。
# 3. 进行 LDAP 用户认证。
#
set -e # 任何命令失败则立即退出

# --- 配置 ---
BASE_IMAGE="ohpc/bos:1.0"
NEW_IMAGE_NAME="ohpc/node-network:1.0"
MAINTAINER="pushihao@njust.edu.cn"

echo "--- Building ${NEW_IMAGE_NAME} from ${BASE_IMAGE} ---"

# 1. 从基础镜像创建工作容器
ctr=$(buildah from "${BASE_IMAGE}")

# 2. 设置镜像元数据
buildah config --label maintainer="${MAINTAINER}" --created-by "Buildah" "${ctr}"

# 3. 运行安装命令
buildah run "${ctr}" -- bash -c '
  set -ex

  echo ">>> Installing openssh and core packages..."
  dnf install -y openssh-server
  dnf swap -y curl-minimal curl
  dnf install -y git wget tmux screen rsync iproute iputils
'

# 4. LDAP 用户认证
buildah copy "${ctr}" ./pam.d/system-auth ./pam.d/password-auth /etc/pam.d/
buildah copy "${ctr}" ./openldap_config/nslcd.conf ./openldap_config/nsswitch.conf /etc/
buildah run "${ctr}" -- bash -c '
  set -ex

  echo ">>> Configure LDAP Client"
  dnf install -y openldap-clients nss-pam-ldapd
  chmod 640 /etc/nslcd.conf

  echo ">>> Cleaning up package cache..."
  dnf clean all
  rm -rf /var/cache/dnf/*
'

# 5. openssh 配置
buildah copy "${ctr}" ./ssh_config/sshd_config /etc/ssh/sshd_config

# 6. 设置 root 密码
buildah run "${ctr}" -- bash -c 'usermod -p "$(openssl passwd -1 -stdin <<< root)" root'

# 7. 配置开机任务
buildah run "${ctr}" -- bash -c '
  echo "rm -f /var/run/nologin" >> /etc/rc.local
  chmod +x /etc/rc.local
'

# 8. 启用 systemd 服务
buildah run "${ctr}" -- systemctl enable sshd nslcd

# 9. 设置容器默认启动命令
buildah config --cmd '["/usr/sbin/init"]' "${ctr}"

# 10. 提交工作容器为新镜像
echo "--- Committing ${NEW_IMAGE_NAME} ---"
buildah commit "${ctr}" "${NEW_IMAGE_NAME}"

# 11. 清理临时工作容器
buildah rm "${ctr}"

echo "--- Build complete for ${NEW_IMAGE_NAME} ---"