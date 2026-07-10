#!/bin/bash
# ============================================================
# ClawBox 统一入口脚本
# 所有构建、部署、管理操作的统一入口
#
# 用法: ./start.sh <command> [子命令] [选项]
# ============================================================

set -euo pipefail

# ========== 配置 ==========
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_DIR="${SCRIPT_DIR}/image"
OUTPUT_DIR="${SCRIPT_DIR}/output"

# 版本
VERSION="${CLAWBOX_VERSION:-1.0.0}"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ========== 工具函数 ==========
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
log()   { echo -e "${BLUE}[i]${NC} $*"; }

# ========== 帮助信息 ==========
show_help() {
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                   ClawBox Build System                       ║
╚══════════════════════════════════════════════════════════════╝

用法: ./start.sh <command> [子命令] [选项]

构建命令:
  build os          构建磁盘镜像 (.img.gz)
  build iso         构建安装镜像 (.iso)
  build docker      构建 Docker 镜像
  build all         构建所有镜像

管理命令:
  clean             清理构建产物
  clean all         清理所有（含缓存）
  list              列出已构建的镜像

运行命令:
  run qemu          用 QEMU 启动已构建的镜像（推荐磁盘镜像 .img.gz）
  run check         检查虚拟机服务是否就绪

选项 (构建命令):
  -p, --proxyclaw-path PATH     本地源码路径
  --proxyclaw-repo URL          GitHub 仓库地址
  --proxyclaw-branch BR         分支名 (默认: main)
  --no-proxyclaw                跳过构建，拉取远程镜像
  --no-cache                    不使用缓存，强制全量重建
  --output-dir DIR              输出目录 (默认: ./output)
  --with-ollama                 包含 Ollama 镜像（约 3GB）

通用选项:
  -h, --help                    显示此帮助信息
  -v, --version                 显示版本号

示例:
  # 构建 ISO 镜像（跳过 proxyclaw）
  ./start.sh build iso --no-proxyclaw

  # 构建磁盘镜像（使用本地 proxyclaw）
  ./start.sh build os -p /path/to/proxyclaw

  # 构建 Docker 镜像
  ./start.sh build docker

  # 构建所有镜像
  ./start.sh build all --no-proxyclaw

  # 构建 ISO 镜像（包含 Ollama）
  ./start.sh build iso --no-proxyclaw --with-ollama

  # 清理构建产物
  ./start.sh clean

  # 列出已构建的镜像
  ./start.sh list

  # 用 QEMU 启动磁盘镜像
  ./start.sh run qemu

  # 用 QEMU 启动 ISO（需虚拟硬盘）
  ./start.sh run qemu --type iso
EOF
}

show_version() {
    echo "ClawBox Build System v${VERSION}"
}

# ========== 构建命令 ==========
cmd_build() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        os)     build_os "$@" ;;
        iso)    build_iso "$@" ;;
        docker) build_docker "$@" ;;
        all)    build_all "$@" ;;
        help|*) show_build_help ;;
    esac
}

show_build_help() {
    cat << 'EOF'
构建子命令:
  build os          构建磁盘镜像 (.img.gz) - 可直接 dd 烧录
  build iso         构建安装镜像 (.iso) - 支持 BIOS/UEFI
  build docker      构建 Docker 镜像 - 用于开发测试
  build all         构建所有镜像

选项:
  -p, --proxyclaw-path PATH     本地源码路径
  --proxyclaw-repo URL          GitHub 仓库地址
  --proxyclaw-branch BR         分支名 (默认: main)
  --no-proxyclaw                跳过构建，拉取远程镜像
  --no-cache                    不使用缓存，强制全量重建
  --output-dir DIR              输出目录 (默认: ./output)
  --with-ollama                 包含 Ollama 镜像（约 3GB）

示例:
  ./start.sh build iso --no-proxyclaw
  ./start.sh build os -p /path/to/proxyclaw
  ./start.sh build docker
  ./start.sh build iso --with-ollama
EOF
}

build_os() {
    log "构建磁盘镜像..."
    sudo "${IMAGE_DIR}/build-os.sh" --output-dir "${OUTPUT_DIR}" "$@"
}

build_iso() {
    log "构建 ISO 安装镜像..."
    sudo "${IMAGE_DIR}/build-iso.sh" --output-dir "${OUTPUT_DIR}" "$@"
}

build_docker() {
    log "构建 Docker 镜像..."
    "${IMAGE_DIR}/build.sh" docker
}

build_all() {
    log "构建所有镜像..."
    echo ""
    log "[1/3] 构建磁盘镜像..."
    sudo "${IMAGE_DIR}/build-os.sh" --output-dir "${OUTPUT_DIR}" "$@"
    echo ""
    log "[2/3] 构建 ISO 镜像..."
    sudo "${IMAGE_DIR}/build-iso.sh" --output-dir "${OUTPUT_DIR}" "$@"
    echo ""
    log "[3/3] 构建 Docker 镜像..."
    "${IMAGE_DIR}/build.sh" docker
    echo ""
    info "所有镜像构建完成!"
}

# ========== 清理命令 ==========
unmount_stale_build_mounts() {
    local base="${SCRIPT_DIR}/build"
    for mp in "${base}/mnt" "${base}/rootfs"; do
        for sub in dev/pts sys proc dev; do
            if mountpoint -q "${mp}/${sub}" 2>/dev/null; then
                sudo umount -lf "${mp}/${sub}" 2>/dev/null || true
            fi
        done
        if mountpoint -q "$mp" 2>/dev/null; then
            sudo umount -lf "$mp" 2>/dev/null || true
        fi
    done
    if [[ -f "${base}/loop_device" ]]; then
        sudo losetup -d "$(cat "${base}/loop_device")" 2>/dev/null || true
    fi
}

cmd_clean() {
    local target="${1:-build}"

    case "$target" in
        build)
            log "卸载残留挂载..."
            unmount_stale_build_mounts
            log "清理构建目录..."
            sudo rm -rf "${SCRIPT_DIR}/build"
            rm -rf "${SCRIPT_DIR}/output" 2>/dev/null || sudo rm -rf "${SCRIPT_DIR}/output"
            rm -rf /tmp/clawbox-build 2>/dev/null || sudo rm -rf /tmp/clawbox-build
            info "构建产物已清理"
            ;;
        all)
            log "卸载残留挂载..."
            unmount_stale_build_mounts
            log "清理所有（含缓存）..."
            sudo rm -rf "${SCRIPT_DIR}/build"
            rm -rf "${SCRIPT_DIR}/output" "${SCRIPT_DIR}/build-cache" /tmp/clawbox-build 2>/dev/null || \
                sudo rm -rf "${SCRIPT_DIR}/output" "${SCRIPT_DIR}/build-cache" /tmp/clawbox-build
            info "所有构建产物和缓存已清理"
            ;;
        help|*)
            echo "用法: ./start.sh clean [all]"
            echo "  build   清理构建产物（保留缓存）"
            echo "  all     清理所有（含缓存）"
            ;;
    esac
}

# ========== 运行命令 ==========
cmd_run() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        qemu) run_qemu "$@" ;;
        check) run_check "$@" ;;
        help|*) show_run_help ;;
    esac
}

show_run_help() {
    cat << 'EOF'
运行子命令:
  run qemu          用 QEMU 启动已构建的镜像
  run check         检查虚拟机内服务是否就绪（在宿主机执行）

选项 (run qemu):
  --image PATH          指定镜像文件（默认自动选择 output/ 中最新的）
  --type TYPE           镜像类型: auto | img | iso (默认: auto，优先 img)
  -m, --memory SIZE     内存 MB (默认: 4096)
  --cpus N              CPU 核心数 (默认: 2)
  --port PORT           Web UI 端口转发 (默认: 20060)
  --ssh-port PORT       SSH 端口转发 (默认: 2222)
  --disk-size SIZE      ISO 模式虚拟盘大小 (默认: 8G)
  --uefi                使用 UEFI 启动
  --no-kvm              禁用 KVM 加速
  --nographic           无图形界面，输出到终端
  --display TYPE        显示后端: gtk | sdl | none (默认: gtk)
  --output-dir DIR      镜像搜索目录 (默认: ./output)

示例:
  ./start.sh run qemu
  ./start.sh run qemu --type iso
  ./start.sh run qemu --image ./output/clawbox-1.0.0-amd64.iso
  ./start.sh run qemu -m 8192 --cpus 4 --uefi

选项 (run check):
  --port PORT           Web UI 端口 (默认: 20060)
  --ssh-port PORT       SSH 端口 (默认: 2222)
  --timeout SEC         最长等待秒数 (默认: 0，只检查一次)
  --interval SEC        轮询间隔 (默认: 5)

示例:
  ./start.sh run check
  ./start.sh run check --timeout 600 --interval 10
EOF
}

run_check() {
    local port="20060"
    local ssh_port="2222"
    local timeout="0"
    local interval="5"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --port) port="$2"; shift 2 ;;
            --ssh-port) ssh_port="$2"; shift 2 ;;
            --timeout) timeout="$2"; shift 2 ;;
            --interval) interval="$2"; shift 2 ;;
            -h|--help) show_run_help; exit 0 ;;
            *) err "未知选项: $1\n运行 './start.sh run check --help' 查看帮助" ;;
        esac
    done

    local url="http://localhost:${port}/health"
    local start_ts
    start_ts=$(date +%s)

    log "检查 ClawBox 服务 (Web: ${url}, SSH: localhost:${ssh_port})"
    echo ""

    while true; do
        local web_ok=false ssh_ok=false docker_ok=false

        if curl -sf --max-time 3 "$url" >/dev/null 2>&1; then
            web_ok=true
            info "Web UI: 就绪 (${url})"
        else
            warn "Web UI: 未响应"
        fi

        if ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
            -p "$ssh_port" clawbox@localhost "exit" >/dev/null 2>&1; then
            ssh_ok=true
            info "SSH:    就绪 (ssh -p ${ssh_port} clawbox@localhost)"

            if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
                -p "$ssh_port" clawbox@localhost \
                "docker ps --format '{{.Names}}' 2>/dev/null | grep -q proxyclaw" >/dev/null 2>&1; then
                docker_ok=true
                info "Docker: proxyclaw 容器运行中"
            else
                warn "Docker: proxyclaw 尚未启动（首次启动需加载镜像，约 5-15 分钟）"
            fi
        else
            warn "SSH:    未响应"
        fi

        if [[ "$web_ok" == true ]]; then
            echo ""
            info "服务已就绪，可访问 http://localhost:${port}"
            exit 0
        fi

        if [[ "$timeout" == "0" ]]; then
            echo ""
            warn "服务尚未就绪"
            echo "  若虚拟机卡在引导界面，当前 ISO 无法完成启动，请改用磁盘镜像:"
            echo "    sudo ./start.sh build os --no-proxyclaw"
            echo "    ./start.sh run qemu --type img"
            exit 1
        fi

        local now_ts elapsed
        now_ts=$(date +%s)
        elapsed=$((now_ts - start_ts))
        if [[ "$elapsed" -ge "$timeout" ]]; then
            echo ""
            err "超时 (${timeout}s)，服务未就绪"
        fi

        log "等待 ${interval}s 后重试... (${elapsed}/${timeout}s)"
        sleep "$interval"
    done
}

find_latest_image() {
    local dir="$1"
    local pattern="$2"
    local latest=""

    shopt -s nullglob
    local files=("${dir}"/${pattern})
    shopt -u nullglob

    for f in "${files[@]}"; do
        if [[ -z "$latest" || "$f" -nt "$latest" ]]; then
            latest="$f"
        fi
    done

    echo "$latest"
}

resolve_qemu_image() {
    local image="$1"
    local image_type="$2"
    local search_dir="$3"

    if [[ -n "$image" ]]; then
        [[ -f "$image" ]] || err "镜像不存在: $image"
        echo "$image"
        return
    fi

    [[ -d "$search_dir" ]] || err "输出目录不存在: $search_dir\n请先运行 ./start.sh build os 或 ./start.sh build iso"

    local selected=""
    case "$image_type" in
        img)
            selected="$(find_latest_image "$search_dir" "*.img.gz")"
            [[ -z "$selected" ]] && selected="$(find_latest_image "$search_dir" "*.img")"
            ;;
        iso)
            selected="$(find_latest_image "$search_dir" "*.iso")"
            ;;
        auto)
            selected="$(find_latest_image "$search_dir" "*.img.gz")"
            [[ -z "$selected" ]] && selected="$(find_latest_image "$search_dir" "*.img")"
            [[ -z "$selected" ]] && selected="$(find_latest_image "$search_dir" "*.iso")"
            ;;
        *)
            err "未知镜像类型: $image_type (可选: auto, img, iso)"
            ;;
    esac

    [[ -n "$selected" ]] || err "未找到可用镜像，请先构建:\n  ./start.sh build os\n  ./start.sh build iso"
    echo "$selected"
}

prepare_disk_image() {
    local source="$1"
    local qemu_dir="$2"
    local dest="${qemu_dir}/clawbox.img"

    mkdir -p "$qemu_dir"

    if [[ "$source" == *.img.gz ]]; then
        if [[ ! -f "$dest" || "$source" -nt "$dest" ]]; then
            log "解压磁盘镜像..."
            gunzip -c "$source" > "$dest"
        fi
        echo "$dest"
    else
        echo "$source"
    fi
}

run_qemu() {
    local image=""
    local image_type="auto"
    local memory="4096"
    local cpus="2"
    local port="20060"
    local ssh_port="2222"
    local disk_size="8G"
    local uefi=false
    local kvm=true
    local nographic=false
    local display="gtk"
    local search_dir="${OUTPUT_DIR}"
    local qemu_dir="${SCRIPT_DIR}/.qemu"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --image) image="$2"; shift 2 ;;
            --type) image_type="$2"; shift 2 ;;
            -m|--memory) memory="$2"; shift 2 ;;
            --cpus) cpus="$2"; shift 2 ;;
            --port) port="$2"; shift 2 ;;
            --ssh-port) ssh_port="$2"; shift 2 ;;
            --disk-size) disk_size="$2"; shift 2 ;;
            --uefi) uefi=true; shift ;;
            --no-kvm) kvm=false; shift ;;
            --nographic) nographic=true; shift ;;
            --display) display="$2"; shift 2 ;;
            --output-dir) search_dir="$2"; shift 2 ;;
            -h|--help) show_run_help; exit 0 ;;
            *) err "未知选项: $1\n运行 './start.sh run qemu --help' 查看帮助" ;;
        esac
    done

    command -v qemu-system-x86_64 >/dev/null 2>&1 || err "未安装 QEMU，请运行: sudo apt install qemu-system-x86 qemu-utils ovmf"

    local source_image
    source_image="$(resolve_qemu_image "$image" "$image_type" "$search_dir")"

    local -a qemu_args=(
        -name clawbox
        -m "$memory"
        -smp "$cpus"
        -netdev "user,id=net0,hostfwd=tcp::${port}-:20060,hostfwd=tcp::${ssh_port}-:22"
        -device virtio-net-pci,netdev=net0
    )

    if [[ "$kvm" == true ]] && [[ -r /dev/kvm ]]; then
        qemu_args+=(-enable-kvm)
    elif [[ "$kvm" == true ]]; then
        warn "KVM 不可用，使用软件模拟（可加 --no-kvm 跳过此提示）"
    fi

    if [[ "$nographic" == true ]]; then
        qemu_args+=(-nographic)
    else
        qemu_args+=(-vga virtio -display "$display")
    fi

    if [[ "$uefi" == true ]]; then
        local ovmf_code=""
        for candidate in \
            /usr/share/OVMF/OVMF_CODE.fd \
            /usr/share/OVMF/OVMF_CODE_4M.fd \
            /usr/share/edk2/ovmf/OVMF_CODE.fd; do
            if [[ -f "$candidate" ]]; then
                ovmf_code="$candidate"
                break
            fi
        done
        [[ -n "$ovmf_code" ]] || err "未找到 OVMF 固件，请运行: sudo apt install ovmf"

        local ovmf_vars="${qemu_dir}/OVMF_VARS.fd"
        mkdir -p "$qemu_dir"
        if [[ ! -f "$ovmf_vars" ]]; then
            for candidate in \
                /usr/share/OVMF/OVMF_VARS.fd \
                /usr/share/OVMF/OVMF_VARS_4M.fd \
                /usr/share/edk2/ovmf/OVMF_VARS.fd; do
                if [[ -f "$candidate" ]]; then
                    cp "$candidate" "$ovmf_vars"
                    break
                fi
            done
        fi
        [[ -f "$ovmf_vars" ]] || err "未找到 OVMF_VARS.fd，请运行: sudo apt install ovmf"

        qemu_args+=(
            -drive "if=pflash,format=raw,readonly=on,file=${ovmf_code}"
            -drive "if=pflash,format=raw,file=${ovmf_vars}"
        )
    fi

    local boot_mode=""
    if [[ "$source_image" == *.iso ]]; then
        boot_mode="iso"
        echo ""
        warn "当前 ISO 仅含引导文件，不含完整系统（rootfs 未写入 ISO）"
        warn "内核会等待 /dev/sda1 根分区，空虚拟盘会导致引导卡住"
        warn "虚拟机测试请改用磁盘镜像:"
        echo "    sudo ./start.sh build os --no-proxyclaw"
        echo "    ./start.sh run qemu --type img"
        echo ""
        warn "服务就绪后在宿主机执行: ./start.sh run check"
        echo ""
    else
        boot_mode="img"
    fi

    log "启动 QEMU (${boot_mode})"
    info "镜像: $source_image"
    info "Web UI: http://localhost:${port}"
    info "SSH:    ssh -p ${ssh_port} clawbox@localhost"
    echo ""

    if [[ "$boot_mode" == "iso" ]]; then
        local data_disk="${qemu_dir}/clawbox-disk.qcow2"
        mkdir -p "$qemu_dir"
        if [[ ! -f "$data_disk" ]]; then
            log "创建虚拟硬盘 (${disk_size})..."
            qemu-img create -f qcow2 "$data_disk" "$disk_size" >/dev/null
        fi

        exec qemu-system-x86_64 \
            "${qemu_args[@]}" \
            -cdrom "$source_image" \
            -drive "file=${data_disk},format=qcow2,if=virtio" \
            -boot d
    else
        local disk_image
        disk_image="$(prepare_disk_image "$source_image" "$qemu_dir")"

        exec qemu-system-x86_64 \
            "${qemu_args[@]}" \
            -drive "file=${disk_image},format=raw,if=ide,index=0,media=disk" \
            -boot c
    fi
}

# ========== 列出命令 ==========
cmd_list() {
    log "已构建的镜像:"
    echo ""

    local found=false

    if [ -d "${OUTPUT_DIR}" ]; then
        for f in "${OUTPUT_DIR}"/*.img.gz "${OUTPUT_DIR}"/*.iso; do
            if [ -f "$f" ]; then
                local size=$(du -sh "$f" | cut -f1)
                local name=$(basename "$f")
                printf "  %-45s %s\n" "$name" "$size"
                found=true
            fi
        done
    fi

    if [ "$found" = false ]; then
        warn "未找到已构建的镜像"
        echo "  使用 ./start.sh build iso 开始构建"
    fi
}

# ========== 主入口 ==========
main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        build)
            cmd_build "$@"
            ;;
        clean)
            cmd_clean "$@"
            ;;
        list)
            cmd_list
            ;;
        run)
            cmd_run "$@"
            ;;
        -h|--help|help)
            show_help
            ;;
        -v|--version)
            show_version
            ;;
        *)
            err "未知命令: $command\n运行 './start.sh --help' 查看帮助"
            ;;
    esac
}

main "$@"
