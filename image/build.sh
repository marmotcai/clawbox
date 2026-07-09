#!/bin/bash
# ClawBox 系统镜像构建脚本
# 基于 Debian 12 最小化安装，预装 Docker + proxyclaw

set -euo pipefail

# 配置
CLAWBOX_VERSION="${CLAWBOX_VERSION:-1.0.0}"
IMAGE_NAME="clawbox-${CLAWBOX_VERSION}"
OUTPUT_DIR="./output"
WORK_DIR="./build"
ROOTFS_DIR="${WORK_DIR}/rootfs"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[BUILD]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ========== 1. 准备工作 ==========
prepare() {
    log "Preparing build environment..."
    mkdir -p "$OUTPUT_DIR" "$WORK_DIR"
    
    # 检查依赖（根据构建模式）
    case "${BUILD_MODE:-docker}" in
        image)
            # image 模式需要 debootstrap + docker
            for cmd in debootstrap docker; do
                command -v "$cmd" >/dev/null 2>&1 || err "$cmd not found"
            done
            ;;
        docker)
            # docker 模式只需要 docker
            command -v docker >/dev/null 2>&1 || err "docker not found"
            ;;
    esac
}

# ========== 2. 创建最小化 rootfs ==========
create_rootfs() {
    log "Creating minimal Debian 12 rootfs..."
    
    if [ -d "$ROOTFS_DIR" ]; then
        warn "Rootfs exists, cleaning..."
        rm -rf "$ROOTFS_DIR"
    fi
    
    # 使用 debootstrap 创建最小系统
    debootstrap \
        --variant=minbase \
        --include=systemd,systemd-sysv,dbus,openssh-server,curl,wget,ca-certificates \
        --exclude=e2fsprogs,busybox,kmod,plymouth \
        bookworm \
        "$ROOTFS_DIR" \
        http://deb.debian.org/debian
    
    log "Rootfs created ($(du -sh "$ROOTFS_DIR" | cut -f1))"
}

# ========== 3. 精简系统 ==========
slim_rootfs() {
    log "Slimming rootfs..."
    
    chroot "$ROOTFS_DIR" /bin/bash << 'SLIM'
        # 清理缓存
        apt-get clean
        rm -rf /var/lib/apt/lists/*
        rm -rf /usr/share/doc/*
        rm -rf /usr/share/man/*
        rm -rf /usr/share/info/*
        rm -rf /usr/share/locale/*
        rm -rf /var/cache/apt/archives/*
        
        # 禁用不必要的服务
        systemctl disable -f avahi-daemon 2>/dev/null || true
        systemctl disable -f bluetooth 2>/dev/null || true
        systemctl disable -f cups 2>/dev/null || true
        systemctl disable -f ModemManager 2>/dev/null || true
        
        # 配置 tmpfs
        echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,noexec,mode=1777 0 0" >> /etc/fstab
        
        # 配置日志轮转
        cat > /etc/logrotate.d/proxyclaw << 'EOF'
/var/log/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
SLIM
}

# ========== 4. 安装 Docker ==========
install_docker() {
    log "Installing Docker..."
    
    chroot "$ROOTFS_DIR" /bin/bash << 'DOCKER'
        # 安装 Docker
        curl -fsSL https://get.docker.com | sh
        
        # 配置 Docker daemon
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json << 'EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "data-root": "/var/lib/docker"
}
EOF
        
        # Docker 开机自启
        systemctl enable docker
DOCKER
}

# ========== 5. 部署 ClawBox ==========
deploy_clawbox() {
    log "Deploying ClawBox..."
    
    local clawbox_dir="${ROOTFS_DIR}/opt/clawbox"
    mkdir -p "$clawbox_dir"
    
    # 复制文件
    cp ../docker-compose.yml "$clawbox_dir/"
    cp ../.env.example "$clawbox_dir/.env"
    cp ../ota/ota-agent.sh "$clawbox_dir/"
    cp ../scripts/first-boot.sh "$clawbox_dir/"
    chmod +x "$clawbox_dir/ota-agent.sh" "$clawbox_dir/first-boot.sh"
    
    # 创建 systemd 服务
    chroot "$ROOTFS_DIR" /bin/bash << 'SYSTEMD'
        # proxyclaw 服务
        cat > /etc/systemd/system/clawbox.service << 'EOF'
[Unit]
Description=ClawBox AI Server
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/clawbox
ExecStartPre=/opt/clawbox/first-boot.sh --auto
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
        
        # OTA 服务
        cat > /etc/systemd/system/clawbox-ota.service << 'EOF'
[Unit]
Description=ClawBox OTA Agent
Requires=docker.service
After=docker.service clawbox.service

[Service]
Type=simple
ExecStart=/opt/clawbox/ota-agent.sh daemon
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable clawbox
        systemctl enable clawbox-ota
SYSTEMD
}

# ========== 6. 系统配置 ==========
configure_system() {
    log "Configuring system..."
    
    chroot "$ROOTFS_DIR" /bin/bash << 'CONFIG'
        # 主机名
        echo "clawbox" > /etc/hostname
        echo "127.0.1.1 clawbox" >> /etc/hosts
        
        # 时区
        ln -snf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        echo "Asia/Shanghai" > /etc/timezone
        
        # Locale
        echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
        locale-gen
        echo "LANG=en_US.UTF-8" > /etc/default/locale
        
        # SSH 配置
        sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
        sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        
        # 自动安全更新
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades
        dpkg-reconfigure -plow unattended-upgrades
        
        # 清理
        apt-get clean
        rm -rf /var/lib/apt/lists/*
CONFIG
}

# ========== 7. 打包镜像 ==========
build_image() {
    log "Building image..."
    
    local image_file="${OUTPUT_DIR}/${IMAGE_NAME}.img"
    local image_size="4G"
    
    # 创建磁盘镜像
    fallocate -l "$image_size" "$image_file"
    
    # 格式化
    mkfs.ext4 -F -L EDBOX "$image_file"
    
    # 挂载并复制 rootfs
    local mount_point="${WORK_DIR}/mnt"
    mkdir -p "$mount_point"
    mount -o loop "$image_file" "$mount_point"
    
    cp -a "$ROOTFS_DIR"/. "$mount_point"/
    
    # 安装 GRUB (可选，用于 x86 启动)
    # chroot "$mount_point" grub-install --target=i386-pc /dev/loop0
    
    # 卸载
    umount "$mount_point"
    
    # 压缩
    gzip -9 "${image_file}"
    log "Image created: ${image_file}.gz ($(du -sh "${image_file}.gz" | cut -f1))"
}

# ========== 8. Docker 镜像 (备选方案) ==========
build_docker_image() {
    log "Building Docker image..."
    
    # 获取当前脚本所在目录 (image/)
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # 获取项目根目录
    local project_root
    project_root="$(cd "${script_dir}/.." && pwd)"
    
    log "Project root: ${project_root}"
    log "Script dir: ${script_dir}"
    
    # 复制 Dockerfile 和 entrypoint 到项目根目录
    cp "${script_dir}/Dockerfile.clawbox" "${project_root}/Dockerfile.clawbox"
    cp "${script_dir}/entrypoint.sh" "${project_root}/entrypoint.sh"
    chmod +x "${project_root}/entrypoint.sh"
    
    # 构建 Docker 镜像
    docker build -t "clawbox:${CLAWBOX_VERSION}" -f "${project_root}/Dockerfile.clawbox" "${project_root}"
    
    # 清理临时文件
    rm -f "${project_root}/Dockerfile.clawbox" "${project_root}/entrypoint.sh"
    
    log "Docker image built: clawbox:${CLAWBOX_VERSION}"
    log "Run with: docker run -d -p 20060:20060 clawbox:${CLAWBOX_VERSION}"
}

# ========== 主流程 ==========
main() {
    log "ClawBox Image Builder v${CLAWBOX_VERSION}"
    echo ""
    
    # 确定构建模式
    BUILD_MODE="${1:-docker}"
    
    # macOS 不支持 image 模式，自动切换到 docker 模式
    if [ "$BUILD_MODE" = "image" ] && [ "$(uname)" = "Darwin" ]; then
        warn "macOS detected, image mode not available"
        warn "Switching to docker mode..."
        BUILD_MODE="docker"
        echo ""
    fi
    
    prepare
    
    case "$BUILD_MODE" in
        image)
            create_rootfs
            slim_rootfs
            install_docker
            deploy_clawbox
            configure_system
            build_image
            ;;
        docker)
            build_docker_image
            ;;
        *)
            echo "Usage: $0 [image|docker]"
            echo "  image  - Build raw disk image (Linux only, requires root)"
            echo "  docker - Build Docker image (default, works on macOS/Linux)"
            exit 1
            ;;
    esac
    
    log "Build complete!"
}

main "$@"
