#!/bin/bash
# ============================================================
# ClawBox ISO 构建脚本
# 基于 Debian 12 最小化系统，预装 Docker + proxyclaw
#
# 用法: sudo ./build-iso.sh [选项]
#   --proxyclaw-repo   URL    proxyclaw GitHub 仓库 (默认: https://github.com/proxyclaw/proxyclaw.git)
#   --proxyclaw-branch BR     proxyclaw 分支 (默认: main)
#   --proxyclaw-path   PATH   proxyclaw 本地源码路径 (优先级最高)
#   --no-proxyclaw            跳过构建，直接拉取远程镜像
# ============================================================

set -euo pipefail

# ========== 配置 ==========
CLAWBOX_VERSION="1.0.0"
ISO_VOLUME="ClawBox"
WORK_DIR="/tmp/clawbox-build"
ROOTFS="${WORK_DIR}/rootfs"
ISO_OUTPUT="${WORK_DIR}/clawbox-${CLAWBOX_VERSION}-amd64.iso"

# proxyclaw 构建选项
PROXYCLAW_REPO="https://github.com/proxyclaw/proxyclaw.git"
PROXYCLAW_BRANCH="main"
PROXYCLAW_LOCAL_PATH=""
NO_PROXYCLAW=false
PROXYCLAW_BUILD_DIR=""

# ========== 解析参数 ==========
while [[ $# -gt 0 ]]; do
    case $1 in
        --proxyclaw-repo)   PROXYCLAW_REPO="$2"; shift 2 ;;
        --proxyclaw-branch) PROXYCLAW_BRANCH="$2"; shift 2 ;;
        --proxyclaw-path)   PROXYCLAW_LOCAL_PATH="$2"; shift 2 ;;
        --no-proxyclaw)     NO_PROXYCLAW=true; shift ;;
        --help|-h)
            echo "Usage: sudo $0 [选项]"
            echo ""
            echo "proxyclaw 构建选项:"
            echo "  --proxyclaw-repo URL    GitHub 仓库地址"
            echo "  --proxyclaw-branch BR   分支名 (默认: main)"
            echo "  --proxyclaw-path PATH   本地源码路径"
            echo "  --no-proxyclaw          跳过构建，拉取远程镜像"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ========== 权限检查 ==========
if [[ $EUID -ne 0 ]]; then
    err "需要 root 权限运行"
fi

# ========== 清理 ==========
info "Cleaning build directory..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# ========== 1. 创建最小 rootfs ==========
info "Step 1: Creating minimal Debian 12 rootfs..."

debootstrap \
    --variant=minbase \
    --arch=amd64 \
    --include="\
systemd,systemd-sysv,dbus,\
openssh-server,openssh-client,\
curl,wget,ca-certificates,gnupg,\
iproute2,iputils-ping,\
sudo,passwd,login,\
locales,\
docker.io,docker-compose,\
lsof,htop,tmux,nano,kmod" \
    --exclude="\
e2fsprogs,busybox,\
plymouth,systemd-resolved,\
vim-common,vim-tiny" \
    bookworm \
    "$ROOTFS" \
    http://deb.debian.org/debian/

log "Rootfs created ($(du -sh "$ROOTFS" | cut -f1))"

# ========== 2. 精简系统 ==========
info "Step 2: Slimming system..."

chroot "$ROOTFS" /bin/bash << 'SLIM'
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    rm -rf /var/cache/apt/archives/*
    rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*
    rm -rf /usr/share/lintian/* /usr/share/linda/*
    find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en' ! -name 'en_US' ! -name 'zh_CN' -exec rm -rf {} + 2>/dev/null || true
    find /usr/share/zoneinfo -mindepth 1 -maxdepth 1 ! -name 'Asia' ! -name 'UTC' -exec rm -rf {} + 2>/dev/null || true
    
    # 禁用不必要的服务
    systemctl disable -f avahi-daemon 2>/dev/null || true
    systemctl disable -f bluetooth 2>/dev/null || true
    systemctl disable -f cups 2>/dev/null || true
    systemctl disable -f getty@tty1 2>/dev/null || true
    
    # 清理日志
    find /var/log -name "*.log" -exec truncate -s 0 {} \;
    find /var/log -name "*.gz" -delete
    find /var/log -name "*.[0-9]" -delete
SLIM

log "System slimmed"

# ========== 3. 系统配置 ==========
info "Step 3: Configuring system..."

# 主机名
echo "clawbox" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" << 'EOF'
127.0.0.1   localhost
127.0.1.1   clawbox
::1         localhost ip6-localhost ip6-loopback
EOF

# 时区
chroot "$ROOTFS" ln -snf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > "$ROOTFS/etc/timezone"

# Locale
echo "en_US.UTF-8 UTF-8" >> "$ROOTFS/etc/locale.gen"
echo "zh_CN.UTF-8 UTF-8" >> "$ROOTFS/etc/locale.gen"
chroot "$ROOTFS" locale-gen
cat > "$ROOTFS/etc/default/locale" << 'EOF'
LANG=en_US.UTF-8
LANGUAGE=en_US:zh_CN
LC_ALL=en_US.UTF-8
EOF

# 网络
cat > "$ROOTFS/etc/network/interfaces" << 'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# DNS
cat > "$ROOTFS/etc/resolv.conf" << 'EOF'
nameserver 223.5.5.5
nameserver 8.8.8.8
EOF

# sysctl 优化
cat > "$ROOTFS/etc/sysctl.d/99-clawbox.conf" << 'EOF'
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_forward = 1
vm.swappiness = 10
vm.overcommit_memory = 1
fs.file-max = 65535
EOF

# fstab
cat > "$ROOTFS/etc/fstab" << 'EOF'
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,noexec,size=256M 0 0
tmpfs /var/log tmpfs defaults,noatime,nosuid,nodev,size=128M 0 0
EOF

log "System configured"

# ========== 4. SSH 配置 ==========
info "Step 4: Configuring SSH..."

chroot "$ROOTFS" ssh-keygen -A 2>/dev/null || true

cat > "$ROOTFS/etc/ssh/sshd_config" << 'EOF'
Port 22
ListenAddress 0.0.0.0
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
EOF

log "SSH configured"

# ========== 5. Docker 配置 ==========
info "Step 5: Configuring Docker..."

chroot "$ROOTFS" /bin/bash << 'DOCKER'
    systemctl enable docker
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << 'DJSON'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "data-root": "/var/lib/docker"
}
DJSON
    groupadd -f docker
DOCKER

log "Docker configured"

# ========== 6. 部署 ClawBox ==========
info "Step 6: Deploying ClawBox..."

CLAWBOX_DIR="${ROOTFS}/opt/clawbox"
mkdir -p "$CLAWBOX_DIR"

# 查找项目目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 如果项目目录不存在，使用当前工作目录
if [[ ! -f "$PROJECT_DIR/docker-compose.yml" ]]; then
    PROJECT_DIR="/vol1/@apphome/trim.openclaw/data/workspace/clawbox"
fi

if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
    cp "$PROJECT_DIR/docker-compose.yml" "$CLAWBOX_DIR/"
    cp "$PROJECT_DIR/.env.example" "$CLAWBOX_DIR/.env"
    cp "$PROJECT_DIR/ota/ota-agent.sh" "$CLAWBOX_DIR/"
    cp "$PROJECT_DIR/scripts/first-boot.sh" "$CLAWBOX_DIR/"
    chmod +x "$CLAWBOX_DIR/ota-agent.sh" "$CLAWBOX_DIR/first-boot.sh"
    mkdir -p "$CLAWBOX_DIR/config"
    cp "$PROJECT_DIR/config/education.yaml" "$CLAWBOX_DIR/config/" 2>/dev/null || true
    echo "$CLAWBOX_VERSION" > "$CLAWBOX_DIR/VERSION"
fi

# ========== 6.5. 构建 proxyclaw 镜像 ==========
info "Step 6.5: Building proxyclaw Docker image..."

if [ "$NO_PROXYCLAW" = false ]; then
    if [ -n "$PROXYCLAW_LOCAL_PATH" ]; then
        if [ ! -d "$PROXYCLAW_LOCAL_PATH" ]; then
            warn "proxyclaw local path not found: $PROXYCLAW_LOCAL_PATH"
            NO_PROXYCLAW=true
        else
            PROXYCLAW_BUILD_DIR="$PROXYCLAW_LOCAL_PATH"
            info "Using local proxyclaw source: $PROXYCLAW_BUILD_DIR"
        fi
    else
        PROXYCLAW_BUILD_DIR="${WORK_DIR}/proxyclaw-source"
        info "Cloning proxyclaw from $PROXYCLAW_REPO (branch: $PROXYCLAW_BRANCH)..."
        if ! git clone --depth 1 --branch "$PROXYCLAW_BRANCH" "$PROXYCLAW_REPO" "$PROXYCLAW_BUILD_DIR" 2>&1; then
            warn "Failed to clone proxyclaw repo, falling back to remote image pull"
            NO_PROXYCLAW=true
        else
            log "proxyclaw source cloned"
        fi
    fi

    if [ "$NO_PROXYCLAW" = false ]; then
        # 查找 Dockerfile
        local_dockerfile=""
        if [ -f "${PROXYCLAW_BUILD_DIR}/Dockerfile" ]; then
            local_dockerfile="${PROXYCLAW_BUILD_DIR}/Dockerfile"
        elif [ -f "${PROXYCLAW_BUILD_DIR}/build/Dockerfile" ]; then
            local_dockerfile="${PROXYCLAW_BUILD_DIR}/build/Dockerfile"
        elif [ -f "${PROXYCLAW_BUILD_DIR}/docker/Dockerfile" ]; then
            local_dockerfile="${PROXYCLAW_BUILD_DIR}/docker/Dockerfile"
        else
            local_dockerfile=$(find "$PROXYCLAW_BUILD_DIR" -maxdepth 3 -name "Dockerfile" -not -path "*/node_modules/*" 2>/dev/null | head -1)
        fi

        if [ -z "$local_dockerfile" ]; then
            warn "No Dockerfile found in proxyclaw source, falling back to remote image pull"
            NO_PROXYCLAW=true
        else
            local build_context
            build_context=$(dirname "$local_dockerfile")
            info "  Building proxyclaw/proxyclaw:${CLAWBOX_VERSION} from $local_dockerfile"
            if docker build -t "proxyclaw/proxyclaw:${CLAWBOX_VERSION}" -t "proxyclaw/proxyclaw:latest" -f "$local_dockerfile" "$build_context" 2>&1; then
                log "proxyclaw image built successfully"
                sed -i "s|^PROXYCLAW_IMAGE=.*|PROXYCLAW_IMAGE=proxyclaw/proxyclaw:${CLAWBOX_VERSION}|" "${CLAWBOX_DIR}/.env"
            else
                warn "Failed to build proxyclaw, falling back to remote image pull"
                NO_PROXYCLAW=true
            fi
        fi
    fi
else
    info "Skipping proxyclaw build (--no-proxyclaw)"
fi

# ========== 6.6. 预拉取 Docker 镜像 ==========
info "Step 6.6: Prefetching Docker images for offline deployment..."

IMAGES_DIR="${CLAWBOX_DIR}/images"
mkdir -p "$IMAGES_DIR"

# 确定 proxyclaw 镜像
PROXYCLAW_IMG="proxyclaw/proxyclaw:latest"
custom_pc=$(grep "^PROXYCLAW_IMAGE=" "${CLAWBOX_DIR}/.env" | cut -d= -f2)
[ -n "$custom_pc" ] && PROXYCLAW_IMG="$custom_pc"

SAVED_IMAGES=()

# proxyclaw
if [ "$NO_PROXYCLAW" = false ] && docker image inspect "$PROXYCLAW_IMG" >/dev/null 2>&1; then
    info "  Using locally built $PROXYCLAW_IMG"
    SAVED_IMAGES+=("$PROXYCLAW_IMG")
else
    info "  Pulling $PROXYCLAW_IMG ..."
    docker pull "$PROXYCLAW_IMG" 2>/dev/null && SAVED_IMAGES+=("$PROXYCLAW_IMG") || warn "  Failed to pull $PROXYCLAW_IMG"
fi

# 其他镜像
for img in "pgvector/pgvector:pg16" "ollama/ollama:latest" "clawbox/ota-agent:latest"; do
    info "  Pulling $img ..."
    docker pull "$img" 2>/dev/null && SAVED_IMAGES+=("$img") || warn "  Failed to pull $img"
done

if [ ${#SAVED_IMAGES[@]} -gt 0 ]; then
    info "  Saving ${#SAVED_IMAGES[@]} images..."
    docker save "${SAVED_IMAGES[@]}" -o "${IMAGES_DIR}/clawbox-images.tar" 2>/dev/null || {
        for img in "${SAVED_IMAGES[@]}"; do
            local fname; fname=$(echo "$img" | tr '/:' '_')
            docker save "$img" -o "${IMAGES_DIR}/${fname}.tar" 2>/dev/null || true
        done
    }
    log "Docker images saved ($(du -sh "$IMAGES_DIR" 2>/dev/null | cut -f1))"
else
    warn "No Docker images were prefetched"
fi

# 首次启动脚本
cat > "$CLAWBOX_DIR/first-boot.sh" << 'FIRSTBOOT'
#!/bin/bash
set -euo pipefail
SETUP_DONE="/opt/clawbox/.setup_done"
LOG="/var/log/clawbox-setup.log"
mkdir -p /var/log/clawbox

if [ -f "$SETUP_DONE" ]; then
    exit 0
fi

echo "[$(date)] === ClawBox First Boot ===" | tee "$LOG"

# 生成随机密码
ADMIN_PASS=$(head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 16)
PG_PASS=$(head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 16)
sed -i "s/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=${ADMIN_PASS}/" /opt/clawbox/.env
sed -i "s/^PG_PASSWORD=.*/PG_PASSWORD=${PG_PASS}/" /opt/clawbox/.env

# 生成设备 ID
DEVICE_ID="clawbox-$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':' | head -c 8 || echo 'boot')"
sed -i "s/^DEVICE_ID=.*/DEVICE_ID=${DEVICE_ID}/" /opt/clawbox/.env

# 加载 Docker 镜像（优先本地）
cd /opt/clawbox
IMAGES_DIR="/opt/clawbox/images"
if [ -d "$IMAGES_DIR" ] && [ -n "$(ls -A "$IMAGES_DIR" 2>/dev/null)" ]; then
    echo "[$(date)] Loading local Docker images..." | tee -a "$LOG"
    for tar_file in "$IMAGES_DIR"/*.tar; do
        [ -f "$tar_file" ] || continue
        echo "[$(date)]   Loading $(basename "$tar_file") ..." | tee -a "$LOG"
        docker load -i "$tar_file" 2>&1 | tee -a "$LOG" || echo "[$(date)]   Failed to load $(basename "$tar_file")" | tee -a "$LOG"
    done
    rm -rf "$IMAGES_DIR"
    echo "[$(date)] Local images loaded, packages cleaned up" | tee -a "$LOG"
else
    echo "[$(date)] No local images, trying online pull..." | tee -a "$LOG"
    docker compose pull 2>&1 | tee -a "$LOG" || echo "[$(date)] Online pull failed" | tee -a "$LOG"
fi

# 启动服务
docker compose up -d 2>&1 | tee -a "$LOG"

# 等待服务就绪
retries=30
while [ $retries -gt 0 ]; do
    if curl -sf http://localhost:20060/health >/dev/null 2>&1; then
        echo "[$(date)] Services ready!" | tee -a "$LOG"
        break
    fi
    retries=$((retries - 1))
    sleep 2
done

touch "$SETUP_DONE"
echo "[$(date)] === Setup Complete ===" | tee -a "$LOG"
FIRSTBOOT
chmod +x "$CLAWBOX_DIR/first-boot.sh"

# systemd 服务
cat > "$ROOTFS/etc/systemd/system/clawbox.service" << 'EOF'
[Unit]
Description=ClawBox AI Education Server
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/clawbox
ExecStartPre=/bin/bash -c 'if [ ! -f /opt/clawbox/.setup_done ]; then /opt/clawbox/first-boot.sh; fi'
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

cat > "$ROOTFS/etc/systemd/system/clawbox-ota.service" << 'EOF'
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

chroot "$ROOTFS" systemctl daemon-reload
chroot "$ROOTFS" systemctl enable clawbox
chroot "$ROOTFS" systemctl enable clawbox-ota

log "ClawBox deployed"

# ========== 7. 创建用户 ==========
info "Step 7: Creating user..."

chroot "$ROOTFS" /bin/bash << 'USER'
    useradd -m -s /bin/bash -G sudo,docker clawbox
    echo "clawbox:clawbox123" | chpasswd
    echo "clawbox ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/clawbox
    chmod 440 /etc/sudoers.d/clawbox
USER

log "User created: clawbox / clawbox123"

# ========== 8. 安装 GRUB ==========
info "Step 8: Installing GRUB..."

# 创建 GRUB 启动配置
mkdir -p "$ROOTFS/boot/grub"
cat > "$ROOTFS/boot/grub/grub.cfg" << 'GRUBCFG'
set default=0
set timeout=5

menuentry "ClawBox" {
    insmod gzio
    insmod part_msdos
    insmod ext2
    set root='(hd0,msdos1)'
    linux /boot/vmlinuz root=/dev/sda1 ro quiet splash
    initrd /boot/initrd.img
}

menuentry "ClawBox (Recovery)" {
    insmod part_msdos
    insmod ext2
    set root='(hd0,msdos1)'
    linux /boot/vmlinuz root=/dev/sda1 ro single
    initrd /boot/initrd.img
}
GRUBCFG

# 安装 GRUB 到 rootfs
chroot "$ROOTFS" /bin/bash << 'GRUB_INSTALL'
    apt-get update -qq
    apt-get install -y -qq grub-pc-bin 2>/dev/null || true
GRUB_INSTALL

log "GRUB configured"

# ========== 9. 生成内核 (使用宿主机) ==========
info "Step 9: Setting up kernel..."

# 复制当前内核
if [[ -f /boot/vmlinuz-$(uname -r) ]]; then
    cp /boot/vmlinuz-$(uname -r) "$ROOTFS/boot/vmlinuz"
    cp /boot/initrd.img-$(uname -r) "$ROOTFS/boot/initrd.img"
    log "Kernel copied: $(uname -r)"
else
    warn "No kernel found, ISO may not boot directly"
fi

# ========== 10. 打包 ISO ==========
info "Step 10: Building ISO..."

# 创建 ISO 目录结构
ISO_DIR="${WORK_DIR}/iso"
mkdir -p "$ISO_DIR/boot/grub"
mkdir -p "$ISO_DIR/install.amd64"

# 复制内核
cp "$ROOTFS/boot/vmlinuz" "$ISO_DIR/boot/vmlinuz" 2>/dev/null || true
cp "$ROOTFS/boot/initrd.img" "$ISO_DIR/boot/initrd.img" 2>/dev/null || true
cp "$ROOTFS/boot/grub/grub.cfg" "$ISO_DIR/boot/grub/grub.cfg"

# 创建 rootfs 压缩包
info "Compressing rootfs..."
cd "$ROOTFS"
tar czf "${WORK_DIR}/rootfs.tar.gz" .
ROOTFS_SIZE=$(du -sh "${WORK_DIR}/rootfs.tar.gz" | cut -f1)
info "Rootfs size: $ROOTFS_SIZE"

# 使用 xorriso 创建 ISO
info "Creating ISO with xorriso..."

xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "$ISO_VOLUME" \
    -output "$ISO_OUTPUT" \
    -eltorito-boot boot/grub/bios.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --grub2-boot-info \
        -eltorito-catalog boot/grub/boot.cat \
    -append_partition 2 0xef ${WORK_DIR}/EFI.img \
    -eltorito-alt-boot \
        -e --interval:appended_partition_2:all:: \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
    "$ISO_DIR" 2>&1 || {
        warn "xorriso failed, trying simple ISO creation..."
        
        # 简单 ISO 创建
        genisoimage -r -J -T \
            -V "$ISO_VOLUME" \
            -b boot/grub/bios.img \
            -c boot/grub/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -o "$ISO_OUTPUT" \
            "$ISO_DIR" 2>&1 || err "ISO creation failed"
    }

log "ISO created: $ISO_OUTPUT ($(du -sh "$ISO_OUTPUT" | cut -f1))"

# ========== 11. 输出 ==========
echo ""
echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                                                          ║"
echo "║           🎉 ClawBox ISO Build Complete!                 ║"
echo "║                                                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  ISO 文件:  $ISO_OUTPUT"
echo "║  ISO 大小:  $(du -sh "$ISO_OUTPUT" | cut -f1)"
echo "║  Rootfs:    $ROOTFS_SIZE (compressed)"
echo "║  版本:      $CLAWBOX_VERSION"
echo "║  proxyclaw: $(if [ "$NO_PROXYCLAW" = true ]; then echo "远程镜像"; elif [ -n "$PROXYCLAW_LOCAL_PATH" ]; then echo "本地: $PROXYCLAW_LOCAL_PATH"; else echo "GitHub: $PROXYCLAW_REPO ($PROXYCLAW_BRANCH)"; fi)"
echo "║                                                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  烧录到 U 盘:                                            ║"
echo "║    sudo dd if=$ISO_OUTPUT of=/dev/sdX bs=4M status=progress"
echo "║                                                          ║"
echo "║  或使用 Ventoy / Rufus 写入                              ║"
echo "║                                                          ║"
echo "║  默认账号:  clawbox / clawbox123                           ║"
echo "║  管理面板:  http://设备IP:20060                          ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
