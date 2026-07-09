#!/bin/bash
# ClawBox 首次启动向导
# 引导用户完成初始配置

set -euo pipefail

CLAWBOX_DIR="/opt/clawbox"
ENV_FILE="${CLAWBOX_DIR}/.env"
SETUP_DONE="${CLAWBOX_DIR}/.setup_done"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║                                                  ║"
    echo "║        🎓 ClawBox 教育 AI 服务器 初始化          ║"
    echo "║                                                  ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_step() {
    echo -e "\n${BLUE}[$1/5]${NC} ${GREEN}$2${NC}"
}

print_info() {
    echo -e "  ${YELLOW}→${NC} $1"
}

print_success() {
    echo -e "  ${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "  ${RED}✗${NC} $1"
}

# ========== 步骤 1：设置管理员密码 ==========
setup_admin() {
    print_step "1" "设置管理员账号"

    local username="admin"
    local password=""

    while true; do
        read -rsp "  请输入管理员密码 (至少6位): " password
        echo
        if [ ${#password} -ge 6 ]; then
            break
        fi
        print_error "密码至少需要 6 位"
    done

    local confirm=""
    read -rsp "  确认密码: " confirm
    echo

    if [ "$password" != "$confirm" ]; then
        print_error "两次输入的密码不一致"
        return 1
    fi

    # 写入 .env
    sed -i "s/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=${password}/" "$ENV_FILE"
    print_success "管理员密码已设置"
}

# ========== 步骤 2：配置 API Key ==========
setup_api_key() {
    print_step "2" "配置 LLM API Key"

    echo "  支持的模型服务:"
    echo "    1. OpenAI (GPT-4/GPT-3.5)"
    echo "    2. DeepSeek"
    echo "    3. 通义千问 (DashScope)"
    echo "    4. 智谱 AI (GLM)"
    echo "    5. 跳过 (稍后配置)"
    echo ""

    local choice=""
    read -rp "  请选择 [1-5]: " choice

    case "$choice" in
        1)
            local key=""
            read -rsp "  请输入 OpenAI API Key: " key
            echo
            if [ -n "$key" ]; then
                echo "OPENAI_API_KEY=${key}" >> "$ENV_FILE"
                print_success "OpenAI API Key 已配置"
            fi
            ;;
        2)
            local key=""
            read -rsp "  请输入 DeepSeek API Key: " key
            echo
            if [ -n "$key" ]; then
                echo "DEEPSEEK_API_KEY=${key}" >> "$ENV_FILE"
                print_success "DeepSeek API Key 已配置"
            fi
            ;;
        3)
            local key=""
            read -rsp "  请输入 DashScope API Key: " key
            echo
            if [ -n "$key" ]; then
                echo "DASHSCOPE_API_KEY=${key}" >> "$ENV_FILE"
                print_success "DashScope API Key 已配置"
            fi
            ;;
        4)
            local key=""
            read -rsp "  请输入智谱 AI API Key: " key
            echo
            if [ -n "$key" ]; then
                echo "ZHIPU_API_KEY=${key}" >> "$ENV_FILE"
                print_success "智谱 AI API Key 已配置"
            fi
            ;;
        5)
            print_info "跳过 API Key 配置，稍后通过 Web 界面设置"
            ;;
        *)
            print_error "无效选择"
            return 1
            ;;
    esac
}

# ========== 步骤 3：设置设备名称 ==========
setup_device() {
    print_step "3" "设置设备信息"

    local hostname="clawbox"
    read -rp "  设备名称 [clawbox]: " hostname
    hostname="${hostname:-clawbox}"

    sed -i "s/^DEVICE_ID=.*/DEVICE_ID=${hostname}/" "$ENV_FILE"
    hostnamectl set-hostname "$hostname" 2>/dev/null || true
    print_success "设备名称: $hostname"
}

# ========== 步骤 4：网络配置 ==========
setup_network() {
    print_step "4" "网络配置"

    local port="20060"
    read -rp "  proxyclaw 端口 [20060]: " port
    port="${port:-20060}"

    sed -i "s/^PROXYCLAW_PORT=.*/PROXYCLAW_PORT=${port}/" "$ENV_FILE"
    print_success "服务端口: $port"

    # 显示 IP 地址
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "未获取到")
    print_info "设备 IP 地址: $ip"
    print_info "Web 界面地址: http://${ip}:${port}"
}

# ========== 步骤 5：启动服务 ==========
start_services() {
    print_step "5" "启动服务"

    cd "$CLAWBOX_DIR"

    print_info "拉取镜像..."
    docker compose pull 2>&1 | tail -3

    print_info "启动容器..."
    docker compose up -d 2>&1 | tail -5

    print_info "等待服务就绪..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if curl -sf http://localhost:20060/health >/dev/null 2>&1; then
            print_success "proxyclaw 服务已就绪!"
            break
        fi
        retries=$((retries - 1))
        sleep 2
    done

    if [ $retries -eq 0 ]; then
        print_error "服务启动超时，请检查日志: docker compose logs"
        return 1
    fi

    # 下载 embedding 模型
    print_info "下载 Embedding 模型 (bge-m3)..."
    docker exec clawbox-ollama ollama pull bge-m3 2>&1 | tail -2
    print_success "Embedding 模型就绪"
}

# ========== 完成 ==========
show_completion() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "未获取到")
    local port
    port=$(grep PROXYCLAW_PORT "$ENV_FILE" | cut -d= -f2 || echo "20060")

    echo ""
    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║                                                  ║"
    echo "║              🎉 初始化完成!                      ║"
    echo "║                                                  ║"
    echo "╠══════════════════════════════════════════════════╣"
    echo "║                                                  ║"
    echo "║  Web 界面:  http://${ip}:${port}                ║"
    echo "║  管理账号:  admin                                ║"
    echo "║                                                  ║"
    echo "║  教育场景:  发送 #edu 即可进入教育模式            ║"
    echo "║                                                  ║"
    echo "║  更多功能请访问 Web 界面探索!                     ║"
    echo "║                                                  ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ========== 主流程 ==========
main() {
    # 检查是否已完成设置
    if [ -f "$SETUP_DONE" ]; then
        echo "ClawBox 已完成初始化。如需重新设置，请删除 $SETUP_DONE"
        exit 0
    fi

    # 检查 .env
    if [ ! -f "$ENV_FILE" ]; then
        cp "${CLAWBOX_DIR}/.env.example" "$ENV_FILE"
    fi

    print_header

    echo "  欢迎使用 ClawBox 教育 AI 服务器!"
    echo "  本向导将引导您完成初始配置，大约需要 2-3 分钟。"
    echo ""
    read -rp "  按 Enter 开始..." _

    setup_admin || exit 1
    setup_api_key || exit 1
    setup_device || exit 1
    setup_network || exit 1
    start_services || exit 1

    touch "$SETUP_DONE"
    show_completion
}

main "$@"
