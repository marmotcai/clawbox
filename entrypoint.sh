#!/bin/bash
set -e

echo "=== ClawBox AI Server ==="

# 首次启动
if [ ! -f /opt/clawbox/.setup_done ]; then
    echo "First boot detected, running setup..."
    /opt/clawbox/first-boot.sh --auto
fi

# 启动服务
cd /opt/clawbox
echo "Starting services..."
docker compose up -d

echo "ClawBox is ready!"
echo "Web UI: http://localhost:20060"

# 保持容器运行
exec sleep infinity
