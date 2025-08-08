#!/bin/bash
#
# 构建 OpenLDAP 服务器节点镜像。
# 功能：
# 1. 基于 ohpc/bos:1.0 镜像，继承其所有基础配置。
# 2. 安装 OpenLDAP 服务器、Nginx 和 phpLDAPadmin。
# 3. 复制预设的 Nginx 和 phpLDAPadmin 配置文件。
# 4. 启用所需服务 (slapd, nginx)。
#
set -e # 任何命令失败则立即退出

# --- 配置 ---
BASE_IMAGE="ohpc/bos:1.0"
NEW_IMAGE_NAME="ohpc/node-openldap:1.0"
MAINTAINER="pushihao@njust.edu.cn"

echo "--- Building ${NEW_IMAGE_NAME} from ${BASE_IMAGE} ---"

# 1. 从基础镜像创建工作容器
ctr=$(buildah from "${BASE_IMAGE}")

# 2. 设置镜像元数据
buildah config --label maintainer="${MAINTAINER}" --created-by "Buildah" "${ctr}"

# 3. 安装 OpenLDAP, Nginx, 和 phpLDAPadmin 软件包
buildah run "${ctr}" -- bash -c '
  set -ex
  echo ">>> Installing OpenLDAP packages..."
  dnf install -y iputils iproute openldap openldap-servers openldap-clients nginx phpldapadmin

  echo ">>> Cleaning up package cache..."
  dnf clean all
  rm -rf /var/cache/dnf/*
'

# 4. 从宿主机复制配置文件
echo ">>> Copying configuration files..."
buildah copy "${ctr}" ./php_ldap_admin_config/nginx.conf /etc/nginx/nginx.conf
buildah copy "${ctr}" ./php_ldap_admin_config/config.php /etc/phpldapadmin/config.php

# 5. 启用所需服务
buildah run "${ctr}" -- systemctl enable nginx slapd

# 6. 设置容器默认启动命令
buildah config --cmd '["/usr/sbin/init"]' "${ctr}"

# 7. 提交工作容器为新镜像
echo "--- Committing ${NEW_IMAGE_NAME} ---"
buildah commit "${ctr}" "${NEW_IMAGE_NAME}"

# 8. 清理临时工作容器
buildah rm "${ctr}"

echo "--- Build complete for ${NEW_IMAGE_NAME} ---"