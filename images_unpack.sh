#!/bin/bash
#
# ==============================================================
#                         镜像解包脚本
# ==============================================================
#
# 功能:
#   一键解包当前目录的所有镜像压缩文件
#
# 使用:
#   在项目根目录下运行: bash ./images_unpack.sh
#
#---------------------------------------------------------------

set -e # 任何命令失败则立即退出

echo "Starting image unpacking process..."

# 检查当前目录下是否有 .tar 文件
if ! ls *.tar &> /dev/null; then
    echo "No .tar files found in the current directory."
    exit 1
fi

# 循环加载当前目录下的所有 .tar 文件
for file in *.tar; do
  echo "==> Unpacking ${file}..."

  # 执行解包命令
  podman load -i "$file"

  if [ $? -eq 0 ]; then
    echo "    SUCCESS: ${file} unpacked successfully."
  else
    echo "    ERROR: Failed to unpack ${file}."
  fi
done

echo "All .tar files have been processed."
echo "Run 'podman images' to check the loaded images."
