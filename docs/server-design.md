# AIRouter 服务端设计

> 本文档对应当前实现：`gateway/server.mjs`（认证/路由）、`gateway/auth.mjs`、
> `gateway/db.mjs`、`gateway/file-service.mjs`、`gateway/opencode-server.mjs`。
> 设备认证细节见 [device-auth-design.md](device-auth-design.md)，部署见 [deploy.md](deploy.md)。

## 1. 定位

服务端运行在 Linux（ECS）上，核心进程是 `gateway/server.mjs`。它把 HarmonyOS 客户端的请求
转换为受控的 OpenCode 操作，并保证**按设备隔离**。

服务端职责：

- 开放注册 + 为设备自动分配注册码 + Ed25519 设备签名认证。
- 签发和刷新访问令牌。
- 管理 OpenCode 会话（列表/创建/恢复/重命名/归档/删除/消息）并做**设备归属校验**。
- 登记并按设备展示会话产出的文件。
- 下发 TURN/ICE 配置。
- 提供健康检查与任务占位接口。

服务端不做：

- 不提供任意 shell API；不让手机直接 SSH。
- 不把 AI 供应商 API Key 返回给客户端。
- 不接受客户端提交任意文件系统路径。

## 2. 总体架构

```text
HarmonyOS App
  -> HTTPS(8443) / HTTP(8080)
gateway/server.mjs
  -> auth.mjs / db.mjs (SQLite)
  -> file-service.mjs
  -> opencode-server.mjs
       -> opencode serve (HTTP, 127.0.0.1:4096)
       -> opencode db (CLI, 读取会话列表)
  -> 服务器文件系统（OPENCODE_WORKDIR，如 /root）
```

技术栈：

- 运行时：Node.js 22+。
- 数据库：SQLite（`better-sqlite3`）。
- 进程管理：systemd（`codex-router.service`）。
- TLS：由网关直接使用证书监听 HTTPS（`GATEWAY_TLS_KEY/CERT`），无需反向代理。

## 3. 服务地址与端口

| 入口 | 默认 | 说明 |
|---|---|---|
| HTTPS | `0.0.0.0:8443` | 主入口，App 使用 |
| HTTP | `0.0.0.0:8080` | 调试入口 |

健康检查：

```http
GET /health
-> { "status": "ok", "sessionName": "opencode-main" }
```

App **内置固定服务器地址**（`entry/src/main/ets/model/AppConfig.ets`）并使用**证书固定**校验，
因此生产环境的地址与证书必须与 App 内置一致。

## 4. 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `GATEWAY_HOST` | `0.0.0.0` | 监听地址 |
| `GATEWAY_PORT` | `8443` | HTTPS 端口 |
| `GATEWAY_HTTP_PORT` | `8080` | HTTP 端口 |
| `GATEWAY_TLS_KEY` / `GATEWAY_TLS_CERT` | - | TLS 证书路径 |
| `OPENCODE_COMMAND` | `opencode` | opencode 可执行文件 |
| `OPENCODE_WORKDIR` | `$HOME` | opencode 工作目录 / 文件根目录 |
| `OPENCODE_SERVER_URL` | `http://127.0.0.1:4096` | opencode serve 地址 |
| `AI_ROUTER_SIGNING_KEY_PATH` | `./keys/jwt-signing.pem` | Ed25519 签名私钥 |
| `AI_ROUTER_SIGNING_PUB_PATH` | `./keys/jwt-signing.pub` | 签名公钥 |
| `AI_ROUTER_SIGNING_PUB_PREV_PATH` | `<pub>.prev` | 轮换前的上一个公钥（可选） |
| `AI_ROUTER_DB_PATH` | `./data/devices.db` | SQLite 数据库路径 |
| `COTURN_HOST/PORT/USER/PASS` | - | TURN/STUN 配置 |

## 5. 设备认证

不依赖 Linux 系统账号，无用户名/密码。流程：

```text
POST /api/auth/register    { deviceId, publicKey }                -> { activationToken, challenge, registrationCode }
POST /api/auth/activate    { deviceId, activationToken, signedChallenge } -> { accessToken, refreshToken, registrationCode }
POST /api/auth/challenge   { deviceId }                           -> { nonce, expiresAt }
POST /api/auth/verify      { deviceId, nonce, signature }         -> { accessToken, refreshToken }
POST /api/auth/refresh     { refreshToken }                       -> { accessToken }
POST /api/auth/logout      { refreshToken }                       -> { ok: true }
POST /api/auth/reregister  { deviceId, publicKey, mode }          -> tokens（mode="reset"，无需注册码）
GET  /api/auth/me                                                 -> { deviceId, sessionName, registrationCode }
```

规则：

- **注册开放**：`register` 只需 `deviceId` 与设备公钥；服务器为该设备**自动分配注册码**并绑定（不可更改/换绑）。
- 设备用私钥对挑战签名完成 `activate`；`verify` 用于已注册设备登录。
- 访问令牌为 Ed25519 签名的 JWT（约 15 分钟）；刷新令牌 7 天、存哈希。
- 速率限制：register/activate/challenge/verify/refresh/reregister 分别限流。
- 签名密钥支持轮换：验证访问令牌时依次尝试当前与 `.prev` 公钥。

## 6. Token 策略

- **Access Token**：Ed25519 JWT，约 15 分钟，放在 `authorization: Bearer <token>`。
- **Refresh Token**：`rt-<uuid>`，服务端只存 `sha256` 哈希，7 天有效，可注销/吊销。
- 重建服务器签名密钥会使所有旧访问令牌失效；刷新令牌存库，不受影响。

## 7. 项目

`GET /api/projects` 返回服务端配置的固定项目：

```json
{ "items": [ { "id": "codex-router", "name": "AI Router", "defaultBranch": "master", "status": "ready", "permissions": ["task:create", "task:read", "task:write", "diff:read", "approval:review"] } ] }
```

## 8. OpenCode 适配层

`gateway/opencode-server.mjs` 的 `OpenCodeServerClient` 是服务端与 OpenCode 的边界：

- 启动/复用 `opencode serve`（`ensureReady`），`OPENCODE_WORKDIR` 作为进程 cwd。
- `listResumes`：通过 `opencode db "select … from session …" --format json` 读取会话列表（带短 TTL 缓存，变更时失效）。
- `readResume`：HTTP `GET /session/:id` 与 `GET /session/:id/message`，并映射为会话回合；同时用 `extractFilePathsFromMessages` 提取产出文件。
- `sendResumeMessage`：使用 **`POST /session/:id/prompt_async`**（发送即返回 204，不等待生成），随后读取快照。
- `renameResume` / `archiveResume` / `deleteResume`：重命名走 HTTP PATCH，归档/删除走 opencode CLI。
- 每请求可携带 `directory` 参数（前向兼容；当前 opencode 版本不据此切换目录）。

## 9. 会话 API（按设备隔离）

```http
GET    /api/opencode/resumes                 仅返回本设备会话
POST   /api/opencode/resumes                 创建会话（写入设备归属）
POST   /api/opencode/resumes/{id}/resume     恢复（校验归属，非本设备 404）
POST   /api/opencode/resumes/{id}/name       重命名（校验归属）
POST   /api/opencode/resumes/{id}/archive    归档（校验归属）
DELETE /api/opencode/resumes/{id}            删除（校验归属）
POST   /api/opencode/resumes/{id}/messages   发送消息（校验归属，异步返回）
```

归属通过 `device_sessions(thread_id → device_id)` 持久化，gateway 重启不丢；
`requireThreadOwnership` 对非归属方返回 404（不泄漏会话存在）。

## 10. 任务 API（占位）

```http
POST /api/projects/{projectId}/tasks   { message, sandbox?, networkEnabled? } -> { taskId, status: "queued" }
GET  /api/tasks/{taskId}               查询任务状态
```

当前任务为内存态占位实现（创建即 `queued`），实际的 AI 交互通过会话消息完成。

## 11. 文件（会话 → 文件归属）

openCode 实际在 `OPENCODE_WORKDIR` 下读写文件，且不按会话切换目录，因此文件隔离采用**登记式归属**：

- 读会话时从消息 parts（`file` part 的 filename；`write/edit/patch` 等工具 input/metadata 中的路径；bash 命令/输出中的路径）与会话 diff 提取文件路径。
- 路径经 `session_files(thread_id, device_id, path, name, size, modified_at)` 登记，按设备归属。
- `GET /api/files` 汇总**本设备可见文件**：已登记文件 ∪ 本设备专属工作区目录（`workspaces/<sha256(deviceId)>`）下实际存在的文件；返回**扁平文件名（basename）**、size、modifiedAt。
- `GET /api/files/{name}/download` 在“本设备可见文件”集合中按 basename 匹配（否则 404），流式下载——限定设备范围，杜绝越权/穿越。
- 这样即使某文件未被消息提取到（如脚本间接产出），只要它落在设备工作区里，也能被列出与下载。

## 12. 数据模型（SQLite）

```sql
CREATE TABLE devices (
  device_id TEXT PRIMARY KEY,
  public_key_pem TEXT NOT NULL,
  device_name TEXT DEFAULT '',
  registered_at TEXT,
  last_seen_at TEXT,
  status TEXT DEFAULT 'active'
);

CREATE TABLE refresh_tokens (
  token_hash TEXT PRIMARY KEY,
  device_id TEXT,
  created_at TEXT,
  expires_at TEXT
);

CREATE TABLE activation_nonces (
  nonce TEXT PRIMARY KEY,
  device_id TEXT,
  activation_token TEXT UNIQUE,
  public_key_pem TEXT,
  registration_code TEXT,
  created_at TEXT,
  expires_at TEXT,
  used INTEGER DEFAULT 0
);

CREATE TABLE login_nonces (
  nonce TEXT PRIMARY KEY,
  device_id TEXT,
  created_at TEXT,
  expires_at TEXT,
  used INTEGER DEFAULT 0
);

CREATE TABLE registration_codes (
  code TEXT PRIMARY KEY,
  used INTEGER DEFAULT 0,
  uses INTEGER DEFAULT 0,
  max_uses INTEGER DEFAULT -1,
  used_by_device TEXT DEFAULT NULL,
  used_at TEXT DEFAULT NULL
);

CREATE TABLE device_sessions (
  thread_id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  created_at TEXT
);

CREATE TABLE session_files (
  thread_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  path TEXT NOT NULL,
  name TEXT NOT NULL,
  size INTEGER DEFAULT 0,
  modified_at TEXT DEFAULT '',
  created_at TEXT,
  PRIMARY KEY (thread_id, path)
);
```

启动时会做兼容迁移：`registration_codes(used_by_device)` 去重后建唯一索引（一设备一码）。

## 13. 错误格式

```json
{ "error": { "code": "invalid_request", "message": "…", "requestId": "req_<uuid>" } }
```

常用错误码：`invalid_request`、`invalid_code`、`token_missing`、`token_expired`、
`device_mismatch`、`invalid_signature`、`session_not_found`、`file_not_found`、
`files_root_unset`、`rate_limited`、`gateway_unavailable`。

## 14. 安全边界

- 全链路 HTTPS；App 使用**证书固定**，只信任内置证书对应的服务器。
- App 不直连 SSH，不持有 AI 供应商 API Key。
- 会话与文件按 `deviceId` 归属隔离（列表 + 下载均校验）。
- 设备私钥保存在客户端 HUKS，服务端只存公钥。
- 接口限流；敏感操作（注册/激活/登录）限流更严格。
- 注册码绑定设备且不可换绑；服务器签名密钥支持轮换。

## 15. Linux 部署

部署目录（当前 ECS `8.153.174.88`）：

```text
/opt/codex-router/
  codex-router-master/        # git clone（master）
    gateway/                  # 网关源码
    data/devices.db           # SQLite（AI_ROUTER_DB_PATH 默认 ./data/devices.db）
    keys/jwt-signing.pem|pub  # Ed25519 签名密钥
  certs/                      # TLS 证书
```

systemd 单元（`/etc/systemd/system/codex-router.service`）：

```ini
[Unit]
Description=Codex Router Gateway
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/codex-router/codex-router-master
ExecStart=/usr/bin/node gateway/server.mjs
Environment=OPENCODE_COMMAND=opencode
Environment=OPENCODE_WORKDIR=/root
Environment=GATEWAY_HOST=0.0.0.0
Environment=GATEWAY_PORT=8443
Environment=GATEWAY_HTTP_PORT=8080
Environment=GATEWAY_TLS_KEY=/opt/codex-router/certs/key.pem
Environment=GATEWAY_TLS_CERT=/opt/codex-router/certs/cert.pem
Environment=COTURN_HOST=8.153.174.88
Environment=COTURN_PORT=3478
Environment=COTURN_USER=codexrouter
Environment=COTURN_PASS=***
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

运维脚本见 `scripts/`（部署、证书、签名密钥轮换、注册码/设备管理）。

## 16. 测试与验收

- 网关测试：`cd gateway && node --test server.test.mjs opencode-server.test.mjs`（当前 **35/35 通过**）。
- 覆盖：注册/激活/挑战/验证/刷新、会话归属与越权拦截、文件登记与下载、错误与限流。
- 验收要点：
  - `curl -k https://<host>:8443/health` 返回 `{"status":"ok",…}`。
  - 注册开放、自动分配设备码；重复注册沿用同一码。
  - 设备 A 无法列出/下载设备 B 的会话与文件。
  - App 内置固定地址与证书即可连接，无需用户配置。
