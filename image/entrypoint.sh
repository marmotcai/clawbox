#!/bin/bash
# ClawBox Docker 入口脚本
set -e

CLAWBOX_DIR="/opt/clawbox"
ENV_FILE="${CLAWBOX_DIR}/.env"
SETUP_DONE="${CLAWBOX_DIR}/.setup_done"
LOG="/var/log/clawbox/entrypoint.log"

mkdir -p /var/log/clawbox

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

log "=== ClawBox Starting ==="

# ========== 首次启动配置 ==========
if [ ! -f "$SETUP_DONE" ]; then
    log "First boot detected, running auto-setup..."
    
    # 生成随机设备 ID
    DEVICE_ID="clawbox-$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':' | head -c 8 || echo 'docker')"
    sed -i "s/^DEVICE_ID=.*/DEVICE_ID=${DEVICE_ID}/" "$ENV_FILE"
    log "Device ID: $DEVICE_ID"
    
    # 生成随机密码
    ADMIN_PASS=$(head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 16)
    PG_PASS=$(head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 16)
    sed -i "s/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=${ADMIN_PASS}/" "$ENV_FILE"
    sed -i "s/^PG_PASSWORD=.*/PG_PASSWORD=${PG_PASS}/" "$ENV_FILE"
    log "Passwords generated"
    
    # 标记完成
    touch "$SETUP_DONE"
    log "Auto-setup complete"
fi

# ========== 环境变量导出 ==========
set -a
source "$ENV_FILE"
set +a

# ========== 启动 Docker Compose 服务 ==========
log "Starting services..."
cd "$CLAWBOX_DIR"

# 如果是容器内运行 Docker (Docker-in-Docker)
if [ -S /var/run/docker.sock ]; then
    log "Docker socket detected, starting compose services..."
    
    # 拉取镜像
    docker compose pull 2>&1 | tee -a "$LOG" || true
    
    # 启动服务
    docker compose up -d 2>&1 | tee -a "$LOG"
    
    # 等待服务就绪
    log "Waiting for proxyclaw..."
    retries=30
    while [ $retries -gt 0 ]; do
        if curl -sf http://localhost:20060/health >/dev/null 2>&1; then
            log "proxyclaw is ready!"
            break
        fi
        retries=$((retries - 1))
        sleep 2
    done
    
    if [ $retries -eq 0 ]; then
        log "WARNING: proxyclaw not ready yet, may need more time"
    fi
    
    # 下载 embedding 模型
    log "Downloading embedding model..."
    docker exec clawbox-ollama ollama pull bge-m3 2>&1 | tee -a "$LOG" || true
    
    log "=== All services started ==="
    
    # 保持容器运行
    exec tail -f /var/log/clawbox/*.log 2>/dev/null || exec sleep infinity
else
    log "No Docker socket, running in single-container mode"
    log "=== ClawBox ready (single-container) ==="
    
    # 保持容器运行
    exec sleep infinity
fi
