#!/bin/bash
# ============================================================
# ClawBox 统一入口脚本
# 用法: ./start.sh <命令> [参数...]
# ============================================================

set -euo pipefail

# ========== 配置 ==========
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_DIR="${SCRIPT_DIR}/image"
OUTPUT_DIR="${SCRIPT_DIR}/output"

# 加载环境变量
if [ -f "${SCRIPT_DIR}/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/.env"
    set +a
fi
VERSION="${CLAWBOX_VERSION:-1.0.0}"

# ========== 颜色 ==========
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ========== 工具函数 ==========
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
log()   { echo -e "${BLUE}[i]${NC} $*"; }

show_version() {
    echo "ClawBox v${VERSION}"
}

# ========== 主帮助 (命令列表) ==========
show_usage() {
    cat << EOF
${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗
║                   ClawBox Build System                       ║
╚══════════════════════════════════════════════════════════════╝${NC}

用法: ${BOLD}./start.sh <命令> [子命令] [参数...]${NC}

${BOLD}构 建 命 令:${NC}
  ${GREEN}build os${NC}          构建磁盘镜像 (.img.gz)，可直接 dd 烧录
  ${GREEN}build iso${NC}         构建安装镜像 (.iso)，支持 Ventoy/Rufus
  ${GREEN}build docker${NC}      构建 Docker 镜像，用于开发测试
  ${GREEN}build all${NC}         依次构建 os → iso → docker 三种镜像

${BOLD}运 行 命 令:${NC}
  ${GREEN}run qemu${NC}          用 QEMU 启动已构建的镜像
  ${GREEN}run check${NC}         检查虚拟机内 ClawBox 服务是否就绪

${BOLD}开 发 命 令:${NC}
  ${GREEN}debug os${NC}          Debug 模式构建磁盘镜像并启动 QEMU
  ${GREEN}debug iso${NC}         Debug 模式构建 ISO 并启动 QEMU

${BOLD}管 理 命 令:${NC}
  ${GREEN}clean${NC} [all]       清理构建产物（加 all 清理缓存）
  ${GREEN}list${NC}              列出 output/ 中已构建的镜像及大小

${BOLD}其 他:${NC}
  ${GREEN}-h, --help${NC}        显示本帮助
  ${GREEN}-v, --version${NC}     显示版本信息
  ${GREEN}-w, init${NC}          初始化向导，交互式配置环境

使用 ${BOLD}./start.sh <命令> --help${NC} 查看各命令的详细参数。
EOF
}
show_help() { show_usage; }

# ========== 构建命令帮助 ==========
show_build_help() {
    cat << EOF
${BOLD}用法: ./start.sh build <os|iso|docker|all> [选项...]${NC}

${BOLD}构 建 选 项:${NC}
  ${GREEN}-p, --proxyclaw-path${NC} PATH     本地 proxyclaw 源码路径
  ${GREEN}--proxyclaw-repo${NC} URL          指定 GitHub 仓库地址
  ${GREEN}--proxyclaw-branch${NC} BR         分支名 (默认: main)
  ${GREEN}--no-proxyclaw${NC}                从 Docker Hub 拉取镜像，跳过编译
  ${GREEN}--no-cache${NC}                    不使用缓存，强制全量重建
  ${GREEN}--output-dir${NC} DIR              输出目录 (默认: ./output)
  ${GREEN}--with-ollama${NC}                 内置 Ollama（镜像约增大 3GB）

${BOLD}示 例:${NC}
  sudo ./start.sh build iso --no-proxyclaw
  sudo ./start.sh build os -p /home/user/proxyclaw
  sudo ./start.sh build all --no-proxyclaw --with-ollama
EOF
}

# ========== 运行命令帮助 ==========
show_run_help() {
    cat << EOF
${BOLD}用法: ./start.sh run <qemu|check> [选项...]${NC}

${BOLD}run qemu${NC} - 用 QEMU 启动已构建的镜像
  ${GREEN}--image${NC} PATH        指定镜像文件（默认自动选 output/ 中最新的）
  ${GREEN}--type${NC} TYPE         镜像类型: auto | img | iso (默认: auto)
  ${GREEN}-m, --memory${NC} SIZE   内存 MB (默认: 4096)
  ${GREEN}--cpus${NC} N             CPU 核心数 (默认: 2)
  ${GREEN}--port${NC} PORT         Web UI 端口 (默认: 20060)
  ${GREEN}--ssh-port${NC} PORT     SSH 端口 (默认: 2222)
  ${GREEN}--disk-size${NC} SIZE    ISO 模式虚拟盘 (默认: 8G)
  ${GREEN}--uefi${NC}              使用 UEFI 启动
  ${GREEN}--no-kvm${NC}            禁用 KVM 加速
  ${GREEN}--nographic${NC}         无图形窗口
  ${GREEN}--display${NC} TYPE      显示后端: gtk | sdl | none (默认: gtk)

${BOLD}run check${NC} - 检查虚拟机内服务是否就绪
  ${GREEN}--port${NC} PORT         Web UI 端口 (默认: 20060)
  ${GREEN}--ssh-port${NC} PORT     SSH 端口 (默认: 2222)
  ${GREEN}--timeout${NC} SEC       最长等待秒数 (默认: 0，仅查一次)
  ${GREEN}--interval${NC} SEC      轮询间隔秒数 (默认: 5)

${BOLD}示 例:${NC}
  ./start.sh run qemu
  ./start.sh run qemu -m 8192 --cpus 4 --uefi
  ./start.sh run check --timeout 600 --interval 10
EOF
}

# ========== qemu 帮助 ==========
show_qemu_help() {
    cat << EOF
${BOLD}用法: ./start.sh run qemu [选项...]${NC}

${BOLD}选 项:${NC}
  ${GREEN}--image${NC} PATH        指定镜像文件（默认自动选 output/ 中最新的）
  ${GREEN}--type${NC} TYPE         镜像类型: auto | img | iso (默认: auto)
  ${GREEN}-m, --memory${NC} SIZE   内存 MB (默认: 4096)
  ${GREEN}--cpus${NC} N             CPU 核心数 (默认: 2)
  ${GREEN}--port${NC} PORT         Web UI 端口 (默认: 20060)
  ${GREEN}--ssh-port${NC} PORT     SSH 端口 (默认: 2222)
  ${GREEN}--disk-size${NC} SIZE    ISO 模式虚拟盘 (默认: 8G)
  ${GREEN}--uefi${NC}              使用 UEFI 启动
  ${GREEN}--no-kvm${NC}            禁用 KVM 加速
  ${GREEN}--nographic${NC}         无图形窗口
  ${GREEN}--display${NC} TYPE      显示后端: gtk | sdl | none (默认: gtk)

${BOLD}示 例:${NC}
  ./start.sh run qemu -m 2048 --nographic
  ./start.sh run qemu -m 8192 --cpus 4 --uefi
  ./start.sh run qemu --image ./output/clawbox-1.0.0-amd64.iso
EOF
}

# ========== check 帮助 ==========
show_check_help() {
    cat << EOF
${BOLD}用法: ./start.sh run check [选项...]${NC}

${BOLD}选 项:${NC}
  ${GREEN}--port${NC} PORT         Web UI 端口 (默认: 20060)
  ${GREEN}--ssh-port${NC} PORT     SSH 端口 (默认: 2222)
  ${GREEN}--timeout${NC} SEC       最长等待秒数 (默认: 0，仅查一次)
  ${GREEN}--interval${NC} SEC      轮询间隔秒数 (默认: 5)

${BOLD}示 例:${NC}
  ./start.sh run check
  ./start.sh run check --timeout 300
  ./start.sh run check --timeout 600 --interval 10
EOF
}

# ========== clean 帮助 ==========
show_clean_help() {
    cat << EOF
${BOLD}用法: ./start.sh clean [all]${NC}

${BOLD}参 数:${NC}
  (无参数)    清理构建产物 (build/、output/、/tmp/clawbox-build)
  all         完全清理，含构建缓存 (build-cache/)

${BOLD}示 例:${NC}
  ./start.sh clean
  ./start.sh clean all
EOF
}

# ========== debug 帮助 ==========
show_debug_help() {
    cat << EOF
${BOLD}用法: ./start.sh debug <os|iso> [选项...]${NC}

${BOLD}Debug 模式会强制全量重建并启动 QEMU 进行调试。${NC}

${BOLD}构 建 选 项:${NC}
  ${GREEN}-p, --proxyclaw-path${NC} PATH     本地 proxyclaw 源码路径
  ${GREEN}--proxyclaw-repo${NC} URL          指定 GitHub 仓库地址
  ${GREEN}--proxyclaw-branch${NC} BR         分支名 (默认: main)
  ${GREEN}--no-proxyclaw${NC}                从 Docker Hub 拉取镜像，跳过编译
  ${GREEN}--output-dir${NC} DIR              输出目录 (默认: ./output)
  ${GREEN}--with-ollama${NC}                 内置 Ollama

${BOLD}QEMU 选 项:${NC}
  ${GREEN}-m, --memory${NC} SIZE   内存 MB (默认: 4096)
  ${GREEN}--cpus${NC} N             CPU 核心数 (默认: 2)
  ${GREEN}--port${NC} PORT         Web UI 端口 (默认: 20060)
  ${GREEN}--ssh-port${NC} PORT     SSH 端口 (默认: 2222)
  ${GREEN}--no-kvm${NC}            禁用 KVM 加速

${BOLD}示 例:${NC}
  sudo ./start.sh debug os --no-proxyclaw
  sudo ./start.sh debug iso -p /home/user/proxyclaw -m 8192
EOF
}

# ========== init 帮助 ==========
show_init_help() {
    cat << EOF
${BOLD}用法: ./start.sh init 或 ./start.sh -w${NC}

${BOLD}初始化向导会引导你完成首次配置:${NC}
  1. 检查系统依赖 (Docker, QEMU 等)
  2. 创建 .env 配置文件
  3. 交互式填写必填配置项 (管理员密码、API Key 等)

${BOLD}示 例:${NC}
  ./start.sh init
  ./start.sh -w
EOF
}

# ========== build-os ==========
cmd_build_os() {
    for a in "$@"; do case "$a" in -h|--help) show_build_help; exit 0 ;; esac; done
    log "构建磁盘镜像..."
    sudo "${IMAGE_DIR}/build-os.sh" --output-dir "${OUTPUT_DIR}" "$@"
}

# ========== build-iso ==========
cmd_build_iso() {
    for a in "$@"; do case "$a" in -h|--help) show_build_help; exit 0 ;; esac; done
    log "构建 ISO 安装镜像..."
    sudo "${IMAGE_DIR}/build-iso.sh" --output-dir "${OUTPUT_DIR}" "$@"
}

# ========== build-docker ==========
cmd_build_docker() {
    for a in "$@"; do case "$a" in -h|--help) show_build_help; exit 0 ;; esac; done
    log "构建 Docker 镜像..."
    "${IMAGE_DIR}/build.sh" docker
}

# ========== build-all ==========
cmd_build_all() {
    for a in "$@"; do case "$a" in -h|--help) show_build_help; exit 0 ;; esac; done
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

# ========== qemu ==========
find_latest_image() {
    local dir="$1"
    local pattern="$2"
    local latest=""
    shopt -s nullglob
    local files=("${dir}"/${pattern})
    shopt -u nullglob
    for f in "${files[@]}"; do
        [[ -z "$latest" || "$f" -nt "$latest" ]] && latest="$f"
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
        *)  err "未知镜像类型: $image_type (可选: auto, img, iso)" ;;
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

cmd_qemu() {
    local image="" image_type="auto" memory="4096" cpus="2"
    local port="20060" ssh_port="2222" disk_size="8G"
    local uefi=false kvm=true nographic=false display="gtk"
    local search_dir="${OUTPUT_DIR}" qemu_dir="${SCRIPT_DIR}/.qemu"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --image)       image="$2"; shift 2 ;;
            --type)        image_type="$2"; shift 2 ;;
            -m|--memory)   memory="$2"; shift 2 ;;
            --cpus)        cpus="$2"; shift 2 ;;
            --port)        port="$2"; shift 2 ;;
            --ssh-port)    ssh_port="$2"; shift 2 ;;
            --disk-size)   disk_size="$2"; shift 2 ;;
            --uefi)        uefi=true; shift ;;
            --no-kvm)      kvm=false; shift ;;
            --nographic)   nographic=true; shift ;;
            --display)     display="$2"; shift 2 ;;
            -h|--help)     show_qemu_help; exit 0 ;;
            *) err "未知选项: $1\n运行 './start.sh run qemu --help' 查看帮助" ;; 
        esac
    done

    command -v qemu-system-x86_64 >/dev/null 2>&1 || err "未安装 QEMU，请运行: sudo apt install qemu-system-x86 qemu-utils ovmf"

    local source_image
    source_image="$(resolve_qemu_image "$image" "$image_type" "$search_dir")"

    local -a qemu_args=(
        -name clawbox -m "$memory" -smp "$cpus"
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
        for candidate in /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
            [[ -f "$candidate" ]] && { ovmf_code="$candidate"; break; }
        done
        [[ -n "$ovmf_code" ]] || err "未找到 OVMF 固件，请运行: sudo apt install ovmf"

        local ovmf_vars="${qemu_dir}/OVMF_VARS.fd"
        mkdir -p "$qemu_dir"
        if [[ ! -f "$ovmf_vars" ]]; then
            for candidate in /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/edk2/ovmf/OVMF_VARS.fd; do
                [[ -f "$candidate" ]] && { cp "$candidate" "$ovmf_vars"; break; }
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
        warn "虚拟机测试请改用磁盘镜像:"
        echo "    sudo ./start.sh build os --no-proxyclaw"
        echo "    ./start.sh run qemu"
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
        [[ ! -f "$data_disk" ]] && { log "创建虚拟硬盘 (${disk_size})..."; qemu-img create -f qcow2 "$data_disk" "$disk_size" >/dev/null; }
        exec qemu-system-x86_64 "${qemu_args[@]}" -cdrom "$source_image" -drive "file=${data_disk},format=qcow2,if=virtio" -boot d
    else
        local disk_image
        disk_image="$(prepare_disk_image "$source_image" "$qemu_dir")"
        exec qemu-system-x86_64 "${qemu_args[@]}" -drive "file=${disk_image},format=raw,if=ide,index=0,media=disk" -boot c
    fi
}

# ========== check ==========
cmd_check() {
    local port="20060" ssh_port="2222" timeout="0" interval="5"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --port)       port="$2"; shift 2 ;;
            --ssh-port)   ssh_port="$2"; shift 2 ;;
            --timeout)    timeout="$2"; shift 2 ;;
            --interval)   interval="$2"; shift 2 ;;
            -h|--help)    show_check_help; exit 0 ;;
            *) err "未知选项: $1\n运行 './start.sh run check --help' 查看帮助" ;; 
        esac
    done

    local url="http://localhost:${port}/health"
    local start_ts
    start_ts=$(date +%s)

    log "检查 ClawBox 服务 (Web: ${url}, SSH: localhost:${ssh_port})"
    echo ""

    while true; do
        local web_ok=false

        if curl -sf --max-time 3 "$url" >/dev/null 2>&1; then
            web_ok=true
            info "Web UI: 就绪 (${url})"
        else
            warn "Web UI: 未响应"
        fi

        if ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
            -p "$ssh_port" clawbox@localhost "exit" >/dev/null 2>&1; then
            info "SSH:    就绪 (ssh -p ${ssh_port} clawbox@localhost)"
            if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
                -p "$ssh_port" clawbox@localhost \
                "docker ps --format '{{.Names}}' 2>/dev/null | grep -q proxyclaw" >/dev/null 2>&1; then
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
            echo "  若虚拟机卡在引导界面，请改用磁盘镜像:"
            echo "    sudo ./start.sh build os --no-proxyclaw"
            echo "    ./start.sh run qemu"
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

# ========== clean ==========
unmount_stale_build_mounts() {
    local base="${SCRIPT_DIR}/build"
    for mp in "${base}/mnt" "${base}/rootfs"; do
        for sub in dev/pts sys proc dev; do
            mountpoint -q "${mp}/${sub}" 2>/dev/null && sudo umount -lf "${mp}/${sub}" 2>/dev/null || true
        done
        mountpoint -q "$mp" 2>/dev/null && sudo umount -lf "$mp" 2>/dev/null || true
    done
    [[ -f "${base}/loop_device" ]] && sudo losetup -d "$(cat "${base}/loop_device")" 2>/dev/null || true
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
            info "构建产物已清理（缓存已保留）"
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
        -h|--help)
            show_clean_help; exit 0 ;;
        *)
            err "未知参数: $target\n运行 './start.sh clean --help' 查看帮助" ;;
    esac
}

# ========== list ==========
cmd_list() {
    log "已构建的镜像:"
    echo ""
    local found=false
    if [ -d "${OUTPUT_DIR}" ]; then
        for f in "${OUTPUT_DIR}"/*.img.gz "${OUTPUT_DIR}"/*.iso; do
            if [ -f "$f" ]; then
                local size
                size=$(du -sh "$f" | cut -f1)
                printf "  %-45s %s\n" "$(basename "$f")" "$size"
                found=true
            fi
        done
    fi
    if [ "$found" = false ]; then
        warn "未找到已构建的镜像"
        echo "  使用 ./start.sh build iso 开始构建"
    fi
}

# ========== init (初始化向导) ==========
cmd_init() {
    for a in "$@"; do case "$a" in -h|--help) show_init_help; exit 0 ;; esac; done

    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗"
    echo -e "║              ClawBox 初始化向导                              ║"
    echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Step 1: Check prerequisites
    log "检查系统依赖..."
    echo ""

    local deps_ok=true

    # Docker
    if command -v docker >/dev/null 2>&1; then
        if docker info >/dev/null 2>&1; then
            info "Docker:   已安装且可运行 ($(docker --version))"
        else
            warn "Docker:   已安装但无权限，请将当前用户加入 docker 组"
            deps_ok=false
        fi
    else
        warn "Docker:   未安装，请先安装 Docker"
        echo "          Ubuntu: sudo apt install docker.io"
        echo "          macOS:  brew install docker"
        deps_ok=false
    fi

    # QEMU
    if command -v qemu-system-x86_64 >/dev/null 2>&1; then
        info "QEMU:     已安装 ($(qemu-system-x86_64 --version 2>&1 | head -1))"
    else
        warn "QEMU:     未安装 (构建镜像非必须，调试运行时需要)"
        echo "          Ubuntu: sudo apt install qemu-system-x86 qemu-utils ovmf"
    fi

    # sudo
    if command -v sudo >/dev/null 2>&1; then
        info "sudo:     可用"
    else
        warn "sudo:     未安装 (构建磁盘/ISO 镜像需要)"
        deps_ok=false
    fi

    # curl
    if command -v curl >/dev/null 2>&1; then
        info "curl:     可用"
    else
        warn "curl:     未安装"
    fi

    # git
    if command -v git >/dev/null 2>&1; then
        info "git:      可用 ($(git --version))"
    else
        warn "git:      未安装"
    fi

    echo ""

    if [[ "$deps_ok" == false ]]; then
        warn "存在未满足的依赖，请安装后再继续"
        exit 1
    fi

    # Step 2: Configure .env
    local env_file="${SCRIPT_DIR}/.env"
    local env_example="${SCRIPT_DIR}/.env.example"

    if [[ -f "$env_file" ]]; then
        log ".env 配置文件已存在: $env_file"
        echo ""
        read -r -p "是否重新配置? (会覆盖现有配置) [y/N]: " reconf
        if [[ ! "$reconf" =~ ^[Yy]$ ]]; then
            info "保持现有配置，跳过配置步骤"
            echo ""
            show_wizard_summary
            return
        fi
    fi

    # Load or create .env.example
    if [[ ! -f "$env_example" ]]; then
        log "未找到 .env.example，创建最小 .env 配置..."
        cat > "$env_file" << 'INNEREOF'
# ClawBox 环境变量配置

# ========== 设备信息 ==========
DEVICE_ID=clawbox-001
CLAWBOX_VERSION=1.0.0

# ========== 网络 ==========
PROXYCLAW_PORT=20060

# ========== 数据库 ==========
PG_PASSWORD=

# ========== 管理员 ==========
ADMIN_USERNAME=admin
ADMIN_PASSWORD=

# ========== OTA ==========
OTA_SERVER=https://ota.clawbox.ai

# ========== LLM API Keys (至少填一个) ==========
# OPENAI_API_KEY=sk-xxx
# DEEPSEEK_API_KEY=sk-xxx
# DASHSCOPE_API_KEY=sk-xxx

# ========== 镜像 ==========
PROXYCLAW_IMAGE=proxyclaw:latest
OTA_IMAGE=clawbox/ota-agent:latest

# ========== 日志 ==========
LOG_LEVEL=info
INNEREOF
    else
        cp "$env_example" "$env_file"
    fi

    echo ""
    log "交互式配置 .env (回车保留默认值)..."
    echo ""

    # Device ID
    read -r -p "设备 ID [$DEVICE_ID]: " input
    [[ -n "$input" ]] && sed -i '' "s/^DEVICE_ID=.*/DEVICE_ID=${input}/" "$env_file" 2>/dev/null || \
        sed -i "s/^DEVICE_ID=.*/DEVICE_ID=${input}/" "$env_file"

    # Version
    read -r -p "版本号 [$VERSION]: " input
    [[ -n "$input" ]] && sed -i '' "s/^CLAWBOX_VERSION=.*/CLAWBOX_VERSION=${input}/" "$env_file" 2>/dev/null || \
        sed -i "s/^CLAWBOX_VERSION=.*/CLAWBOX_VERSION=${input}/" "$env_file"

    # Admin username
    read -r -p "管理员用户名 [admin]: " input
    [[ -n "$input" ]] && sed -i '' "s/^ADMIN_USERNAME=.*/ADMIN_USERNAME=${input}/" "$env_file" 2>/dev/null || \
        sed -i "s/^ADMIN_USERNAME=.*/ADMIN_USERNAME=${input}/" "$env_file"

    # Admin password (required)
    echo ""
    log "管理员密码 (必填，Web UI 登录凭据):"
    read -r -s -p "  密码: " admin_pw
    echo ""
    if [[ -n "$admin_pw" ]]; then
        sed -i '' "s/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=${admin_pw}/" "$env_file" 2>/dev/null || \
            sed -i "s/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=${admin_pw}/" "$env_file"
        info "管理员密码已设置"
    else
        warn "管理员密码未设置，请在 .env 中手动填写"
    fi

    # PG Password
    local pg_pw
    pg_pw=$(openssl rand -base64 24 2>/dev/null || echo "change-me-$(date +%s)")
    sed -i '' "s/^PG_PASSWORD=.*/PG_PASSWORD=${pg_pw}/" "$env_file" 2>/dev/null || \
        sed -i "s/^PG_PASSWORD=.*/PG_PASSWORD=${pg_pw}/" "$env_file"
    info "数据库密码已自动生成"

    # API Key
    echo ""
    log "LLM API Key (至少配置一个，回车跳过):"
    read -r -p "  OPENAI_API_KEY [留空跳过]: " input
    if [[ -n "$input" ]]; then
        sed -i '' "s|^# OPENAI_API_KEY=.*|OPENAI_API_KEY=${input}|" "$env_file" 2>/dev/null || \
            sed -i "s|^# OPENAI_API_KEY=.*|OPENAI_API_KEY=${input}|" "$env_file"
    fi

    read -r -p "  DEEPSEEK_API_KEY [留空跳过]: " input
    if [[ -n "$input" ]]; then
        sed -i '' "s|^# DEEPSEEK_API_KEY=.*|DEEPSEEK_API_KEY=${input}|" "$env_file" 2>/dev/null || \
            sed -i "s|^# DEEPSEEK_API_KEY=.*|DEEPSEEK_API_KEY=${input}|" "$env_file"
    fi

    echo ""
    info ".env 配置文件已保存: $env_file"
    echo ""

    show_wizard_summary
}

show_wizard_summary() {
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  初始化完成!${NC}"
    echo ""
    echo "  下一步:"
    echo -e "    ${GREEN}./start.sh build iso --no-proxyclaw${NC}   构建 ISO 镜像"
    echo -e "    ${GREEN}./start.sh build os --no-proxyclaw${NC}    构建磁盘镜像"
    echo -e "    ${GREEN}./start.sh run qemu${NC}                   启动虚拟机"
    echo -e "    ${GREEN}./start.sh run check --timeout 600${NC}    等待服务就绪"
    echo ""
    echo "  配置文件: ${SCRIPT_DIR}/.env"
    echo -e "  修改配置后重新运行: ${GREEN}./start.sh -w${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ========== debug (编译+调试运行) ==========
cmd_debug() {
    local target="${1:-help}"
    shift || true

    case "$target" in
        -h|--help|help) show_debug_help; exit 0 ;;
        os|iso) ;;
        *) err "未知 debug 目标: $target (可选: os, iso)\n运行 './start.sh debug --help' 查看帮助" ;;
    esac

    log "Debug 模式: 构建 ${target} 并启动 QEMU..."

    # 解析 QEMU 参数
    local memory="4096" cpus="2" port="20060" ssh_port="2222"
    local nographic=true kvm=true qemu_args=()
    local build_extra_args=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            -m|--memory)   memory="$2"; shift 2 ;;
            --cpus)        cpus="$2"; shift 2 ;;
            --port)        port="$2"; shift 2 ;;
            --ssh-port)    ssh_port="$2"; shift 2 ;;
            --no-kvm)      kvm=false; shift ;;
            -h|--help)     show_debug_help; exit 0 ;;
            -p|--proxyclaw-path|--proxyclaw-repo|--proxyclaw-branch|--no-proxyclaw|--output-dir|--with-ollama)
                build_extra_args+=("$1")
                # 带值参数需要额外 shift
                [[ "$1" != --no-proxyclaw && "$1" != --with-ollama ]] && { build_extra_args+=("$2"); shift; }
                shift
                ;;
            *)
                err "未知选项: $1\n运行 './start.sh debug --help' 查看帮助" ;;
        esac
    done

    # Step 1: 强制全量构建
    echo ""
    log "[1/2] 构建 ${target} (Debug, --no-cache)..."
    echo ""

    if [[ "$target" == "os" ]]; then
        sudo "${IMAGE_DIR}/build-os.sh" --output-dir "${OUTPUT_DIR}" --no-cache "${build_extra_args[@]}"
    else
        sudo "${IMAGE_DIR}/build-iso.sh" --output-dir "${OUTPUT_DIR}" --no-cache "${build_extra_args[@]}"
    fi

    # Step 2: 启动 QEMU
    echo ""
    log "[2/2] 启动 QEMU..."
    echo ""

    local image_type="$target"
    local search_dir="${OUTPUT_DIR}"

    command -v qemu-system-x86_64 >/dev/null 2>&1 || err "未安装 QEMU，请运行: sudo apt install qemu-system-x86 qemu-utils ovmf"

    local source_image
    source_image="$(resolve_qemu_image "" "$image_type" "$search_dir")"

    qemu_args=(
        -name clawbox-debug -m "$memory" -smp "$cpus"
        -netdev "user,id=net0,hostfwd=tcp::${port}-:20060,hostfwd=tcp::${ssh_port}-:22"
        -device virtio-net-pci,netdev=net0
    )

    if [[ "$kvm" == true ]] && [[ -r /dev/kvm ]]; then
        qemu_args+=(-enable-kvm)
    elif [[ "$kvm" == true ]]; then
        warn "KVM 不可用，使用软件模拟"
    fi

    if [[ "$nographic" == true ]]; then
        qemu_args+=(-nographic)
    else
        qemu_args+=(-vga virtio -display gtk)
    fi

    info "镜像: $source_image"
    info "Web UI: http://localhost:${port}"
    info "SSH:    ssh -p ${ssh_port} clawbox@localhost"
    echo ""

    if [[ "$source_image" == *.iso ]]; then
        local data_disk="${SCRIPT_DIR}/.qemu/clawbox-disk.qcow2"
        mkdir -p "${SCRIPT_DIR}/.qemu"
        [[ ! -f "$data_disk" ]] && { log "创建虚拟硬盘 (8G)..."; qemu-img create -f qcow2 "$data_disk" "8G" >/dev/null; }
        exec qemu-system-x86_64 "${qemu_args[@]}" -cdrom "$source_image" -drive "file=${data_disk},format=qcow2,if=virtio" -boot d
    else
        local disk_image
        disk_image="$(prepare_disk_image "$source_image" "${SCRIPT_DIR}/.qemu")"
        exec qemu-system-x86_64 "${qemu_args[@]}" -drive "file=${disk_image},format=raw,if=ide,index=0,media=disk" -boot c
    fi
}

# ========== build 路由 ==========
cmd_build() {
    local target="${1:-help}"
    shift || true
    case "$target" in
        os)     cmd_build_os "$@" ;;
        iso)    cmd_build_iso "$@" ;;
        docker) cmd_build_docker "$@" ;;
        all)    cmd_build_all "$@" ;;
        -h|--help|help) show_build_help ;;
        *)      err "未知构建目标: $target (可选: os, iso, docker, all)\n运行 './start.sh build --help' 查看帮助" ;;
    esac
}

# ========== run 路由 ==========
cmd_run() {
    local target="${1:-help}"
    shift || true
    case "$target" in
        qemu)  cmd_qemu "$@" ;;
        check) cmd_check "$@" ;;
        -h|--help|help) show_run_help ;;
        *)     err "未知运行命令: $target (可选: qemu, check)\n运行 './start.sh run --help' 查看帮助" ;;
    esac
}

# ========== 主入口 ==========
main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        build)          cmd_build "$@" ;;
        run)            cmd_run "$@" ;;
        debug)          cmd_debug "$@" ;;
        init)           cmd_init "$@" ;;
        clean)          cmd_clean "$@" ;;
        list)           cmd_list ;;
        -h|--help|help) show_help ;;
        -v|--version)   show_version ;;
        -w)             cmd_init "$@" ;;
        *)
            err "未知命令: $cmd\n运行 './start.sh --help' 查看帮助" ;;
    esac
}

main "$@"
