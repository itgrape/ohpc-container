#!/bin/bash
#
# ==============================================================
#                    OHPC 容器化环境总构建脚本
# ==============================================================
#
# 功能:
#   按正确的依赖顺序，一键构建项目中的所有容器镜像。
#
# 使用:
#   在项目根目录下运行: bash ./build-all.sh
#
#---------------------------------------------------------------

set -e # 任何命令失败则立即退出

echo
echo "======================================================"
echo "    STARTING OHPC-CONTAINER FULL IMAGE BUILD"
echo "======================================================"
echo

# --- Level 1 ---
echo ">>> [LEVEL 1] Building Root Base Image..."
(cd 01-bos && buildah unshare bash build.sh)
echo "--- Level 1 Complete ---"
echo

# --- Level 2 ---
echo ">>> [LEVEL 2] Building Core Services & OHPC Base..."
(cd 02-base-ohpc && buildah unshare bash build.sh)
(cd 02-node-openldap && buildah unshare bash build.sh)
# (cd 02-node-mysql && buildah unshare bash build.sh)

echo "--- Level 2 Complete ---"
echo

# --- Level 3 ---
echo ">>> [LEVEL 3] Building Compute Bases and Control Node..."
(cd 03-node-slurm-control && buildah unshare bash build.sh)
(cd 03-base-compute && buildah unshare bash build.sh)
echo "--- Level 3 Complete ---"
echo

# --- Level 4 ---
echo ">>> [LEVEL 4] Building Final Service Nodes..."
(cd 04-node-slurm-compute && buildah unshare bash build.sh)
(cd 04-node-slurm-login && buildah unshare bash build.sh)
(cd 04-node-slurm-portal && buildah unshare bash build.sh)

echo "--- Level 4 Complete ---"
echo

# --- Final Summary ---
echo "======================================================"
echo "    ALL BUILDS COMPLETED SUCCESSFULLY!"
echo "======================================================"
echo
echo "Listing all created 'ohpc/' images:"
buildah images | grep "ohpc/"
echo