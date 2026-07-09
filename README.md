# ClawBox — 教育 AI 服务器

> 开箱即用的教育 AI 服务器，为学校/培训机构提供私有化 AI 教学助手。

## 产品特性

- 🎓 **教育场景预置** — 作业答疑、知识点讲解、作文批改、口语练习
- 🚀 **即插即用** — 开机自动启动，5 分钟搞定
- 🔒 **数据隐私** — 数据不出校园，满足合规要求
- 💰 **省钱** — 语义缓存，相似问题不重复调 API
- 🔄 **OTA 升级** — 远程自动更新，无需运维

## 快速开始

### 方式一：Docker 部署（推荐）

```bash
# 1. 克隆项目
git clone <repo-url> clawbox
cd clawbox

# 2. 配置环境变量
cp .env.example .env
nano .env  # 填入 API Key 和管理员密码

# 3. 启动服务
docker compose up -d

# 4. 访问 Web 界面
open http://localhost:20060
```

### 方式二：系统镜像部署

```bash
# 构建系统镜像
cd image
sudo ./build.sh image

# 刷写到 U 盘/SD 卡
sudo dd if=output/clawbox-1.0.0.img.gz | gunzip | sudo dd of=/dev/sdX bs=4M status=progress

# 插入设备，开机即用
```

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

## 项目结构

```
clawbox/
├── docker-compose.yml     # 服务编排
├── .env.example           # 环境变量模板
├── ota/
│   └── ota-agent.sh       # OTA 升级代理
├── scripts/
│   ├── first-boot.sh      # 首次启动向导
│   └── test.sh            # 本地测试脚本
├── image/
│   └── build.sh           # 系统镜像构建
└── config/
    └── education.yaml     # 教育场景配置
```

## 硬件要求

| 配置 | 最低要求 | 推荐配置 |
|------|---------|---------|
| CPU | 2核 x86_64 | N100 4核 |
| 内存 | 4GB | 8GB |
| 存储 | 32GB | 256GB SSD |
| 网络 | 千兆以太网 | — |

## 产品线

| 档位 | 配置 | 功能 | 零售价 |
|------|------|------|--------|
| Lite | N100/8G/256G | 基础代理 | ¥799 |
| Pro | N100/8G/256G | +语义缓存 | ¥999 |
| Max | N305/16G/512G | +本地LLM | ¥1499 |

## 文档

- [部署指南](docs/deployment.md)
- [用户手册](docs/user-guide.md)
- [开发者文档](docs/developer.md)

## License

MIT
