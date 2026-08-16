# AIRouter 服务端设计

> 本文是设计历史文档，部分内容（认证方式、代理栈、接口路径）已随迭代更新。实际实现为 `gateway/server.mjs`，部署见 [deploy.md](deploy.md)，认证见 [device-auth-design.md](device-auth-design.md)。

## 1. 定位

服务端运行在 Linux 上，核心进程是 `gateway/server.mjs`。它负责把 HarmonyOS
客户端的请求转换为受控的 OpenCode 操作。

服务端职责：

- 提供注册码 + 设备签名认证。
- 签发和刷新移动端 token。
- 管理可访问项目。
- 管理 OpenCode 会话（列表/恢复/消息）。
- 下发 TURN/ICE 配置。

服务端不做：

- 不提供任意 shell API。
- 不让手机直接 SSH 到服务器。
- 不把 OpenAI API Key 返回给客户端。
- 不允许客户端提交任意本地文件路径。

## 2. 总体架构

```text
HarmonyOS App
  -> HTTPS
gateway/server.mjs
  -> Auth service
  -> OpenCode adapter
opencode CLI / opencode serve
  -> Git workspaces
```

MVP 推荐：

- 语言：Node.js、Go 或 Rust 任选其一。
- 数据库：SQLite。
- 生产环境：PostgreSQL 可作为团队版升级。
- 进程管理：systemd。
- HTTPS：Caddy 或 Nginx 反向代理。
- 运行用户：独立低权限用户 `codexrouter`。

## 3. 服务地址

默认监听：

```text
127.0.0.1:8443
```

推荐通过反向代理暴露 HTTPS：

```text
https://codex.example.com
https://192.168.1.10:8443
```

客户端可以只输入 IP。客户端负责把 `192.168.1.10` 规范化为
`https://192.168.1.10:8443`。服务端只需要正常处理 HTTPS 请求。

## 4. 配置文件

示例：

```yaml
serverName: codex-main
publicBaseUrl: https://192.168.1.10:8443
listen: 127.0.0.1:8443

auth:
  accessTokenTtlSeconds: 3600
  refreshTokenTtlDays: 30
  maxLoginFailures: 5
  loginLockSeconds: 300

codex:
  binary: /usr/local/bin/opencode
  defaultSandbox: workspace-write
  allowNetworkByDefault: false
  taskRoot: /srv/codex-router/tasks

projects:
  - id: codex-router
    name: AIRouter
    path: /srv/projects/CodexRouter
    defaultBranch: main
    permissions:
      - task:create
      - task:read
      - task:write
      - diff:read
      - approval:review
```

配置要求：

- `serverName` 用于返回给客户端作为默认连接名。
- `projects[].path` 必须是服务端白名单路径。
- 客户端只能通过 `projectId` 访问项目，不能提交任意路径。
- `allowNetworkByDefault` 默认关闭。

## 5. 设备认证

服务端维护注册码与已激活设备表，不依赖 Linux 系统账号。流程为
`register` → `challenge` → `activate`（见 [device-auth-design.md](device-auth-design.md)）。

注册请求：

```http
POST /api/auth/register
Content-Type: application/json
```

```json
{
  "registrationCode": "xxxx",
  "deviceName": "HarmonyOS Phone",
  "publicKey": "<设备 Ed25519 公钥>"
}
```

激活请求：

```http
POST /api/auth/activate
```

登录响应：

```json
{
  "accessToken": "...",
  "refreshToken": "...",
  "codexSessionName": "codex-main",
  "expiresIn": 3600
}
```

认证规则：

- 密码只保存哈希。
- 哈希算法使用 Argon2id，bcrypt 可作为备选。
- 登录失败按用户名和 IP 限流。
- 连续失败达到阈值后短暂锁定。
- 登录成功、登录失败、登出都写入审计日志。

## 6. Token 策略

Access token：

- 生命周期短，推荐 15-60 分钟。
- 用于普通 API 请求。
- 客户端放在内存和系统安全存储中。

Refresh token：

- 生命周期较长，推荐 30 天。
- 与设备绑定。
- 服务端只保存哈希。
- 支持撤销。

刷新接口：

```http
POST /api/auth/refresh
Authorization: Bearer <refreshToken>
```

撤销场景：

- 用户登出。
- 用户删除连接。
- 管理员禁用用户。
- 管理员撤销某台设备。

## 7. 项目访问

项目由服务端配置，客户端只能读取白名单项目。

项目列表接口：

```http
GET /api/projects
Authorization: Bearer <accessToken>
```

返回：

```json
{
  "items": [
    {
      "id": "codex-router",
      "name": "AIRouter",
      "defaultBranch": "main",
      "status": "ready",
      "permissions": [
        "task:create",
        "task:read",
        "task:write",
        "diff:read",
        "approval:review"
      ]
    }
  ]
}
```

安全规则：

- 所有任务必须绑定到 `projectId`。
- `projectId` 必须存在于服务端配置。
- 服务端不接受客户端传入的绝对路径。
- 每个任务建议使用独立 worktree 或任务目录。

## 8. Codex Adapter

`CodexAdapter` 是服务端内部边界，用于隔离 API 层和真实 Codex 执行方式。

MVP 可以先封装 Codex CLI：

- 在指定项目目录启动 Codex。
- 向 Codex 传递用户任务描述。
- 捕获输出。
- 生成任务事件。
- 停止任务。
- 获取 diff。

后续如果需要更深会话、审批和事件集成，再评估 `opencode serve`。

内部接口：

```ts
interface CodexAdapter {
  startTask(input: StartTaskInput): Promise<TaskHandle>;
  appendMessage(taskId: string, message: string): Promise<void>;
  stopTask(taskId: string): Promise<void>;
  getDiff(taskId: string): Promise<DiffResult>;
}
```

任务启动参数：

```ts
interface StartTaskInput {
  taskId: string;
  projectId: string;
  projectPath: string;
  message: string;
  sandbox: "read-only" | "workspace-write" | "danger-full-access";
  networkEnabled: boolean;
  userId: string;
}
```

## 9. 任务状态机

状态：

```text
queued
running
waiting_approval
completed
failed
stopped
```

流转：

```text
queued -> running
running -> waiting_approval
waiting_approval -> running
running -> completed
running -> failed
running -> stopped
waiting_approval -> stopped
```

规则：

- 任务创建后进入 `queued`。
- Codex 进程启动后进入 `running`。
- 需要用户审批时进入 `waiting_approval`。
- 用户批准后回到 `running`。
- 用户拒绝高风险操作时，可继续运行或停止，取决于 Codex 返回状态。
- 用户主动停止时进入 `stopped`。

## 10. 任务 API

创建任务：

```http
POST /api/projects/{projectId}/tasks
Authorization: Bearer <accessToken>
Content-Type: application/json
```

```json
{
  "message": "修复登录页崩溃，并运行测试",
  "sandbox": "workspace-write",
  "networkEnabled": false
}
```

返回：

```json
{
  "taskId": "task_01JZ0001",
  "status": "queued"
}
```

追加消息：

```http
POST /api/tasks/{taskId}/messages
Authorization: Bearer <accessToken>
```

```json
{
  "message": "继续修复失败的单元测试"
}
```

停止任务：

```http
POST /api/tasks/{taskId}/stop
Authorization: Bearer <accessToken>
```

获取 diff：

```http
GET /api/tasks/{taskId}/diff
Authorization: Bearer <accessToken>
```

## 11. 事件流

客户端通过 WebSocket 接收任务事件。

```text
WS /api/tasks/{taskId}/stream
```

事件类型：

```text
task.status
codex.output
command.started
command.finished
approval.requested
approval.resolved
file.changed
test.result
task.summary
error
```

事件示例：

```json
{
  "type": "task.status",
  "taskId": "task_01JZ0001",
  "status": "running",
  "createdAt": "2026-07-01T12:00:00+08:00"
}
```

输出事件：

```json
{
  "type": "codex.output",
  "taskId": "task_01JZ0001",
  "content": "Running tests...",
  "sequence": 42
}
```

## 12. 审批

当 Codex 需要执行敏感操作时，服务端生成审批请求。

审批请求字段：

```json
{
  "approvalId": "appr_001",
  "taskId": "task_01JZ0001",
  "risk": "medium",
  "action": "run_command",
  "command": "npm install",
  "reason": "Install missing dependencies for the project",
  "createdAt": "2026-07-01T12:00:00+08:00"
}
```

审批接口：

```http
POST /api/approvals/{approvalId}/approve
Authorization: Bearer <accessToken>
```

```http
POST /api/approvals/{approvalId}/reject
Authorization: Bearer <accessToken>
```

规则：

- 审批只允许有 `approval:review` 权限的用户操作。
- 批准和拒绝都写入审计日志。
- 高风险操作必须在客户端显示明确风险。
- 服务端不得把审批简化为自动通过。

## 13. 数据模型

MVP 最少需要这些表。

```sql
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  username TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  disabled_at TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE refresh_tokens (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  device_name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  created_at TEXT NOT NULL,
  last_used_at TEXT
);

CREATE TABLE tasks (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  project_id TEXT NOT NULL,
  status TEXT NOT NULL,
  title TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  completed_at TEXT
);

CREATE TABLE approvals (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  user_id TEXT,
  risk TEXT NOT NULL,
  action TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  resolved_at TEXT
);

CREATE TABLE audit_logs (
  id TEXT PRIMARY KEY,
  user_id TEXT,
  task_id TEXT,
  action TEXT NOT NULL,
  metadata_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);
```

## 14. 错误格式

所有 API 错误统一返回：

```json
{
  "error": {
    "code": "invalid_credentials",
    "message": "用户名或密码错误",
    "requestId": "req_01JZ0001"
  }
}
```

常用错误码：

```text
invalid_credentials
token_expired
permission_denied
project_not_found
task_not_found
approval_not_found
gateway_unavailable
codex_failed
rate_limited
```

## 15. 安全边界

必须满足：

- 全链路 HTTPS。
- App 不直连 SSH。
- App 不持有 OpenAI API Key。
- Gateway 使用低权限 Linux 用户运行。
- 项目路径必须白名单化。
- 不暴露任意命令执行接口。
- 敏感操作必须走审批。
- 登录、登出、任务、审批、删除连接都写审计日志。

推荐增强：

- 使用 Tailscale、WireGuard 或 ZeroTier 做私有网络访问。
- 对公网部署添加 IP 白名单。
- 每个任务使用独立 worktree。
- 定期清理过期任务目录和过期 refresh token。

## 16. Linux 部署

推荐目录：

```text
/opt/codex-router/
  codex-gateway
  config.yaml
  data/
    gateway.db
  logs/

/srv/projects/
  CodexRouter/

/srv/codex-router/tasks/
```

systemd 示例：

```ini
[Unit]
Description=AIRouter Gateway
After=network.target

[Service]
User=codexrouter
WorkingDirectory=/opt/codex-router
ExecStart=/opt/codex-router/codex-gateway serve --config /opt/codex-router/config.yaml
Restart=on-failure
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
```

运维命令：

```bash
codex-gateway user create alice
codex-gateway user disable alice
codex-gateway token revoke --user alice --device "HarmonyOS Phone"
codex-gateway serve --config /opt/codex-router/config.yaml
```

## 17. MVP 验收标准

- Gateway 能在 Linux 上作为 systemd 服务运行。
- 用户可以通过用户名密码登录。
- 登录成功返回 `accessToken`、`refreshToken` 和 `codexSessionName`。
- 客户端可以使用 refresh token 恢复会话。
- 服务端只返回白名单项目。
- 客户端不能提交任意文件路径。
- 用户可以创建 Codex 任务。
- 客户端可以通过 WebSocket 接收任务事件。
- 敏感操作可以生成审批请求。
- 审批通过和拒绝都写入审计日志。
- 删除连接时可以撤销对应 refresh token。
- 服务端不提供任意 shell API。
