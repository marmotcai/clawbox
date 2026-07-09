#!/bin/bash
# ClawBox OTA Agent — 版本检查 + 升级 + 回滚
# 常驻运行，定期检查新版本

set -euo pipefail

# 配置
DEVICE_ID="${DEVICE_ID:-clawbox-001}"
OTA_SERVER="${OTA_SERVER:-https://ota.clawbox.ai}"
CURRENT_VERSION="${CURRENT_VERSION:-1.0.0}"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/clawbox}"
CHECK_INTERVAL=21600  # 6小时检查一次
OTA_DIR="/opt/ota"
LOG_FILE="${OTA_DIR}/ota.log"
VERSION_FILE="${OTA_DIR}/current_version"

# 初始化
mkdir -p "$OTA_DIR"
echo "$CURRENT_VERSION" > "$VERSION_FILE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# ========== 心跳上报 ==========
heartbeat() {
    local version
    version=$(cat "$VERSION_FILE" 2>/dev/null || echo "$CURRENT_VERSION")
    local uptime
    uptime=$(uptime -p 2>/dev/null || echo "unknown")
    local ram_usage
    ram_usage=$(free -m | awk '/Mem:/ {printf "%.1f%%", $3/$2*100}' 2>/dev/null || echo "unknown")
    local disk_usage
    disk_usage=$(df -h / | awk 'NR==2 {print $5}' 2>/dev/null || echo "unknown")

    log "Heartbeat: version=$version uptime=$uptime ram=$ram_usage disk=$disk_usage"
}

# ========== 版本检查 ==========
check_update() {
    log "Checking for updates from $OTA_SERVER ..."

    local response
    response=$(curl -sf --max-time 10 \
        -H "X-Device-ID: $DEVICE_ID" \
        -H "X-Current-Version: $(cat $VERSION_FILE)" \
        "${OTA_SERVER}/api/v1/release/latest" 2>/dev/null) || {
        log "Failed to check update (server unreachable)"
        return 1
    }

    local latest_version
    latest_version=$(echo "$response" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$latest_version" ]; then
        log "No version in response"
        return 1
    fi

    local current
    current=$(cat "$VERSION_FILE")
    if [ "$latest_version" = "$current" ]; then
        log "Already up to date ($current)"
        return 0
    fi

    log "New version available: $current → $latest_version"
    echo "$latest_version"
    return 0
}

# ========== 执行升级 ==========
do_upgrade() {
    local target_version="$1"
    log "Upgrading to $target_version ..."

    # 1. 备份当前版本
    local backup_dir="${OTA_DIR}/backups/${CURRENT_VERSION}"
    mkdir -p "$backup_dir"
    cp "$COMPOSE_DIR/docker-compose.yml" "$backup_dir/" 2>/dev/null || true
    cp "$COMPOSE_DIR/.env" "$backup_dir/" 2>/dev/null || true
    log "Backup saved to $backup_dir"

    # 2. 下载新版本配置
    local new_config
    new_config=$(curl -sf --max-time 30 \
        -H "X-Device-ID: $DEVICE_ID" \
        -H "X-Version: $target_version" \
        "${OTA_SERVER}/api/v1/release/${target_version}/config" 2>/dev/null) || {
        log "Failed to download new config"
        return 1
    }

    # 3. 更新 docker-compose.yml (如果提供了新版本)
    if echo "$new_config" | grep -q "services:"; then
        echo "$new_config" > "$COMPOSE_DIR/docker-compose.yml.new"
        mv "$COMPOSE_DIR/docker-compose.yml" "$COMPOSE_DIR/docker-compose.yml.bak"
        mv "$COMPOSE_DIR/docker-compose.yml.new" "$COMPOSE_DIR/docker-compose.yml"
        log "docker-compose.yml updated"
    fi

    # 4. 拉取新镜像
    cd "$COMPOSE_DIR"
    docker compose pull 2>&1 | tee -a "$LOG_FILE"

    # 5. 滚动重启
    docker compose up -d --remove-orphans 2>&1 | tee -a "$LOG_FILE"

    # 6. 健康检查
    log "Waiting for services to be healthy..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if curl -sf http://localhost:20060/health >/dev/null 2>&1; then
            log "Health check passed!"
            echo "$target_version" > "$VERSION_FILE"
            log "Upgrade to $target_version completed successfully"
            return 0
        fi
        retries=$((retries - 1))
        sleep 2
    done

    # 7. 健康检查失败，回滚
    log "Health check failed! Rolling back..."
    do_rollback
    return 1
}

# ========== 回滚 ==========
do_rollback() {
    local previous_version
    previous_version=$(cat "$VERSION_FILE")

    local backup_dir="${OTA_DIR}/backups/${previous_version}"
    if [ ! -d "$backup_dir" ]; then
        log "No backup found for $previous_version, cannot rollback"
        return 1
    fi

    log "Rolling back to $previous_version ..."

    # 恢复配置
    cp "$backup_dir/docker-compose.yml" "$COMPOSE_DIR/" 2>/dev/null || true
    cp "$backup_dir/.env" "$COMPOSE_DIR/" 2>/dev/null || true

    # 重启
    cd "$COMPOSE_DIR"
    docker compose down 2>&1 | tee -a "$LOG_FILE"
    docker compose up -d 2>&1 | tee -a "$LOG_FILE"

    log "Rollback to $previous_version completed"
}

# ========== 手动升级入口 ==========
manual_upgrade() {
    local target="${1:-}"
    if [ -z "$target" ]; then
        echo "Usage: $0 upgrade <version>"
        echo "       $0 upgrade latest"
        exit 1
    fi

    if [ "$target" = "latest" ]; then
        target=$(check_update) || {
            echo "No update available or server unreachable"
            exit 1
        }
    fi

    do_upgrade "$target"
}

# ========== 主循环 ==========
main_loop() {
    log "OTA Agent started (device=$DEVICE_ID, version=$CURRENT_VERSION)"

    while true; do
        heartbeat
        check_update && {
            local new_ver
            new_ver=$(check_update)
            if [ -n "$new_ver" ]; then
                do_upgrade "$new_ver" || log "Upgrade failed, will retry next cycle"
            fi
        }
        sleep "$CHECK_INTERVAL"
    done
}

# ========== 入口 ==========
case "${1:-}" in
    daemon)
        main_loop
        ;;
    check)
        check_update
        ;;
    upgrade)
        manual_upgrade "${2:-}"
        ;;
    rollback)
        do_rollback
        ;;
    heartbeat)
        heartbeat
        ;;
    *)
        echo "ClawBox OTA Agent v1.0.0"
        echo ""
        echo "Usage: $0 <command> [args]"
        echo ""
        echo "Commands:"
        echo "  daemon          Start OTA daemon (default)"
        echo "  check           Check for updates"
        echo "  upgrade <ver>   Upgrade to specific version"
        echo "  upgrade latest  Upgrade to latest version"
        echo "  rollback        Rollback to previous version"
        echo "  heartbeat       Send heartbeat"
        ;;
esac
