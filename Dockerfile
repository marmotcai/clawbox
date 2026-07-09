# ClawBox 教育 AI 服务器 — Docker 镜像
# 基于 Debian 12 slim，预装所有运行时依赖

# ============================================================
# 阶段 1: 运行时基础镜像
# ============================================================
FROM debian:bookworm-slim AS base

# 系统配置
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:zh_CN \
    LC_ALL=en_US.UTF-8

# 安装运行时依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    # 基础工具
    ca-certificates tzdata curl wget bash sudo \
    # 网络工具
    iproute2 iputils-ping \
    # 进程管理
    htop tmux \
    # Docker (用于 OTA)
    docker.io docker-compose \
    # 清理
    && rm -rf /var/lib/apt/lists/* \
    && ln -snf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" > /etc/timezone \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
    && locale-gen

# ============================================================
# 阶段 2: ClawBox 应用
# ============================================================
FROM base AS clawbox

WORKDIR /opt/clawbox

# 复制 docker-compose.yml
COPY docker-compose.yml ./

# 复制环境配置
COPY .env.example ./.env

# 复制 OTA Agent
COPY ota/ota-agent.sh ./
RUN chmod +x ota-agent.sh

# 复制首次启动脚本
COPY scripts/first-boot.sh ./
RUN chmod +x first-boot.sh

# 复制教育配置
COPY config/ ./config/

# 创建数据目录
RUN mkdir -p /opt/clawbox/data /var/log/clawbox

# 版本信息
ARG CLAWBOX_VERSION=1.0.0
RUN echo "${CLAWBOX_VERSION}" > VERSION

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD curl -f http://localhost:20060/health || exit 1

# 暴露端口
EXPOSE 20060

# 启动脚本
COPY image/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
