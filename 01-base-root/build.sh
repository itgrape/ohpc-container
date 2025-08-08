#!/bin/bash
#
# 构建所有镜像的根镜像 (base-root)。
# 功能：
# 1. 基于官方的 rockylinux:9。
# 2. 添加 EPEL 源。
# 3. 对 systemd 进行裁剪，移除不必要的服务，使其适合作为容器基础环境。
# 4. 清理缓存，减小镜像体积。
#
set -e # 任何命令失败则立即退出

# --- 配置 ---
# 基础镜像，直接从 Docker Hub 拉取
BASE_IMAGE="registry.docker.com/library/rockylinux:9"

# 定义新镜像的名称和标签
NEW_IMAGE_NAME="ohpc/base-root:1.0" 

# 维护者信息
MAINTAINER="pushihao@njust.edu.cn"


echo "--- Building ${NEW_IMAGE_NAME} from ${BASE_IMAGE} ---"

# 1. 从基础镜像创建工作容器
ctr=$(buildah from "${BASE_IMAGE}")

# 2. 设置镜像元数据
buildah config --label maintainer="${MAINTAINER}" --created-by "Buildah" "${ctr}"

# 3. 运行安装和配置命令
#    使用 'set -ex' 会在容器内执行时打印每条命令，非常便于调试
buildah run "${ctr}" -- bash -c '
  set -ex

  echo ">>> Installing EPEL repo and base packages..."
  dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
  dnf upgrade -y
  dnf install -y systemd systemd-libs

  echo ">>> Pruning systemd services for container environment..."
  (cd /lib/systemd/system/sysinit.target.wants/; for i in *; do [ $i == systemd-tmpfiles-setup.service ] || rm -f $i; done)
  
  # 删除其他 target 的 wants 目录下的所有服务链接，大幅精简
  rm -f /lib/systemd/system/multi-user.target.wants/*
  rm -f /etc/systemd/system/*.wants/*
  rm -f /lib/systemd/system/local-fs.target.wants/*
  rm -f /lib/systemd/system/sockets.target.wants/*udev*
  rm -f /lib/systemd/system/sockets.target.wants/*initctl*
  rm -f /lib/systemd/system/basic.target.wants/*
  rm -f /lib/systemd/system/anaconda.target.wants/*
'

# 4. 提交工作容器为新镜像
echo "--- Committing ${NEW_IMAGE_NAME} ---"
buildah commit "${ctr}" "${NEW_IMAGE_NAME}"

# 5. 清理临时工作容器
buildah rm "${ctr}"

echo "--- Build complete for ${NEW_IMAGE_NAME} ---"