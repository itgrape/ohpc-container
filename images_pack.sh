#!/bin/bash
#
# ==============================================================
#                         镜像打包脚本
# ==============================================================
#
# 功能:
#   一键打包所有镜像到指定目录
#
# 使用:
#   在项目根目录下运行: bash ./images_pack.sh
#
#---------------------------------------------------------------

set -e # 任何命令失败则立即退出

# 要打包的镜像列表
IMAGES=(
  "localhost/ohpc/node-slurm-control:1.0"
  "localhost/ohpc/node-slurm-portal:1.0"
  "localhost/ohpc/node-slurm-login:1.0"
  "localhost/ohpc/node-slurm-compute:1.0"
  "localhost/ohpc/node-openldap:1.0"
)

# 创建一个目录来存放打包好的镜像
OUTPUT_DIR="ohpc_images"
mkdir -p "$OUTPUT_DIR"

echo "Starting image packing process..."

# 循环遍历列表中的每个镜像
for image in "${IMAGES[@]}"; do
  # 将镜像名中的 / 和 : 替换成 _ 和 -，以生成合法的文件名
  filename=$(echo "$image" | sed 's|/|_|g' | sed 's|:|-|g').tar

  echo "==> Packing ${image} to ${OUTPUT_DIR}/${filename}..."

  # 执行打包命令
  podman save -o "${OUTPUT_DIR}/${filename}" "$image"

  if [ $? -eq 0 ]; then
    echo "    SUCCESS: ${image} packed successfully."
  else
    echo "    ERROR: Failed to pack ${image}."
  fi
done

echo "All images have been processed."
