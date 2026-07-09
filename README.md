# ClawBox — 教育 AI 服务器

> 开箱即用的教育 AI 服务器，为学校/培训机构提供私有化 AI 教学助手。

## 产品特性

- 🎓 **教育场景预置** — 作业答疑、知识点讲解、作文批改、口语练习
- 🚀 **即插即用** — 开机自动启动，5 分钟搞定
- 🔒 **数据隐私** — 数据不出校园，满足合规要求
- 💰 **省钱** — 语义缓存，相似问题不重复调用 API
- 📦 **离线部署** — 镜像预打包所有依赖，无需联网即可部署
- 🔄 **OTA 升级** — 远程自动更新，无需运维

---

## 快速开始

### 方式一：Docker Compose 部署（开发/测试推荐）

```bash
# 1. 克隆项目
git clone <repo-url> clawbox
cd clawbox

# 2. 配置环境变量
cp .env.example .env
nano .env  # 填入 LLM API Key 和管理员密码

# 3. 启动所有服务
docker compose up -d

# 4. 访问 Web 界面
open http://localhost:20060
```

首次启动会自动拉取所需镜像（proxyclaw、PostgreSQL + pgvector、Ollama），请确保网络畅通。

### 方式二：Docker 单镜像部署

```bash
# 构建 Docker 镜像
cd image
./build.sh          # 构建 clawbox:1.0.0

# 运行
docker run -d -p 20060:20060 clawbox:1.0.0
```

---

## 系统镜像构建

如果需要将 ClawBox 烧录到物理设备（工控机、迷你主机），可以构建完整的系统镜像。

### 构建磁盘镜像（.img.gz）

适用于直接 `dd` 烧录到 U 盘或硬盘。

```bash
# 一键构建
sudo ./image/quick-build.sh

# 或手动构建（可自定义参数）
sudo ./image/build-os.sh \
    --output-dir ./output \
    --image-size 4G \
    --hostname clawbox
```

构建完成后镜像位于 `output/clawbox-1.0.0-YYYYMMDD.img.gz`。

### 构建 ISO 安装镜像

适用于 Ventoy / Rufus 写入 U 盘安装。

```bash
sudo ./image/build-iso.sh
```

ISO 文件位于 `/tmp/clawbox-build/clawbox-1.0.0-amd64.iso`。

### 构建参数说明

以下参数对 `build-os.sh`、`build-iso.sh`、`quick-build.sh` 均有效：

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--output-dir DIR` | 输出目录 | `./output` |
| `--image-size SIZE` | 镜像大小 | `4G` |
| `--hostname NAME` | 主机名 | `clawbox` |
| `--proxyclaw-repo URL` | proxyclaw GitHub 仓库 | `https://github.com/proxyclaw/proxyclaw.git` |
| `--proxyclaw-branch BR` | proxyclaw 分支 | `main` |
| `--proxyclaw-path PATH` | proxyclaw 本地源码路径 | 空（优先于 GitHub） |
| `--no-proxyclaw` | 跳过构建，直接拉取远程镜像 | `false` |

---

## proxyclaw 集成方式

ClawBox 的核心服务是 **proxyclaw**（AI 代理网关），构建镜像时支持三种集成方式：

### 1. 从本地源码构建（离线环境推荐）

适合在内网或离线环境中，proxyclaw 代码已在本地的情况：

```bash
sudo ./image/quick-build.sh --proxyclaw-path /home/user/proxyclaw
```

镜像构建时会直接使用本地源码 `docker build`，不依赖外部网络。

### 2. 从 GitHub 拉取并构建

适合使用特定分支或 fork 版本：

```bash
# 使用默认仓库的 develop 分支
sudo ./image/quick-build.sh --proxyclaw-branch develop

# 使用自定义仓库
sudo ./image/quick-build.sh \
    --proxyclaw-repo https://github.com/myorg/proxyclaw.git \
    --proxyclaw-branch feature-v2
```

### 3. 直接拉取远程镜像（默认）

不构建，直接从 Docker Hub 拉取：

```bash
sudo ./image/quick-build.sh --no-proxyclaw
```

### 离线部署原理

构建时脚本会自动执行：

1. `docker build` / `docker pull` 获取所有镜像（proxyclaw、pgvector、ollama、ota-agent）
2. 将镜像通过 `docker save` 打包为 tar 文件，存入 `/opt/clawbox/images/`
3. 首次开机时 `first-boot.sh` 自动 `docker load` 本地镜像包
4. 加载完成后清理 tar 包释放空间
5. 如果本地包不存在，回退到在线 `docker compose pull`

---

## 烧录与部署

### 磁盘镜像烧录

```bash
# Linux
gunzip -c clawbox-1.0.0-YYYYMMDD.img.gz | sudo dd of=/dev/sdX bs=4M status=progress

# macOS
gunzip -c clawbox-1.0.0-YYYYMMDD.img.gz | sudo dd of=/dev/rdiskX bs=4m
```

### ISO 烧录

```bash
# 使用 dd
sudo dd if=clawbox-1.0.0-amd64.iso of=/dev/sdX bs=4M status=progress

# 或使用 Ventoy / Rufus / balenaEtcher 写入
```

### 首次启动

设备上电后会自动完成以下操作：

1. 生成随机管理员密码和数据库密码
2. 加载预打包的 Docker 镜像
3. 启动 proxyclaw + PostgreSQL + Ollama
4. 下载 embedding 模型（bge-m3）
5. 标记初始化完成

**默认账号**: `clawbox` / `clawbox123`（首次登录需修改密码）

**管理面板**: `http://设备IP:20060`

---

## 配置说明

### 环境变量 (.env)

```bash
# 设备信息
DEVICE_ID=clawbox-001           # 设备唯一标识
CLAWBOX_VERSION=1.0.0           # 版本号

# 网络
PROXYCLAW_PORT=20060            # Web UI 端口

# 数据库
PG_PASSWORD=clawbox_secret_2026 # PostgreSQL 密码（生产环境请修改）

# 管理员
ADMIN_USERNAME=admin            # 管理员用户名
ADMIN_PASSWORD=admin123         # 管理员密码（首次启动会自动生成随机密码）

# OTA 升级
OTA_SERVER=https://ota.clawbox.ai

# LLM API Keys（至少填一个）
# OPENAI_API_KEY=sk-xxx
# DEEPSEEK_API_KEY=sk-xxx
# DASHSCOPE_API_KEY=sk-xxx

# 镜像配置
PROXYCLAW_IMAGE=proxyclaw/proxyclaw:latest
OTA_IMAGE=clawbox/ota-agent:latest

# 日志
LOG_LEVEL=info
```

### 服务架构

```
┌─────────────────────────────────────────┐
│              用户浏览器                   │
│            http://IP:20060              │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│            proxyclaw                     │
│         (AI 代理网关)                    │
│    端口: 20060                          │
│    依赖: PostgreSQL, Ollama             │
└────┬──────────────┬─────────────────────┘
     │              │
┌────▼────┐   ┌─────▼──────┐
│PostgreSQL│   │  Ollama    │
│+ pgvector│   │ (Embedding)│
│  :5432   │   │  :11434    │
└──────────┘   └────────────┘
```

---

## 使用教育场景

在 Web 界面的对话框中，使用快捷码进入教育模式：

| 快捷码 | 场景 | 说明 |
|--------|------|------|
| `#edu` | 通用答疑 | 默认答疑模式 |
| `#edu 解题` | 解题辅导 | 苏格拉底引导法 |
| `#edu 讲解` | 概念讲解 | 生活类比+举例 |
| `#edu 知识点` | 知识点思考 | 深度学习引导 |
| `#edu 作文` | 作文批改 | 评分+修改建议 |
| `#edu 口语` | 英语口语 | 对话练习+纠错 |

---

## 硬件要求

| 配置 | 最低要求 | 推荐配置 |
|------|---------|---------|
| CPU | 2核 x86_64 | N100 4核 |
| 内存 | 4GB | 8GB |
| 存储 | 32GB（系统） | 256GB SSD |
| 网络 | 千兆以太网 | — |

---

## 项目结构

```
clawbox/
├── docker-compose.yml       # 服务编排
├── Dockerfile               # Docker 镜像构建
├── .env                     # 环境变量（需从 .env.example 复制）
├── ota/
│   └── ota-agent.sh         # OTA 升级代理
├── scripts/
│   ├── first-boot.sh        # 首次启动向导
│   └── test.sh              # 本地测试脚本
├── image/
│   ├── build.sh             # 主构建入口（docker/image 双模式）
│   ├── build-os.sh          # 磁盘镜像构建（.img.gz）
│   ├── build-iso.sh         # ISO 安装镜像构建
│   ├── quick-build.sh       # 一键构建脚本
│   ├── Dockerfile.clawbox   # Docker 模式使用的 Dockerfile
│   └── entrypoint.sh        # Docker 容器入口脚本
└── config/
    └── education.yaml       # 教育场景配置
```

---

## 常用命令速查

```bash
# === Docker Compose 方式 ===
docker compose up -d              # 启动所有服务
docker compose down               # 停止所有服务
docker compose logs -f proxyclaw  # 查看日志
docker compose pull               # 更新镜像

# === 系统镜像构建 ===
sudo ./image/quick-build.sh                          # 一键构建（默认配置）
sudo ./image/quick-build.sh --proxyclaw-path ./src   # 使用本地 proxyclaw
sudo ./image/quick-build.sh --no-proxyclaw           # 拉取远程镜像
sudo ./image/build-iso.sh                            # 构建 ISO 安装盘

# === 烧录 ===
gunzip -c clawbox-*.img.gz | sudo dd of=/dev/sdX bs=4M status=progress  # 烧录磁盘镜像
sudo dd if=clawbox-*.iso of=/dev/sdX bs=4M status=progress              # 烧录 ISO
```

---

## License

MIT
