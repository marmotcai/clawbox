#!/bin/bash
# ============================================================
# ClawBox OS 构建脚本
# 基于 Debian 12 最小化系统，预装 Docker + proxyclaw
# 
# 用法: sudo ./build-os.sh [选项]
#   --output-dir       输出目录 (默认: ./output)
#   --image-size       镜像大小 (默认: 4G)
#   --hostname         主机名 (默认: clawbox)
#   -p|--proxyclaw-path PATH   proxyclaw 本地源码路径 (优先级高于 --proxyclaw-repo)
#   --proxyclaw-repo   proxyclaw GitHub 仓库地址 (默认: https://github.com/proxyclaw/proxyclaw.git)
#   --proxyclaw-branch proxyclaw 分支名 (默认: main)
#   --no-proxyclaw     不构建 proxyclaw，直接拉取远程镜像
#   --no-cache         不使用 rootfs 缓存，强制全量重建
#   --with-ollama      包含 Ollama 镜像（默认不包含）
# ============================================================

set -euo pipefail

# ========== 路径（基于脚本位置，避免 sudo 时 cwd 不一致） ==========
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ========== 默认参数 ==========
OUTPUT_DIR="${PROJECT_DIR}/output"
IMAGE_SIZE="4G"
HOSTNAME="clawbox"
CLAWBOX_VERSION="${CLAWBOX_VERSION:-1.0.0}"
WORK_DIR="${PROJECT_DIR}/build"
ROOTFS="${WORK_DIR}/rootfs"
MOUNT_POINT="${WORK_DIR}/mnt"

# proxyclaw 构建选项
PROXYCLAW_REPO="https://github.com/proxyclaw/proxyclaw.git"
PROXYCLAW_BRANCH="main"
PROXYCLAW_LOCAL_PATH=""
NO_PROXYCLAW=false
PROXYCLAW_BUILD_DIR=""  # 实际使用的构建目录

# 可选组件
WITH_OLLAMA=false

# rootfs 缓存
NO_CACHE=false
CACHE_DIR="${PROJECT_DIR}/build-cache"
ROOTFS_CACHE=""  # 在 main 中赋值

# 镜像名称
TIMESTAMP=$(date +%Y%m%d)
IMAGE_NAME="clawbox-${CLAWBOX_VERSION}-${TIMESTAMP}"
IMAGE_FILE="${OUTPUT_DIR}/${IMAGE_NAME}.img"

# ========== 颜色 ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ========== 解析参数 ==========
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --output-dir)
                OUTPUT_DIR="$2"
                if [[ "$OUTPUT_DIR" != /* ]]; then
                    OUTPUT_DIR="${PROJECT_DIR}/${OUTPUT_DIR#./}"
                fi
                shift 2
                ;;
            --image-size)       IMAGE_SIZE="$2"; shift 2 ;;
            --hostname)         HOSTNAME="$2"; shift 2 ;;
            -p|--proxyclaw-path) PROXYCLAW_LOCAL_PATH="$2"; shift 2 ;;
            --proxyclaw-repo)   PROXYCLAW_REPO="$2"; shift 2 ;;
            --proxyclaw-branch) PROXYCLAW_BRANCH="$2"; shift 2 ;;
            --no-proxyclaw)     NO_PROXYCLAW=true; shift ;;
            --no-cache)         NO_CACHE=true; shift ;;
            --with-ollama)      WITH_OLLAMA=true; shift ;;
            --help|-h)
                echo "Usage: sudo $0 [选项]"
                echo ""
                echo "基本选项:"
                echo "  --output-dir DIR        输出目录 (默认: ./output)"
                echo "  --image-size SIZE       镜像大小 (默认: 4G)"
                echo "  --hostname NAME         主机名 (默认: clawbox)"
                echo "  --no-cache              不使用 rootfs 缓存，强制全量重建"
                echo ""
                echo "proxyclaw 构建选项:"
                echo "  -p, --proxyclaw-path PATH   proxyclaw 本地源码路径 (优先级最高)"
                echo "  --proxyclaw-repo URL        proxyclaw GitHub 仓库地址"
                echo "                              (默认: https://github.com/proxyclaw/proxyclaw.git)"
                echo "  --proxyclaw-branch BR       proxyclaw 分支名 (默认: main)"
                echo "  --no-proxyclaw              跳过构建，直接拉取远程镜像"
                echo ""
                echo "可选组件:"
                echo "  --with-ollama               包含 Ollama 镜像（约 3GB）"
                echo ""
                echo "示例:"
                echo "  sudo $0 -p /path/to/proxyclaw"
                echo "  sudo $0 --proxyclaw-path /path/to/proxyclaw"
                echo "  sudo $0 --proxyclaw-branch develop"
                echo "  sudo $0 --no-proxyclaw"
                echo "  sudo $0 --no-proxyclaw --with-ollama"
                exit 0
                ;;
            *) err "Unknown option: $1" ;;
        esac
    done
    IMAGE_FILE="${OUTPUT_DIR}/${IMAGE_NAME}.img"
    ROOTFS_CACHE="${CACHE_DIR}/rootfs-${HOSTNAME}.tar.gz"
}

# ========== 权限检查 ==========
check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "此脚本需要 root 权限运行\n  请使用: sudo $0"
    fi
}

# ========== 依赖检查 ==========
check_deps() {
    info "Checking dependencies..."
    local missing=()
    for cmd in debootstrap parted mkfs.ext4 chroot; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing dependencies: ${missing[*]}"
        info "Installing..."
        apt-get update
        apt-get install -y debootstrap parted e2fsprogs
    fi
    log "Dependencies OK"
}

# ========== 清理构建目录 ==========
safe_umount() {
    local mp="$1"
    mountpoint -q "$mp" 2>/dev/null || return 0
    umount "$mp" 2>/dev/null || umount -lf "$mp" 2>/dev/null || true
}

unmount_chroot_binds() {
    local target="$1"
    [[ -d "$target" ]] || return 0
    safe_umount "${target}/dev/pts"
    safe_umount "${target}/sys"
    safe_umount "${target}/proc"
    safe_umount "${target}/dev"
}

cleanup_stale_mounts() {
    unmount_chroot_binds "$MOUNT_POINT"
    unmount_chroot_binds "$ROOTFS"
    safe_umount "$MOUNT_POINT"

    if [[ -f "${WORK_DIR}/loop_device" ]]; then
        local loop_dev
        loop_dev=$(cat "${WORK_DIR}/loop_device")
        losetup -d "$loop_dev" 2>/dev/null || true
        rm -f "${WORK_DIR}/loop_device"
    fi
}

clean_build() {
    info "Cleaning previous build..."

    cleanup_stale_mounts

    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR" "$OUTPUT_DIR" "$CACHE_DIR"
    log "Build directory cleaned (cache preserved at $CACHE_DIR)"
}

# ========== 从缓存恢复 rootfs ==========
# 返回 0 表示命中缓存，1 表示未命中
restore_rootfs_cache() {
    if [ "$NO_CACHE" = true ]; then
        info "Cache disabled (--no-cache)"
        return 1
    fi

    if [ ! -f "$ROOTFS_CACHE" ]; then
        info "No rootfs cache found, will build from scratch"
        return 1
    fi

    info "Restoring rootfs from cache: $ROOTFS_CACHE"
    mkdir -p "$ROOTFS"
    if tar xzf "$ROOTFS_CACHE" -C "$ROOTFS" 2>&1; then
        log "Rootfs restored from cache ($(du -sh "$ROOTFS" | cut -f1))"
        return 0
    else
        warn "Failed to restore cache, will build from scratch"
        rm -rf "$ROOTFS"
        mkdir -p "$ROOTFS"
        return 1
    fi
}

# ========== 保存 rootfs 到缓存 ==========
# 缓存点：deploy_clawbox 之后，build_proxyclaw 之前
# 这样缓存包含完整的 base 系统 + clawbox 文件，但不包含可能变化的 proxyclaw 镜像
save_rootfs_cache() {
    if [ "$NO_CACHE" = true ]; then
        return 0
    fi

    info "Saving rootfs to cache: $ROOTFS_CACHE"
    mkdir -p "$CACHE_DIR"
    # 使用 pigz 如果可用，否则 gzip
    local compressor="gzip"
    if command -v pigz &>/dev/null; then
        compressor="pigz"
    fi
    if tar cf - -C "$ROOTFS" . | $compressor -9 > "$ROOTFS_CACHE.tmp" 2>&1; then
        mv "$ROOTFS_CACHE.tmp" "$ROOTFS_CACHE"
        log "Rootfs cached ($(du -sh "$ROOTFS_CACHE" | cut -f1))"
    else
        warn "Failed to save rootfs cache"
        rm -f "$ROOTFS_CACHE.tmp"
    fi
}

# ========== 1. 创建最小 rootfs ==========
create_rootfs() {
    info "Creating minimal Debian 12 rootfs..."
    
    # 使用 debootstrap 创建最小系统
    # --variant=minbase: 最小安装
    # --include: 必须包含的包
    # --exclude: 排除不需要的包
    debootstrap \
        --variant=minbase \
        --arch=amd64 \
        --include="\
systemd,systemd-sysv,dbus,\
openssh-server,openssh-client,\
curl,wget,ca-certificates,gnupg,\
iproute2,iputils-ping,inetutils-telnet,\
sudo,passwd,login,\
locales,\
docker.io,docker-compose,\
linux-image-amd64,initramfs-tools,\
e2fsprogs,kmod,\
lsof,htop,tmux,nano" \
        --exclude="\
busybox,\
plymouth,systemd-resolved,\
neovim,vim-common,vim-tiny" \
        bookworm \
        "$ROOTFS" \
        http://deb.debian.org/debian/
    
    log "Rootfs created ($(du -sh "$ROOTFS" | cut -f1))"
}

# ========== 2. 精简系统 ==========
slim_system() {
    info "Slimming system..."
    
    chroot "$ROOTFS" /bin/bash << 'CHROOT_SLIM'
        # 清理包缓存
        apt-get clean
        rm -rf /var/lib/apt/lists/*
        rm -rf /var/cache/apt/archives/*
        
        # 清理文档
        rm -rf /usr/share/doc/*
        rm -rf /usr/share/man/*
        rm -rf /usr/share/info/*
        rm -rf /usr/share/lintian/*
        rm -rf /usr/share/linda/*
        
        # 清理 locale (保留 en_US 和 zh_CN，以及 locale.alias 文件)
        find /usr/share/locale -mindepth 1 -maxdepth 1 \
            ! -name 'en' ! -name 'en_US' ! -name 'zh_CN' \
            ! -name 'locale.alias' \
            -exec rm -rf {} + 2>/dev/null || true
        
        # 清理时区数据 (只保留亚洲)
        find /usr/share/zoneinfo -mindepth 1 -maxdepth 1 ! -name 'Asia' ! -name 'UTC' -exec rm -rf {} + 2>/dev/null || true
        
        # 禁用不必要的服务
        systemctl disable -f avahi-daemon 2>/dev/null || true
        systemctl disable -f avahi-daemon.socket 2>/dev/null || true
        systemctl disable -f bluetooth 2>/dev/null || true
        systemctl disable -f cups 2>/dev/null || true
        systemctl disable -f cups-browsed 2>/dev/null || true
        systemctl disable -f ModemManager 2>/dev/null || true
        systemctl disable -f getty@tty1 2>/dev/null || true
        
        # 清理日志
        find /var/log -name "*.log" -exec truncate -s 0 {} \;
        find /var/log -name "*.gz" -delete
        find /var/log -name "*.[0-9]" -delete
CHROOT_SLIM
    
    log "System slimmed"
}

# ========== 3. 系统配置 ==========
configure_system() {
    info "Configuring system..."
    
    # ---- 主机名 ----
    echo "$HOSTNAME" > "$ROOTFS/etc/hostname"
    cat > "$ROOTFS/etc/hosts" << EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
EOF
    
    # ---- 时区 ----
    chroot "$ROOTFS" ln -snf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    echo "Asia/Shanghai" > "$ROOTFS/etc/timezone"
    
    # ---- Locale ----
    echo "en_US.UTF-8 UTF-8" >> "$ROOTFS/etc/locale.gen"
    echo "zh_CN.UTF-8 UTF-8" >> "$ROOTFS/etc/locale.gen"
    chroot "$ROOTFS" locale-gen
    cat > "$ROOTFS/etc/default/locale" << EOF
LANG=en_US.UTF-8
LANGUAGE=en_US:zh_CN
LC_ALL=en_US.UTF-8
EOF
    
    # ---- 网络 ----
    # minbase 变体不含 ifupdown，需先安装；同时确保目录存在
    mkdir -p "$ROOTFS/etc/network"
    if ! chroot "$ROOTFS" dpkg -s ifupdown &>/dev/null; then
        chroot "$ROOTFS" apt-get update -qq
        chroot "$ROOTFS" apt-get install -y --no-install-recommends ifupdown
        chroot "$ROOTFS" apt-get clean
        rm -rf "$ROOTFS/var/lib/apt/lists/*"
    fi
    mkdir -p "$ROOTFS/etc/network"
    cat > "$ROOTFS/etc/network/interfaces" << EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
    
    # ---- DNS ----
    cat > "$ROOTFS/etc/resolv.conf" << EOF
nameserver 223.5.5.5
nameserver 8.8.8.8
EOF
    
    # ---- sysctl 优化 ----
    cat > "$ROOTFS/etc/sysctl.d/99-clawbox.conf" << EOF
# 网络优化
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_forward = 1

# 内存优化
vm.swappiness = 10
vm.overcommit_memory = 1
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# 文件系统
fs.file-max = 65535
fs.inotify.max_user_watches = 524288
EOF
    
    # ---- tmpfs ----
    echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,noexec,size=256M 0 0" >> "$ROOTFS/etc/fstab"
    echo "tmpfs /var/log tmpfs defaults,noatime,nosuid,nodev,size=128M 0 0" >> "$ROOTFS/etc/fstab"
    
    log "System configured"
}

# ========== 4. 配置 SSH ==========
configure_ssh() {
    info "Configuring SSH..."
    
    # 生成主机密钥 (首次启动时自动重新生成)
    chroot "$ROOTFS" ssh-keygen -A 2>/dev/null || true
    
    # SSH 配置
    cat > "$ROOTFS/etc/ssh/sshd_config" << 'EOF'
# ClawBox SSH Configuration
Port 22
ListenAddress 0.0.0.0

# 安全配置
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

# 限制
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2

# 禁用不需要的功能
X11Forwarding no
AllowTcpForwarding no
PermitTunnel no

# 日志
SyslogFacility AUTH
LogLevel INFO
EOF
    
    # 首次登录时自动生成 SSH 密钥对
    cat > "$ROOTFS/etc/ssh/sshd_config.d/clawbox-init.conf" << 'EOF'
# 首次启动自动生成密钥
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
EOF
    
    log "SSH configured"
}

# ========== 5. 安装 Docker ==========
install_docker() {
    info "Configuring Docker..."
    
    chroot "$ROOTFS" /bin/bash << 'CHROOT_DOCKER'
        # 确保 Docker 开机自启
        systemctl enable docker
        
        # 创建 Docker 配置目录
        mkdir -p /etc/docker
        
        # Docker daemon 配置
        cat > /etc/docker/daemon.json << 'EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "data-root": "/var/lib/docker",
    "default-address-pools": [
        {"base": "172.17.0.0/12", "size": 24}
    ]
}
EOF
        
        # 创建 docker 组并添加默认用户
        groupadd -f docker
CHROOT_DOCKER
    
    log "Docker configured"
}

# ========== 6. 部署 ClawBox ==========
deploy_clawbox() {
    info "Deploying ClawBox..."
    
    local clawbox_dir="${ROOTFS}/opt/clawbox"
    mkdir -p "$clawbox_dir"
    
    # 复制项目文件
    cp "$PROJECT_DIR/docker-compose.yml" "$clawbox_dir/"
    cp "$PROJECT_DIR/.env.example" "$clawbox_dir/.env"
    cp "$PROJECT_DIR/ota/ota-agent.sh" "$clawbox_dir/"
    cp "$PROJECT_DIR/scripts/first-boot.sh" "$clawbox_dir/"
    chmod +x "$clawbox_dir/ota-agent.sh" "$clawbox_dir/first-boot.sh"
    
    # 复制教育配置
    mkdir -p "$clawbox_dir/config"
    cp "$PROJECT_DIR/config/education.yaml" "$clawbox_dir/config/" 2>/dev/null || true
    
    # 版本信息
    echo "$CLAWBOX_VERSION" > "$clawbox_dir/VERSION"
    
    log "ClawBox files deployed"
}

# ========== 6.5. 构建 proxyclaw 镜像 ==========
build_proxyclaw() {
    if [ "$NO_PROXYCLAW" = true ]; then
        info "Skipping proxyclaw build (--no-proxyclaw)"
        return 0
    fi

    info "Building proxyclaw Docker image..."

    # 确定构建来源: 本地路径 > GitHub 仓库
    if [ -n "$PROXYCLAW_LOCAL_PATH" ]; then
        # --- 从本地路径构建 ---
        if [ ! -d "$PROXYCLAW_LOCAL_PATH" ]; then
            err "proxyclaw local path not found: $PROXYCLAW_LOCAL_PATH"
        fi
        PROXYCLAW_BUILD_DIR="$PROXYCLAW_LOCAL_PATH"
        info "Using local proxyclaw source: $PROXYCLAW_BUILD_DIR"

    else
        # --- 从 GitHub 拉取 ---
        PROXYCLAW_BUILD_DIR="${WORK_DIR}/proxyclaw-source"
        if [ -d "$PROXYCLAW_BUILD_DIR" ]; then
            warn "Removing stale proxyclaw source..."
            rm -rf "$PROXYCLAW_BUILD_DIR"
        fi

        info "Cloning proxyclaw from $PROXYCLAW_REPO (branch: $PROXYCLAW_BRANCH)..."
        if ! git clone --depth 1 --branch "$PROXYCLAW_BRANCH" "$PROXYCLAW_REPO" "$PROXYCLAW_BUILD_DIR" 2>&1; then
            warn "Failed to clone proxyclaw repo, falling back to remote image pull"
            NO_PROXYCLAW=true
            return 0
        fi
        log "proxyclaw source cloned"
    fi

    # 查找 Dockerfile
    local dockerfile=""
    if [ -f "${PROXYCLAW_BUILD_DIR}/Dockerfile" ]; then
        dockerfile="${PROXYCLAW_BUILD_DIR}/Dockerfile"
    elif [ -f "${PROXYCLAW_BUILD_DIR}/build/Dockerfile" ]; then
        dockerfile="${PROXYCLAW_BUILD_DIR}/build/Dockerfile"
    elif [ -f "${PROXYCLAW_BUILD_DIR}/docker/Dockerfile" ]; then
        dockerfile="${PROXYCLAW_BUILD_DIR}/docker/Dockerfile"
    else
        # 搜索 Dockerfile
        dockerfile=$(find "$PROXYCLAW_BUILD_DIR" -maxdepth 3 -name "Dockerfile" -not -path "*/node_modules/*" 2>/dev/null | head -1)
    fi

    if [ -z "$dockerfile" ]; then
        warn "No Dockerfile found in proxyclaw source, falling back to remote image pull"
        NO_PROXYCLAW=true
        return 0
    fi

    info "  Dockerfile: $dockerfile"

    # 构建镜像 — 使用项目根目录作为 build context（Dockerfile 可能在子目录）
    local build_context="$PROXYCLAW_BUILD_DIR"
    local proxyclaw_image="proxyclaw/proxyclaw:${CLAWBOX_VERSION}"

    # 将 Dockerfile 路径转为相对于 build context 的路径
    local dockerfile_rel="${dockerfile#${build_context}/}"
    info "  Building $proxyclaw_image ..."
    if docker build -t "$proxyclaw_image" -t "proxyclaw/proxyclaw:latest" -f "$dockerfile_rel" "$build_context" 2>&1; then
        log "proxyclaw image built: $proxyclaw_image"

        # 更新 .env 使用本地构建的镜像
        sed -i "s|^PROXYCLAW_IMAGE=.*|PROXYCLAW_IMAGE=proxyclaw/proxyclaw:${CLAWBOX_VERSION}|" "${ROOTFS}/opt/clawbox/.env"
    else
        warn "Failed to build proxyclaw, falling back to remote image pull"
        NO_PROXYCLAW=true
    fi
}

# ========== 7. 预拉取 Docker 镜像（离线部署支持） ==========
prefetch_images() {
    info "Prefetching Docker images for offline deployment..."

    local images_dir="${ROOTFS}/opt/clawbox/images"
    mkdir -p "$images_dir"

    # 读取 .env 中的镜像配置
    local proxyclaw_img="proxyclaw/proxyclaw:latest"
    local ota_img="clawbox/ota-agent:latest"
    if [ -f "${ROOTFS}/opt/clawbox/.env" ]; then
        local custom_pc custom_ota
        custom_pc=$(grep "^PROXYCLAW_IMAGE=" "${ROOTFS}/opt/clawbox/.env" 2>/dev/null | cut -d= -f2 || true)
        [ -n "$custom_pc" ] && proxyclaw_img="$custom_pc"
        custom_ota=$(grep "^OTA_IMAGE=" "${ROOTFS}/opt/clawbox/.env" 2>/dev/null | cut -d= -f2 || true)
        [ -n "$custom_ota" ] && ota_img="$custom_ota"
    fi

    local images=()
    local failed_images=()

    # proxyclaw: 如果本地已构建，跳过 pull 直接用 save
    if [ "$NO_PROXYCLAW" = true ]; then
        info "  Skipping proxyclaw (--no-proxyclaw)"
    elif docker image inspect "$proxyclaw_img" >/dev/null 2>&1; then
        info "  Using locally built $proxyclaw_img"
        images+=("$proxyclaw_img")
    else
        info "  Pulling $proxyclaw_img ..."
        if docker pull "$proxyclaw_img" 2>/dev/null; then
            images+=("$proxyclaw_img")
        else
            warn "  Failed to pull $proxyclaw_img, skipping..."
            failed_images+=("$proxyclaw_img")
        fi
    fi

    # 其他镜像
    local other_images=(
        "pgvector/pgvector:pg16"
    )
    for img in "${other_images[@]}"; do
        info "  Pulling $img ..."
        if docker pull "$img" 2>/dev/null; then
            images+=("$img")
        else
            warn "  Failed to pull $img, skipping..."
            failed_images+=("$img")
        fi
    done

    # OTA agent
    info "  Pulling $ota_img ..."
    if docker pull "$ota_img" 2>/dev/null; then
        images+=("$ota_img")
    else
        warn "  Failed to pull $ota_img, skipping..."
        failed_images+=("$ota_img")
    fi

    # Ollama (可选)
    if [ "$WITH_OLLAMA" = true ]; then
        info "  Pulling ollama/ollama:latest ..."
        if docker pull "ollama/ollama:latest" 2>/dev/null; then
            images+=("ollama/ollama:latest")
        else
            warn "  Failed to pull ollama/ollama:latest, skipping..."
            failed_images+=("ollama/ollama:latest")
        fi
    fi

    if [ ${#images[@]} -eq 0 ]; then
        warn "No Docker images were pulled, offline deployment will not work"
        return 0
    fi

    info "  Saving ${#images[@]} images to tarball..."
    if ! docker save "${images[@]}" -o "${images_dir}/clawbox-images.tar"; then
        # 逐个保存（某些版本的 docker save 不支持多个参数）
        warn "  Batch save failed, saving images individually..."
        for img in "${images[@]}"; do
            local safe_name
            safe_name=$(echo "$img" | tr '/:' '_')
            docker save "$img" -o "${images_dir}/${safe_name}.tar" 2>/dev/null || true
        done
    fi

    if [ ${#failed_images[@]} -gt 0 ]; then
        warn "  Some images failed: ${failed_images[*]}"
        warn "  Offline deployment may be incomplete for: ${failed_images[*]}"
    fi

    local total_size
    total_size=$(du -sh "$images_dir" 2>/dev/null | cut -f1 || echo "unknown")
    log "Docker images prefetched ($total_size) for offline deployment"
}

# ========== 8. 创建 systemd 服务 ==========
create_services() {
    info "Creating systemd services..."
    
    # ---- ClawBox 主服务 ----
    cat > "$ROOTFS/etc/systemd/system/clawbox.service" << 'EOF'
[Unit]
Description=ClawBox AI Education Server
Documentation=https://github.com/clawbox/clawbox
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/clawbox

# 首次启动检查
ExecStartPre=/bin/bash -c 'if [ ! -f /opt/clawbox/.setup_done ]; then /opt/clawbox/first-boot.sh --auto; fi'

# 启动服务
ExecStart=/usr/bin/docker compose up -d --remove-orphans

# 停止服务
ExecStop=/usr/bin/docker compose down

# 超时设置
TimeoutStartSec=300
TimeoutStopSec=60

# 重启策略
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    # ---- OTA Agent 服务 ----
    cat > "$ROOTFS/etc/systemd/system/clawbox-ota.service" << 'EOF'
[Unit]
Description=ClawBox OTA Update Agent
Requires=docker.service
After=docker.service clawbox.service

[Service]
Type=simple
ExecStart=/opt/clawbox/ota-agent.sh daemon
Restart=always
RestartSec=60
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    # ---- 健康检查定时器 ----
    cat > "$ROOTFS/etc/systemd/system/clawbox-healthcheck.service" << 'EOF'
[Unit]
Description=ClawBox Health Check

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'curl -sf http://localhost:20060/health || systemctl restart clawbox'
EOF
    
    cat > "$ROOTFS/etc/systemd/system/clawbox-healthcheck.timer" << EOF
[Unit]
Description=Run ClawBox health check every 5 minutes

[Timer]
OnBootSec=60
OnUnitActiveSec=300

[Install]
WantedBy=timers.target
EOF
    
    # 启用服务
    chroot "$ROOTFS" /bin/bash << 'CHROOT_SERVICES'
        systemctl daemon-reload
        systemctl enable clawbox
        systemctl enable clawbox-ota
        systemctl enable clawbox-healthcheck.timer
        systemctl enable docker
CHROOT_SERVICES
    
    log "Systemd services created"
}

# ========== 8. 创建用户 ==========
create_user() {
    info "Creating default user..."
    
    chroot "$ROOTFS" /bin/bash << 'CHROOT_USER'
        # 创建 clawbox 用户
        useradd -m -s /bin/bash -G sudo,docker clawbox
        
        # 设置默认密码 (首次登录强制修改)
        echo "clawbox:clawbox123" | chpasswd
        
        # 首次登录强制修改密码
        chage -d 0 clawbox
        
        # 免密码 sudo (首次)
        echo "clawbox ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/clawbox
        chmod 440 /etc/sudoers.d/clawbox
        
        # 自动登录提示
        cat > /etc/profile.d/clawbox.sh << 'PROFILE'
# ClawBox Welcome
if [ -f /opt/clawbox/.setup_done ]; then
    echo ""
    echo "🎓 Welcome to ClawBox!"
    echo "   Web UI: http://$(hostname -I | awk '{print $1}'):20060"
    echo "   Docs:   /opt/clawbox/README.md"
    echo ""
fi
PROFILE
CHROOT_USER
    
    log "User 'clawbox' created (password: clawbox123)"
}

# ========== 9. 首次启动脚本 ==========
setup_first_boot() {
    info "Creating first-boot script..."
    
    cat > "$ROOTFS/opt/clawbox/first-boot.sh" << 'FIRSTBOOT'
#!/bin/bash
# ClawBox 首次启动自动配置

set -euo pipefail

SETUP_DONE="/opt/clawbox/.setup_done"
LOG="/var/log/clawbox-setup.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# 如果已完成设置，跳过
if [ -f "$SETUP_DONE" ]; then
    exit 0
fi

log "=== ClawBox First Boot ==="

# 1. 生成随机设备 ID
DEVICE_ID="clawbox-$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':' | head -c 8 || echo 'unknown')"
sed -i "s/^DEVICE_ID=.*/DEVICE_ID=${DEVICE_ID}/" /opt/clawbox/.env
log "Device ID: $DEVICE_ID"

# 2. 生成随机密码
ADMIN_PASS=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)
PG_PASS=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)
sed -i "s/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=${ADMIN_PASS}/" /opt/clawbox/.env
sed -i "s/^PG_PASSWORD=.*/PG_PASSWORD=${PG_PASS}/" /opt/clawbox/.env
log "Passwords generated"

# 3. 加载 Docker 镜像（优先本地，失败时尝试在线拉取）
log "Loading Docker images..."
cd /opt/clawbox
IMAGES_DIR="/opt/clawbox/images"
if [ -d "$IMAGES_DIR" ]; then
    # 逐个加载本地镜像包
    for tar_file in "$IMAGES_DIR"/*.tar; do
        if [ -f "$tar_file" ]; then
            log "  Loading $(basename "$tar_file") ..."
            docker load -i "$tar_file" 2>&1 | tee -a "$LOG" || warn "  Failed to load $(basename "$tar_file")"
        fi
    done
    # 清理镜像包以释放空间
    rm -rf "$IMAGES_DIR"
    log "Local images loaded, image packages cleaned up"
else
    log "No local images found, trying online pull..."
    docker compose pull 2>&1 | tee -a "$LOG" || log "Online pull failed, some services may not start"
fi

# 4. 启动服务
log "Starting services..."
docker compose up -d 2>&1 | tee -a "$LOG"

# 5. 等待服务就绪
log "Waiting for services..."
retries=30
while [ $retries -gt 0 ]; do
    if curl -sf http://localhost:20060/health >/dev/null 2>&1; then
        log "Services ready!"
        break
    fi
    retries=$((retries - 1))
    sleep 2
done

# 6. 下载 Embedding 模型（仅当 Ollama 运行时）
if docker ps --format '{{.Names}}' | grep -q ollama; then
    log "Downloading embedding model..."
    docker exec clawbox-ollama ollama pull bge-m3 2>&1 | tee -a "$LOG" || log "Failed to download embedding model"
else
    log "Ollama not running, skipping embedding model download"
fi

# 7. 标记完成
touch "$SETUP_DONE"
log "=== Setup Complete ==="
log "Web UI: http://$(hostname -I | awk '{print $1}'):20060"
FIRSTBOOT
    
    chmod +x "$ROOTFS/opt/clawbox/first-boot.sh"
    
    log "First-boot script created"
}

# ========== chroot 辅助（apt / grub 安装需要） ==========
chroot_prepare() {
    local target="$1"
    cp /etc/resolv.conf "${target}/etc/resolv.conf" 2>/dev/null || true
    mount --bind /dev "${target}/dev"
    mount --bind /proc "${target}/proc"
    mount --bind /sys "${target}/sys"
    mount --bind /dev/pts "${target}/dev/pts" 2>/dev/null || true
}

chroot_cleanup() {
    local target="$1"
    unmount_chroot_binds "$target"
}

# ========== 9.5 确保内核（兼容旧 rootfs 缓存） ==========
ensure_bootloader() {
    info "Ensuring kernel..."

    if compgen -G "${ROOTFS}/boot/vmlinuz-"* >/dev/null; then
        log "Kernel already present"
        return 0
    fi

    warn "旧缓存缺少内核，正在下载 linux-image-amd64（约 300MB，需 3-10 分钟，请耐心等待）..."
    chroot_prepare "$ROOTFS"
    trap 'chroot_cleanup "$ROOTFS"' INT TERM

    if ! chroot "$ROOTFS" /bin/bash << 'BOOTPKG'; then
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends \
            linux-image-amd64 \
            initramfs-tools \
            e2fsprogs kmod
        apt-get clean
        rm -rf /var/lib/apt/lists/*
BOOTPKG
        chroot_cleanup "$ROOTFS"
        trap - INT TERM
        err "内核安装失败"
    fi

    chroot_cleanup "$ROOTFS"
    trap - INT TERM

    compgen -G "${ROOTFS}/boot/vmlinuz-"* >/dev/null || err "Failed to install kernel in rootfs"
    log "Kernel installed"
}

# ========== 10. 打包磁盘镜像 ==========
build_disk_image() {
    info "Building disk image (${IMAGE_SIZE})..."
    
    # 创建稀疏文件
    fallocate -l "$IMAGE_SIZE" "$IMAGE_FILE"
    
    # 分区
    parted -s "$IMAGE_FILE" mklabel msdos
    parted -s "$IMAGE_FILE" mkpart primary ext4 1MiB 100%
    parted -s "$IMAGE_FILE" set 1 boot on
    
    # 设置循环设备
    local loop_dev
    loop_dev=$(losetup --find --show "$IMAGE_FILE")
    echo "$loop_dev" > "${WORK_DIR}/loop_device"
    
    # 格式化分区
    mkfs.ext4 -F -L EDBOX -q "${loop_dev}p1"
    
    # 挂载
    mkdir -p "$MOUNT_POINT"
    mount "${loop_dev}p1" "$MOUNT_POINT"
    
    # 复制 rootfs
    cp -a "$ROOTFS"/. "$MOUNT_POINT"/

    # 先写 fstab，update-grub 需要正确的根分区 UUID
    local root_uuid
    root_uuid=$(blkid -s UUID -o value "${loop_dev}p1")
    cat > "$MOUNT_POINT/etc/fstab" << EOF
UUID=$root_uuid  /  ext4  errors=remount-ro  0  1
tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,noexec,size=256M 0 0
tmpfs /var/log tmpfs defaults,noatime,nosuid,nodev,size=128M 0 0
EOF

    # 安装 GRUB 到 MBR（grub-pc 在此步安装，避免 chroot 交互式提示卡死）
    info "Installing GRUB to disk..."
    chroot_prepare "$MOUNT_POINT"

    chroot "$MOUNT_POINT" /bin/bash << GRUB
        set -e
        export DEBIAN_FRONTEND=noninteractive
        if ! dpkg -s grub-pc >/dev/null 2>&1; then
            debconf-set-selections << 'DEBCONF'
grub-pc grub-pc/install_devices multiselect
grub-pc grub-pc/install_devices_empty boolean true
grub-pc grub-pc/install_devices_disks_changed boolean false
DEBCONF
            apt-get update
            apt-get install -y --no-install-recommends grub-pc grub-common
            apt-get clean
            rm -rf /var/lib/apt/lists/*
        fi
        grub-install --target=i386-pc --bootloader-id=ClawBox --recheck "${loop_dev}"
        update-grub
GRUB

    chroot_cleanup "$MOUNT_POINT"
    
    # 卸载
    sync
    umount "$MOUNT_POINT"
    losetup -d "$loop_dev"
    rm -f "${WORK_DIR}/loop_device"
    
    log "Disk image created: $IMAGE_FILE"
    
    # 压缩
    info "Compressing image..."
    gzip -9 "$IMAGE_FILE"
    IMAGE_FILE="${IMAGE_FILE}.gz"
    
    log "Compressed: $IMAGE_FILE ($(du -sh "$IMAGE_FILE" | cut -f1))"
}

# ========== 11. 输出信息 ==========
show_result() {
    local proxyclaw_info=""
    if [ "$NO_PROXYCLAW" = true ]; then
        proxyclaw_info="  远程镜像 (pull)"
    elif [ -n "$PROXYCLAW_LOCAL_PATH" ]; then
        proxyclaw_info="  本地构建: $PROXYCLAW_LOCAL_PATH"
    elif [ -n "$PROXYCLAW_BUILD_DIR" ]; then
        proxyclaw_info="  GitHub: $PROXYCLAW_REPO ($PROXYCLAW_BRANCH)"
    fi

    echo ""
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                                                          ║"
    echo "║              🎉 ClawBox OS Build Complete!                ║"
    echo "║                                                          ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║                                                          ║"
    echo "║  镜像文件:  ${IMAGE_FILE}"
    echo "║  镜像大小:  $(du -sh "$IMAGE_FILE" | cut -f1)"
    echo "║  主机名:    ${HOSTNAME}"
    echo "║  版本:      ${CLAWBOX_VERSION}"
    echo "║  proxyclaw: ${proxyclaw_info}"
    echo "║                                                          ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║                                                          ║"
    echo "║  烧录命令 (Linux):                                       ║"
    echo "║    gunzip -c ${IMAGE_NAME}.img.gz | sudo dd of=/dev/sdX bs=4M status=progress"
    echo "║                                                          ║"
    echo "║  烧录命令 (macOS):                                       ║"
    echo "║    gunzip -c ${IMAGE_NAME}.img.gz | sudo dd of=/dev/rdiskX bs=4m"
    echo "║                                                          ║"
    echo "║  默认账号:  clawbox / clawbox123                           ║"
    echo "║  管理面板:  http://设备IP:20060                          ║"
    echo "║                                                          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ========== 主流程 ==========
main() {
    parse_args "$@"
    check_root
    check_deps
    trap cleanup_stale_mounts EXIT INT TERM

    echo ""
    echo -e "${CYAN}ClawBox OS Builder v${CLAWBOX_VERSION}${NC}"
    echo "========================================"
    echo ""

    clean_build

    # 尝试从缓存恢复 rootfs
    local cache_hit=false
    if restore_rootfs_cache; then
        cache_hit=true
        log "Using cached rootfs, skipping debootstrap + slim + configure + ssh + docker + deploy"
    fi

    if [ "$cache_hit" = false ]; then
        create_rootfs
        slim_system
        configure_system
        configure_ssh
        install_docker
        deploy_clawbox
        # 缓存点：base 系统 + clawbox 文件就绪后保存
        save_rootfs_cache
    fi

    build_proxyclaw
    prefetch_images
    create_services
    create_user
    setup_first_boot
    ensure_bootloader
    build_disk_image
    show_result
}

main "$@"
