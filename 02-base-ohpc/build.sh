#!/bin/bash
#
# 构建 OpenHPC 基础镜像 (base-ohpc)。
# 功能：
# 1. 基于 ohpc/base-root:1.0 镜像。
# 2. 安装 OpenHPC 的软件源和一系列核心软件包。
# 3. 生成 Munge 密钥。
# 4. 进行 LDAP 用户认证。
#
set -e # 任何命令失败则立即退出

# --- 配置 ---
BASE_IMAGE="ohpc/base-root:1.0"
NEW_IMAGE_NAME="ohpc/base-ohpc:1.0"
MAINTAINER="pushihao@njust.edu.cn"

# 架构变量，用于拼接 OpenHPC 的源地址
ARCH="x86_64"

echo "--- Building ${NEW_IMAGE_NAME} from ${BASE_IMAGE} ---"

# 1. 从基础镜像创建工作容器
ctr=$(buildah from "${BASE_IMAGE}")

# 2. 设置镜像元数据
buildah config --label maintainer="${MAINTAINER}" --created-by "Buildah" "${ctr}"

# 3. 运行安装命令
buildah run "${ctr}" -- bash -c '
  set -ex

  echo ">>> Installing OpenHPC repo and core packages..."
  dnf install -y http://repos.openhpc.community/OpenHPC/3/EL_9/'"$ARCH"'/ohpc-release-3-1.el9.'"$ARCH"'.rpm
  dnf install -y dnf-plugins-core
  dnf config-manager --set-enabled crb
  dnf install -y ohpc-base
'

# 4. 密钥生成
buildah run "${ctr}" -- bash -c '
  set -ex

  echo ">>> Generating Munge key..."
  dnf install -y munge
  /usr/sbin/create-munge-key
'

# 5. LDAP 用户认证，因为 Slurm 集群每个节点都需要用户信息
buildah copy "${ctr}" ./pam.d/system-auth ./pam.d/password-auth /etc/pam.d/
buildah copy "${ctr}" ./openldap_config/nslcd.conf ./openldap_config/nsswitch.conf /etc/
buildah run "${ctr}" -- bash -c '
  set -ex

  echo ">>> Configure LDAP Client"
  dnf install -y openldap-clients nss-pam-ldapd
  chmod 640 /etc/nslcd.conf
'

# 5. 提交工作容器为新镜像
echo "--- Committing ${NEW_IMAGE_NAME} ---"
buildah commit "${ctr}" "${NEW_IMAGE_NAME}"

# 6. 清理临时工作容器
buildah rm "${ctr}"

echo "--- Build complete for ${NEW_IMAGE_NAME} ---"