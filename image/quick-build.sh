#!/bin/bash
# ============================================================
# ClawBox 快速构建 — 一键构建系统镜像
#
# 用法: sudo ./quick-build.sh [选项]
#   -p|--proxyclaw-path PATH   本地源码路径
#   --proxyclaw-repo   URL     GitHub 仓库地址
#   --proxyclaw-branch BR     分支名 (默认: main)
#   --no-proxyclaw            跳过构建，拉取远程镜像
#   --no-cache                不使用 rootfs 缓存，强制全量重建
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 颜色
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# 收集传递给 build-os.sh 的参数
BUILD_OS_ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --proxyclaw-*|--no-proxyclaw|--no-cache)
            BUILD_OS_ARGS+=("$1")
            if [[ "$1" == *"="* ]]; then
                shift
            else
                # 需要第二个参数
                case $1 in
                    --proxyclaw-repo|--proxyclaw-branch|--proxyclaw-path)
                        BUILD_OS_ARGS+=("$2"); shift 2 ;;
                    *)
                        shift ;;
                esac
            fi
            ;;
        -p)
            BUILD_OS_ARGS+=("--proxyclaw-path" "$2"); shift 2 ;;
        --help|-h)
            echo "Usage: sudo $0 [选项]"
            echo ""
            echo "proxyclaw 构建选项:"
            echo "  -p, --proxyclaw-path PATH   本地源码路径"
            echo "  --proxyclaw-repo URL        GitHub 仓库地址"
            echo "  --proxyclaw-branch BR       分支名 (默认: main)"
            echo "  --no-proxyclaw              跳过构建，拉取远程镜像"
            echo "  --no-cache                  不使用 rootfs 缓存"
            exit 0
            ;;
        *)
            shift ;;
    esac
done

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════╗"
echo "║     🎓 ClawBox 快速构建                      ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# 检查 root
if [[ $EUID -ne 0 ]]; then
    echo "需要 root 权限，正在提权..."
    exec sudo "$0" "$@"
fi

# 安装依赖
echo -e "${GREEN}[1/3]${NC} 安装构建依赖..."
apt-get update -qq
apt-get install -y -qq debootstrap parted e2fsprogs grub-pc-bin grub2-common git

# 运行构建
echo -e "${GREEN}[2/3]${NC} 构建系统镜像..."
cd "$SCRIPT_DIR"
./build-os.sh \
    --output-dir "$PROJECT_DIR/output" \
    --hostname clawbox \
    --image-size 4G \
    "${BUILD_OS_ARGS[@]}"

# 完成
echo -e "${GREEN}[3/3]${NC} 构建完成!"
echo ""
echo "镜像文件在: $PROJECT_DIR/output/"
echo ""
echo "下一步:"
echo "  1. 准备一个 U 盘 (至少 4GB)"
echo "  2. 烧录镜像到 U 盘"
echo "  3. 插入目标设备，从 U 盘启动"
echo "  4. 首次启动会自动完成配置"
