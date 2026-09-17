# AIRouter 连接体验设计

> 本文档描述当前实现（固定单服务器 App）。以实际代码为准：
> 默认服务器常量见 `entry/src/main/ets/model/AppConfig.ets`，交互实现见
> `entry/src/main/ets/components/ConnectionHome.ets`。

## 1. 定位

AIRouter 是一款 HarmonyOS 客户端，用来操作远端 Linux 服务器上的 OpenCode。
客户端只负责连接、认证、会话与文件交互，不直接连接 SSH、不执行 shell、不保存系统密码。

本设计聚焦连接体验：

- 首次启动如何**自动连接并激活**唯一的固定服务器。
- 连接地址固定、不可修改，连接不可新增/删除。
- 服务器自动分配、只读展示的**设备注册码**。
- 连接后如何进入会话与文件工作区。

## 2. 设计原则

视觉风格保持简洁、专业、安静、可信赖，并带轻微科技感。

- 背景以深色终端风为主，使用低饱和配色与细边框。
- 组件使用小圆角、细边框和轻微阴影。
- 按钮和输入框保持克制，文案清楚，不做夸张装饰。
- 动效只用于状态切换和反馈，保持轻微、流畅。

推荐颜色（终端主题，节选）：

```text
Background:        #0B0F14
Panel:             #111820
Border:            #22303C
Primary text:      #E6EDF3
Muted text:        #8B98A5
Accent:            #3B82F6
Danger:            #DC2626
Success:           #16A34A
```

推荐尺寸：

```text
Card radius:       10-20 vp
Button radius:     8-12 vp
Icon button size:  36-44 vp
Page horizontal:   16 vp
Card spacing:      12 vp
```

## 3. 非目标

- 不做 SSH 客户端，不保存 Linux 系统账号密码。
- 不把 AI 供应商 API Key 下发到手机。
- 不允许手机端输入任意服务器命令。
- **不支持用户新增/修改服务器地址**（App 固定单一服务器）。
- **不支持删除连接**。

## 4. 服务器与认证模型

客户端连接自托管网关（默认 `https://8.153.174.88:8443`，见 `AppConfig.ets`），不是 Linux SSH。

- **固定服务器**：地址、端口、证书均内置；用户不可修改，也不能新增其它服务器。
- **证书固定**：App 只信任内置证书 `entry/src/main/resources/rawfile/codex-router-cert.pem`。
- **注册开放**：`register` 只需 `deviceId` 与设备 Ed25519 公钥，无需注册码。
- **自动分配注册码**：服务器首次为该设备随机生成注册码并绑定（`used_by_device` 唯一），之后不变、不可换绑；客户端只读展示。
- 设备用私钥对 `challenge` 签名完成 `activate`，之后请求携带 `authorization: Bearer <accessToken>`。
- 设备私钥由 HUKS 生成与存储，不出安全硬件。

## 5. 端侧连接数据

端侧只保存连接元数据与 token 引用（不保存密码）；`privateKeyRef` 字段用于保存服务器分配的注册码（只读展示）。

```json
{
  "id": "8.153.174.88",
  "name": "AIRouter",
  "agent": "OpenCode",
  "host": "8.153.174.88",
  "port": 8443,
  "scheme": "https",
  "lastUsedAt": "2026-09-17T12:00:00+08:00",
  "status": "online",
  "accessTokenRef": "<access token>",
  "refreshTokenRef": "<refresh token>",
  "privateKeyRef": "air-xxxxxxxxxxxxxxxx"
}
```

规则：

- **最多保存 1 个连接**（`MAX_CONNECTIONS = 1`）。
- 启动时会丢弃非默认端点的旧连接。
- 连接名称可编辑；服务器地址不可编辑。

## 6. 首屏与启动

启动时（`loadSavedConnections`）：

1. 读取本地连接，**只保留默认端点**的连接。
2. 若无有效连接 → **自动进入连接流程**（固定地址、只读展示），调用 `register` + `activate` 完成激活。
3. 激活成功 → 进入会话列表（工作台）。
4. 激活失败（离线/证书/服务未启动）→ 停留在连接页并给出错误，可点击“连接”重试。

连接页包含：

```text
服务器地址（只读，标注“固定 · 不可修改”）
测试连接（测试固定服务器 /health）
注册码（只读，连接后自动分配）
连接名称（可选）
连接
```

## 7. 连接卡片与编辑

- 连接卡片展示：连接名称、服务器地址、状态（在线/离线/需要登录/未检测）。
- 点击卡片的行为、编辑入口与右滑手势沿用现有实现；**不提供“删除连接”**。
- 编辑连接：只能修改**连接名称**；服务器地址只读、保存时强制写回固定值。
- 不提供“新建连接”入口（`canAddConnection` 在已有连接时为 false）。

## 8. 工作台入口

连接成功后进入工作台，包含：

- 会话列表：列出**本设备**的历史会话，可恢复、重命名、删除（会话级删除保留）。
- 会话内容：消息收发、等待/停止、长任务异步不阻塞；文件/工具进度可见。
- 文件区：列出**本设备会话产出**的文件（按文件名校验归属），可下载/打开。

## 9. API 依赖

### 9.1 设备注册与激活

```http
POST /api/auth/register   { "deviceId": "...", "publicKey": "..." }
                          -> { "activationToken": "...", "challenge": "...", "registrationCode": "air-..." }

POST /api/auth/activate   { "deviceId": "...", "activationToken": "...", "signedChallenge": "..." }
                          -> { "accessToken": "...", "refreshToken": "...", "registrationCode": "air-..." }
```

### 9.2 登录与刷新

```http
POST /api/auth/challenge  { "deviceId": "..." }        -> { "nonce": "...", "expiresAt": "..." }
POST /api/auth/verify     { "deviceId": "...", "nonce": "...", "signature": "..." } -> tokens
POST /api/auth/refresh    { "refreshToken": "..." }    -> { "accessToken": "..." }
POST /api/auth/logout     { "refreshToken": "..." }
GET  /api/auth/me                                       -> { deviceId, sessionName, registrationCode }
```

### 9.3 会话与文件

```http
GET    /api/opencode/resumes
POST   /api/opencode/resumes
POST   /api/opencode/resumes/{id}/resume
POST   /api/opencode/resumes/{id}/name
POST   /api/opencode/resumes/{id}/messages
DELETE /api/opencode/resumes/{id}
GET    /api/files
GET    /api/files/{name}/download
```

## 10. 验收标准

- App 内置固定服务器地址与证书，用户无法修改，也无法新增/删除连接。
- 首次启动自动完成注册与激活；失败时可重试。
- 注册码由服务器自动分配、只读展示、绑定本设备且不可更改。
- 设备私钥存 HUKS；端侧不保存明文密码。
- 会话与文件按设备归属隔离；文件区只展示本设备会话产出的文件。
- 顶部不再显示服务器目录路径副标题；会话标题按首句自动命名且可重命名。
