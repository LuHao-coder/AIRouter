# AIRouter

AIRouter 是 HarmonyOS 客户端 + OpenCode Gateway 组成的远程 AI 编码助手网关系统。HarmonyOS App 通过 HTTPS 连接您自建服务器上的 Gateway，与 OpenCode AI 助手交互，支持多网关管理、会话历史恢复与继续、设备认证。

## 目录

```text
AppScope/                 HarmonyOS 应用配置
entry/                    HarmonyOS entry 模块（App 主体）
gateway/                  Node.js Gateway 服务
scripts/                  ECS 部署与工具脚本
docs/                     设计文档与部署指南
store-assets/             AppGallery 上架素材（隐私政策、描述、软著材料）
start-gateway.sh          本地/ECS 网关启动脚本
```

## 架构

```text
┌─────────────┐   HTTPS(8443)   ┌────────────────┐   opencode CLI   ┌──────────┐
│ HarmonyOS   │ ──────────────▶ │ Gateway        │ ───────────────▶ │ AI 助手  │
│ AIRouter App│  HTTP(8080)     │ gateway/       │  websocket       │ (opencode)│
└─────────────┘                 │ server.mjs     │                  └──────────┘
                                └────────────────┘
```

- Gateway 提供 HTTPS/HTTP 双入口、设备注册/激活认证、TURN/ICE 配置、OpenCode 会话恢复与消息转发。
- 设备认证基于 Ed25519 签名 + 一次性注册码：新设备用注册码完成 `register`，再对 `challenge` 签名完成 `activate`，之后所有请求使用签名令牌。
- App 内置固定 TLS 证书（`entry/src/main/resources/rawfile/codex-router-cert.pem`），只信任该证书签发的服务器，请使用与之一致的自签名证书。

## 快速开始

### 1. 部署 Gateway

部署请见 [docs/deploy.md](docs/deploy.md) 或一键脚本 [scripts/deploy-new-ecs.sh](scripts/deploy-new-ecs.sh)（当前 ECS `8.153.174.88`）。

本地启动（先安装 Node.js 22、opencode，并生成签名密钥与证书）：

```bash
# 生成 Ed25519 设备认证签名密钥
node scripts/generate-signing-key.mjs

# 生成 TLS 证书（SAN 需包含服务器 IP）
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /tmp/airouter-gateway-key.pem \
  -out /tmp/airouter-gateway-cert.pem \
  -days 365 -subj "/CN=codex-router" \
  -addext "subjectAltName=IP:127.0.0.1,IP:<服务器IP>"

# 启动（可改为环境变量或 systemd 注入）
./start-gateway.sh
```

验证：

```bash
curl -k https://127.0.0.1:8443/health
```

### 2. 构建并安装 App

使用 DevEco Studio 打开本目录，或命令行构建：

```bash
hvigorw --mode module -p product=default -p module=entry@default \
  -p buildMode=release assembleHap --analyze=normal --parallel --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-signed.hap`。在 App 中填入服务器地址 `https://<IP>:8443` 和注册码即可连接。

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `GATEWAY_HOST` | `0.0.0.0` | 监听地址 |
| `GATEWAY_PORT` | `8443` | HTTPS 端口 |
| `GATEWAY_HTTP_PORT` | `8080` | HTTP 端口（调试） |
| `GATEWAY_TLS_KEY` / `GATEWAY_TLS_CERT` | - | TLS 证书路径 |
| `OPENCODE_COMMAND` | `opencode` | opencode 可执行文件 |
| `OPENCODE_WORKDIR` | `$HOME` | opencode 工作目录 |
| `OPENCODE_SERVER_URL` | - | opencode 服务地址 |
| `AI_ROUTER_SIGNING_KEY_PATH` | `./keys/jwt-signing.pem` | 设备认证签名私钥 |
| `AI_ROUTER_SIGNING_PUB_PATH` | `./keys/jwt-signing.pub` | 签名公钥 |
| `AI_ROUTER_DB_PATH` | `./data/devices.db` | SQLite 数据库路径 |
| `COTURN_HOST` / `COTURN_PORT` / `COTURN_USER` / `COTURN_PASS` | - | TURN/STUN 服务器配置 |

## 常用接口

```text
GET  /health
POST /api/auth/register            设备注册（携带注册码）
POST /api/auth/activate            设备激活（对 challenge 签名）
POST /api/auth/challenge           获取激活挑战
POST /api/auth/verify              校验签名令牌
POST /api/auth/refresh             刷新令牌
POST /api/auth/logout              注销
POST /api/auth/reregister          重新注册（换新注册码）
GET  /api/auth/me                  当前设备信息
GET  /api/turn/ice-config          TURN/ICE 配置
GET  /api/projects
GET  /api/opencode/resumes         会话列表
POST /api/opencode/resumes         创建会话
POST /api/opencode/resumes/{id}/resume    恢复会话
POST /api/opencode/resumes/{id}/name     重命名会话
POST /api/opencode/resumes/{id}/messages  发送消息
DELETE /api/opencode/resumes/{id}        删除会话
POST /api/projects/{name}/tasks   创建任务
GET  /api/tasks/{id}              查询任务
```

## 测试

```bash
cd gateway && node --test server.test.mjs opencode-server.test.mjs
```

HarmonyOS 侧单元测试见 `entry/src/test/`。

## 文档

- [gateway/README.md](gateway/README.md) — Gateway 使用说明
- [docs/deploy.md](docs/deploy.md) — ECS 部署指南
- [docs/device-auth-design.md](docs/device-auth-design.md) — 设备认证方案
- [docs/connection-design.md](docs/connection-design.md) — 连接体验设计
- [docs/server-design.md](docs/server-design.md) — 服务端设计
