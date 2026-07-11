#!/bin/bash
# ============================================================
# ClawBox ISO 构建脚本
# 基于 Debian 12 最小化系统，预装 Docker + proxyclaw
# 支持 live boot 和安装到磁盘
# ============================================================
#
# 修复记录:
# - 2026-07-10: 添加 linux-image-amd64 到 debootstrap
# - 2026-07-10: 安装 live-boot 并创建 /scripts/casper -> /scripts/live 符号链接
# - 2026-07-10: 修复 GRUB 配置使用 boot=live + live-media-path=casper
# - 2026-07-10: 移除 debootstrap 中的 grub-pc-bin (避免交互式安装)
#
# ============================================================

set -euo pipefail

# ========== 配置 ==========
CLAWBOX_VERSION="1.0.0"
ISO_VOLUME="ClawBox"
WORK_DIR="/tmp/clawbox-build"
ROOTFS="${WORK_DIR}/rootfs"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${PROJECT_DIR}/output"
ISO_OUTPUT="${OUTPUT_DIR}/clawbox-${CLAWBOX_VERSION}-amd64.iso"

# proxyclaw 构建选项
PROXYCLAW_REPO="https://github.com/marmotcai/proxyclaw.git"
PROXYCLAW_BRANCH="main"
PROXYCLAW_LOCAL_PATH=""
NO_PROXYCLAW=false
PROXYCLAW_BUILD_DIR=""

# 可选组件
WITH_OLLAMA=false

# rootfs 缓存
NO_CACHE=false
CACHE_DIR="${PROJECT_DIR}/build-cache"
ROOTFS_CACHE="${CACHE_DIR}/rootfs-iso.tar.gz"

# ========== 解析参数 ==========
while [[ $# -gt 0 ]]; do
    case $1 in
        --proxyclaw-repo)   PROXYCLAW_REPO="$2"; shift 2 ;;
        --proxyclaw-branch) PROXYCLAW_BRANCH="$2"; shift 2 ;;
        -p|--proxyclaw-path) PROXYCLAW_LOCAL_PATH="$2"; shift 2 ;;
        --no-proxyclaw)     NO_PROXYCLAW=true; shift ;;
        --no-cache)         NO_CACHE=true; shift ;;
        --output-dir)       OUTPUT_DIR="$2"; ISO_OUTPUT="${OUTPUT_DIR}/clawbox-${CLAWBOX_VERSION}-amd64.iso"; shift 2 ;;
        --with-ollama)      WITH_OLLAMA=true; shift ;;
        --help|-h)
            echo "Usage: sudo $0 [选项]"
            echo ""
            echo "proxyclaw 构建选项:"
            echo "  -p, --proxyclaw-path PATH   本地源码路径"
            echo "  --proxyclaw-repo URL        GitHub 仓库地址"
            echo "  --proxyclaw-branch BR       分支名 (默认: main)"
            echo "  --no-proxyclaw              跳过构建，拉取远程镜像"
            echo "  --no-cache                  不使用 rootfs 缓存"
            echo "  --output-dir DIR            输出目录 (默认: ./output)"
            echo ""
            echo "可选组件:"
            echo "  --with-ollama               包含 Ollama 镜像（约 3GB）"
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

# ========== 依赖检查 ==========
info "Checking dependencies..."
MISSING_DEPS=()
for cmd in xorriso genisoimage debootstrap mksquashfs isolinux; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING_DEPS+=("$cmd")
    fi
done
if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    info "Installing missing dependencies: ${MISSING_DEPS[*]}"
    apt-get update -qq
    apt-get install -y -qq xorriso genisoimage debootstrap squashfs-tools 2>&1 | tail -1
fi
log "Dependencies OK"

# ========== 清理 ==========
info "Cleaning build directory..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$CACHE_DIR"

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
lsof,htop,tmux,nano,kmod,\
linux-image-amd64,linux-headers-amd64" \
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

    systemctl disable -f avahi-daemon 2>/dev/null || true
    systemctl disable -f bluetooth 2>/dev/null || true
    systemctl disable -f cups 2>/dev/null || true
    # 不禁用 getty，保持登录终端可用

    find /var/log -name "*.log" -exec truncate -s 0 {} \;
    find /var/log -name "*.gz" -delete
    find /var/log -name "*.[0-9]" -delete
SLIM

log "System slimmed"

# ========== 3. 系统配置 ==========
info "Step 3: Configuring system..."

echo "clawbox" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" << 'EOF'
127.0.0.1   localhost
127.0.1.1   clawbox
::1         localhost ip6-localhost ip6-loopback
EOF

chroot "$ROOTFS" ln -snf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > "$ROOTFS/etc/timezone"

echo "en_US.UTF-8 UTF-8" >> "$ROOTFS/etc/locale.gen"
echo "zh_CN.UTF-8 UTF-8" >> "$ROOTFS/etc/locale.gen"
chroot "$ROOTFS" locale-gen
cat > "$ROOTFS/etc/default/locale" << 'EOF'
LANG=en_US.UTF-8
LANGUAGE=en_US:zh_CN
LC_ALL=en_US.UTF-8
EOF

mkdir -p "$ROOTFS/etc/network"
cat > "$ROOTFS/etc/network/interfaces" << 'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

cat > "$ROOTFS/etc/resolv.conf" << 'EOF'
nameserver 223.5.5.5
nameserver 8.8.8.8
EOF

cat > "$ROOTFS/etc/sysctl.d/99-clawbox.conf" << 'EOF'
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_forward = 1
vm.swappiness = 10
vm.overcommit_memory = 1
fs.file-max = 65535
EOF

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
    systemctl enable docker 2>/dev/null || true
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << 'DJSON'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "storage-driver": "vfs",
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

if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
    cp "$PROJECT_DIR/docker-compose.yml" "$CLAWBOX_DIR/"
    cp "$PROJECT_DIR/.env.example" "$CLAWBOX_DIR/.env" 2>/dev/null || true
    cp "$PROJECT_DIR/ota/ota-agent.sh" "$CLAWBOX_DIR/" 2>/dev/null || true
    cp "$PROJECT_DIR/scripts/first-boot.sh" "$CLAWBOX_DIR/" 2>/dev/null || true
    chmod +x "$CLAWBOX_DIR/ota-agent.sh" "$CLAWBOX_DIR/first-boot.sh" 2>/dev/null || true
    mkdir -p "$CLAWBOX_DIR/config"
    cp "$PROJECT_DIR/config/education.yaml" "$CLAWBOX_DIR/config/" 2>/dev/null || true
    echo "$CLAWBOX_VERSION" > "$CLAWBOX_DIR/VERSION"
fi

log "ClawBox deployed"

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
            warn "No Dockerfile found in proxyclaw source"
            NO_PROXYCLAW=true
        else
            info "Building from: $local_dockerfile"
            cd "$(dirname "$local_dockerfile")"
            if docker build -t proxyclaw:latest . 2>&1; then
                log "proxyclaw image built successfully"
                cd "$SCRIPT_DIR"
            else
                warn "Failed to build proxyclaw image"
                cd "$SCRIPT_DIR"
                NO_PROXYCLAW=true
            fi
        fi
    fi
fi

if [ "$NO_PROXYCLAW" = true ]; then
    info "Pulling proxyclaw image from registry..."
    docker pull marmotcai/proxyclaw:latest 2>/dev/null && log "proxyclaw image pulled" || warn "Failed to pull proxyclaw image"
fi

# ========== 6.6. 预拉取 Docker 镜像 ==========
info "Step 6.6: Prefetching Docker images for offline deployment..."

IMAGES=()
if [ "$NO_PROXYCLAW" = false ]; then
    IMAGES+=("proxyclaw:latest")
fi
IMAGES+=("pgvector/pgvector:pg16")

# ClawBox OTA agent image
if [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
    COMPOSE_IMAGES=$(grep "image:" "$PROJECT_DIR/docker-compose.yml" | awk '{print $2}' | sort -u)
    for img in $COMPOSE_IMAGES; do
        IMAGES+=("$img")
    done
fi

if [ "$WITH_OLLAMA" = true ]; then
    IMAGES+=("ollama/ollama:latest")
fi

SAVE_DIR="${WORK_DIR}/docker-images"
mkdir -p "$SAVE_DIR"

for img in "${IMAGES[@]}"; do
    info "  Pulling $img ..."
    if docker pull "$img" 2>&1; then
        safe_name=$(echo "$img" | tr '/:' '_')
        docker save "$img" -o "${SAVE_DIR}/${safe_name}.tar" 2>&1
        log "  Saved $img"
    else
        warn "  Failed to pull $img, skipping"
    fi
done

# 复制到 rootfs
mkdir -p "${ROOTFS}/opt/clawbox/images"
cp ${SAVE_DIR}/*.tar "${ROOTFS}/opt/clawbox/images/" 2>/dev/null || true

# ========== 7. 创建用户 ==========
info "Step 7: Creating user..."

chroot "$ROOTFS" /bin/bash << 'USEREOF'
    useradd -m -s /bin/bash -G sudo,docker clawbox 2>/dev/null || true
    echo "clawbox:clawbox123" | chpasswd
    echo "root:root" | chpasswd
    echo "clawbox ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/clawbox
USEREOF

log "User created: clawbox / clawbox123"

# ========== 8. 安装 live-boot ==========
info "Step 8: Installing live-boot..."

chroot "$ROOTFS" /bin/bash << 'LIVEEOF'
    apt-get update -qq
    apt-get install -y -qq live-boot 2>&1 | tail -1
LIVEEOF

log "live-boot installed"

# ========== 9. 设置内核 ==========
info "Step 9: Setting up kernel..."

KERNEL_VERSION=$(ls "${ROOTFS}/boot/vmlinuz-*" 2>/dev/null | head -1 | sed 's|.*vmlinuz-||')
if [ -n "$KERNEL_VERSION" ]; then
    cp "${ROOTFS}/boot/vmlinuz-${KERNEL_VERSION}" "${ROOTFS}/boot/vmlinuz" 2>/dev/null || true
    cp "${ROOTFS}/boot/initrd.img-${KERNEL_VERSION}" "${ROOTFS}/boot/initrd.img" 2>/dev/null || true
fi

log "Kernel copied: ${KERNEL_VERSION:-unknown}"

# ========== 10. 重建 initramfs ==========
info "Step 10: Rebuilding initramfs..."

chroot "$ROOTFS" update-initramfs -u -k all 2>&1 | tail -3

cd "$SCRIPT_DIR"

log "initramfs rebuilt"

# ========== 11. 构建 ISO ==========
info "Step 11: Building ISO..."

# 安装 isolinux/syslinux
info "Installing isolinux/syslinux..."
chroot "$ROOTFS" /bin/bash << 'ISOLINUX_INST'
    apt-get update -qq
    apt-get install -y -qq isolinux syslinux syslinux-common 2>&1 | tail -1
ISOLINUX_INST
log "isolinux/syslinux installed"

# 创建 ISO 目录结构
ISO_DIR="${WORK_DIR}/iso"
rm -rf "$ISO_DIR"
mkdir -p "$ISO_DIR/isolinux"
mkdir -p "$ISO_DIR/casper"
mkdir -p "$ISO_DIR/boot"

# 1. 创建 squashfs rootfs
info "Creating squashfs (this may take a while)..."
if command -v pigz &>/dev/null; then
    mksquashfs "$ROOTFS" "$ISO_DIR/casper/filesystem.squashfs" -comp pigz -Xcompression-level 9 -b 1M 2>&1 | tail -3
else
    mksquashfs "$ROOTFS" "$ISO_DIR/casper/filesystem.squashfs" -comp gzip -Xcompression-level 9 -b 1M 2>&1 | tail -3
fi
SQUASHFS_SIZE=$(du -sh "$ISO_DIR/casper/filesystem.squashfs" | cut -f1)
log "Squashfs created: $SQUASHFS_SIZE"

# 2. 复制内核到 casper 目录
cp "${ROOTFS}/boot/vmlinuz" "$ISO_DIR/casper/vmlinuz" 2>/dev/null || true
cp "${ROOTFS}/boot/initrd.img" "$ISO_DIR/casper/initrd" 2>/dev/null || true

# 3. 创建 filesystem.size 文件
ESTIMATED_SIZE=$(du -sb "$ROOTFS" | awk '{print int($1 * 1.1)}')
echo "$ESTIMATED_SIZE" > "$ISO_DIR/casper/filesystem.size"

# 4. 创建 manifest
touch "$ISO_DIR/casper/filesystem.manifest"
touch "$ISO_DIR/casper/filesystem.manifest-desktop"

# 5. 复制 isolinux 文件
info "Setting up isolinux boot..."
cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/" 2>/dev/null || err "isolinux.bin not found"
cp /usr/lib/syslinux/modules/bios/*.c32 "$ISO_DIR/isolinux/" 2>/dev/null || true

# 6. 创建 isolinux 配置
cat > "$ISO_DIR/isolinux/isolinux.cfg" << 'ISOLINUXEOF'
UI vesamenu.c32
PROMPT 0
TIMEOUT 50
DEFAULT clawbox

MENU TITLE ClawBox Live Boot

LABEL clawbox
    MENU LABEL ClawBox Live
    KERNEL /casper/vmlinuz
    APPEND boot=live live-media=removable live-media-path=casper initrd=/casper/initrd

LABEL clawbox-nomodeset
    MENU LABEL ClawBox Live (nomodeset)
    KERNEL /casper/vmlinuz
    APPEND boot=live nomodeset live-media=removable live-media-path=casper initrd=/casper/initrd

LABEL clawbox-recovery
    MENU LABEL ClawBox (Recovery)
    KERNEL /casper/vmlinuz
    APPEND boot=live recovery live-media=removable live-media-path=casper initrd=/casper/initrd

LABEL clawbox-debug
    MENU LABEL ClawBox (Debug)
    KERNEL /casper/vmlinuz
    APPEND boot=live nomodeset live-media=removable live-media-path=casper debug initrd=/casper/initrd
ISOLINUXEOF

# 7. 创建 md5sum.txt
info "Calculating checksums..."
cd "$ISO_DIR"
find . -type f ! -name md5sum.txt -exec md5sum {} \; > md5sum.txt
cd "$SCRIPT_DIR"

# 8. 使用 xorriso 创建 ISO (isolinux 引导)
info "Creating ISO with xorriso..."
mkdir -p "$OUTPUT_DIR"

xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "$ISO_VOLUME" \
    -output "$ISO_OUTPUT" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-boot isolinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
    "$ISO_DIR" 2>&1 || {
        warn "xorriso failed, trying simple ISO creation..."
        genisoimage -r -J -T \
            -V "$ISO_VOLUME" \
            -b isolinux/isolinux.bin \
            -c isolinux/boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -o "$ISO_OUTPUT" \
            "$ISO_DIR" 2>&1 || err "ISO creation failed"
    }

ISO_SIZE=$(du -sh "$ISO_OUTPUT" | cut -f1)
log "ISO created: $ISO_OUTPUT ($ISO_SIZE)"

# ========== 12. 验证 ==========
info "Verifying ISO..."
file "$ISO_OUTPUT"
isoinfo -l -i "$ISO_OUTPUT" 2>/dev/null | head -20

# ========== 13. 输出 ==========
echo ""
echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                                                          ║"
echo "║           🎉 ClawBox ISO Build Complete!                 ║"
echo "║                                                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  ISO 文件:  $ISO_OUTPUT"
echo "║  ISO 大小:  $ISO_SIZE"
echo "║  Squashfs:  $SQUASHFS_SIZE"
echo "║  版本:      $CLAWBOX_VERSION"
echo "║                                                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  烧录到 U 盘:                                            ║"
echo "║    sudo dd if=$ISO_OUTPUT of=/dev/sdX bs=4M status=progress"
echo "║                                                          ║"
echo "║  或使用 Ventoy / Rufus 写入                              ║"
echo "║                                                          ║"
echo "║  启动后选择:                                              ║"
echo "║    - ClawBox Live (试用)                                  ║"
echo "║    - ClawBox (Recovery) (恢复模式)                        ║"
echo "║                                                          ║"
echo "║  默认账号:  clawbox / clawbox123                           ║"
echo "║  管理面板:  http://设备IP:20060                          ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
