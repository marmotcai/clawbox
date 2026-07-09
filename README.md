# ClawBox — AI 服务器

> 开箱即用的 AI 服务器，支持多场景扩展（教育、医疗、办公等）。

## 快速开始

### 方式一：Docker（推荐）

```bash
# 1. 克隆仓库
git clone https://github.com/marmotcai/ClawBox.git
cd ClawBox

# 2. 配置环境变量
cp .env.example .env
# 编辑 .env，填入 LLM API Key（至少一个）

# 3. 启动服务
docker compose up -d

# 4. 访问 Web 界面
open http://localhost:20060
```

### 方式二：使用预构建镜像

```bash
# 从 GitHub Container Registry 拉取
docker pull ghcr.io/marmotcai/proxyclaw-amd64:latest
docker pull ollama/ollama:latest
docker pull pgvector/pgvector:pg16

# 启动
docker compose up -d
```

## 配置

### LLM API Key

编辑 `.env`，至少配置一个：

```bash
# OpenAI
OPENAI_API_KEY=sk-xxx

# DeepSeek
DEEPSEEK_API_KEY=sk-xxx

# 通义千问
DASHSCOPE_API_KEY=sk-xxx
```

### 端口

默认端口 `20060`，修改 `.env` 中的 `PROXYCLAW_PORT`：

```bash
PROXYCLAW_PORT=8080
```

## 使用教育场景

在 Web 界面中，使用快捷码进入教育模式：

| 快捷码 | 场景 |
|--------|------|
| `#edu` | 通用答疑 |
| `#edu 解题` | 解题辅导 |
| `#edu 讲解` | 概念讲解 |
| `#edu 作文` | 作文批改 |
| `#edu 口语` | 英语口语 |

## 服务架构

```
┌─────────────────────────────────────────┐
│  ClawBox                                │
├─────────────────────────────────────────┤
│  proxyclaw      :20060    LLM 网关     │
│  PostgreSQL     :5432     数据库       │
│  Ollama         :11434    Embedding    │
│  OTA Agent                 远程升级     │
└─────────────────────────────────────────┘
```

## 项目结构

```
ClawBox/
├── docker-compose.yml      # 服务编排
├── .env.example            # 环境变量模板
├── Dockerfile              # 系统镜像构建
├── README.md               # 本文档
├── config/
│   └── education.yaml      # 教育场景配置
├── image/
│   ├── build.sh            # 系统镜像构建脚本
│   └── Dockerfile.clawbox  # Docker 镜像定义
├── ota/
│   ├── Dockerfile          # OTA Agent 镜像
│   └── ota-agent.sh        # OTA 升级脚本
└── scripts/
    └── first-boot.sh       # 首次启动脚本
```

## 硬件要求

| 配置 | 最低 | 推荐 |
|------|------|------|
| CPU | 2 核 | 4 核 |
| 内存 | 2GB | 4GB |
| 存储 | 20GB | 50GB |

## 产品线

| 产品 | 场景 | 状态 |
|------|------|------|
| ClawBox | 通用 AI 服务器 | ✅ 可用 |
| ClawBox Edu | 教育场景 | ✅ 可用 |
| ClawBox Med | 医疗场景 | 🔜 规划中 |
| ClawBox Legal | 法律场景 | 🔜 规划中 |

## License

MIT
