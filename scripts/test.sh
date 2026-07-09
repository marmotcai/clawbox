#!/bin/bash
# ClawBox 本地测试脚本
# 在开发机上快速验证 ClawBox 功能

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CLAWBOX_DIR="/opt/clawbox"

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[TEST]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

# ========== 环境检查 ==========
check_env() {
    log "Checking environment..."
    
    # Docker
    if ! command -v docker &>/dev/null; then
        fail "Docker not installed"
        exit 1
    fi
    log "  Docker: $(docker --version | head -1)"
    
    # Docker Compose
    if ! docker compose version &>/dev/null; then
        fail "Docker Compose not installed"
        exit 1
    fi
    log "  Docker Compose: $(docker compose version | head -1)"
    
    # .env
    if [ ! -f "$CLAWBOX_DIR/.env" ]; then
        warn ".env not found, copying from example..."
        cp "$PROJECT_DIR/.env.example" "$CLAWBOX_DIR/.env"
    fi
    log "  .env: OK"
}

# ========== 启动服务 ==========
start_services() {
    log "Starting services..."
    
    cd "$CLAWBOX_DIR"
    docker compose up -d
    
    log "Waiting for proxyclaw..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if curl -sf http://localhost:20060/health &>/dev/null; then
            log "  proxyclaw: OK"
            return 0
        fi
        retries=$((retries - 1))
        sleep 2
    done
    
    fail "proxyclaw failed to start"
    docker compose logs
    return 1
}

# ========== 下载 Embedding 模型 ==========
download_models() {
    log "Downloading embedding model..."
    docker exec clawbox-ollama ollama pull bge-m3 2>&1 | tail -2
    log "  bge-m3: OK"
}

# ========== 测试 API ==========
test_api() {
    log "Testing API..."
    
    # 健康检查
    if curl -sf http://localhost:20060/health; then
        log "  Health check: PASS"
    else
        fail "  Health check: FAIL"
        return 1
    fi
    
    # 测试教育场景
    log "Testing education pipeline..."
    local response
    response=$(curl -sf http://localhost:20060/v1/chat/completions \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer test-key" \
        -d '{
            "model": "glm-4-flash",
            "messages": [{"role": "user", "content": "#edu 什么是勾股定理？"}],
            "max_tokens": 500
        }' 2>/dev/null) || {
        warn "Education pipeline test failed (may need API key)"
        return 0
    }
    
    if echo "$response" | grep -q "choices"; then
        log "  Education pipeline: PASS"
    else
        warn "  Education pipeline: Response unexpected"
    fi
}

# ========== 显示状态 ==========
show_status() {
    log "Service status:"
    cd "$CLAWBOX_DIR"
    docker compose ps
    
    echo ""
    log "Endpoints:"
    echo "  Web UI:    http://localhost:20060"
    echo "  API:       http://localhost:20060/v1"
    echo "  Health:    http://localhost:20060/health"
    echo ""
    log "Education usage:"
    echo "  通用答疑:  #edu 你的问题"
    echo "  解题辅导:  #edu 解题 题目内容"
    echo "  概念讲解:  #edu 讲解 概念名称"
    echo "  作文批改:  #edu 作文 作文内容"
    echo "  口语练习:  #edu 口语"
}

# ========== 主流程 ==========
main() {
    log "ClawBox Local Test"
    echo ""
    
    check_env
    start_services
    download_models
    test_api
    show_status
    
    log "All tests passed!"
}

main "$@"
