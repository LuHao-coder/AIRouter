# Gateway 使用说明

AIRouter 的 Gateway 是一个 Node.js HTTPS 服务，为 HarmonyOS App 提供：

- 设备注册/激活认证（注册码 + Ed25519 签名）
- OpenCode 会话列表、恢复、消息转发
- TURN/STUN ICE 配置下发

## 启动

```bash
cd /path/to/codex-router-master
node scripts/generate-signing-key.mjs   # 首次生成设备认证签名密钥（keys/）

# 生成 TLS 证书（SAN 包含服务器 IP）
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /tmp/airouter-gateway-key.pem \
  -out /tmp/airouter-gateway-cert.pem \
  -days 365 -subj "/CN=codex-router" \
  -addext "subjectAltName=IP:127.0.0.1,IP:<服务器IP>"

OPENCODE_COMMAND=/usr/local/bin/opencode \
OPENCODE_SERVER_URL=http://127.0.0.1:4096 \
OPENCODE_WORKDIR=/root \
GATEWAY_HOST=0.0.0.0 \
GATEWAY_PORT=8443 \
GATEWAY_HTTP_PORT=8080 \
GATEWAY_TLS_KEY=/tmp/airouter-gateway-key.pem \
GATEWAY_TLS_CERT=/tmp/airouter-gateway-cert.pem \
AI_ROUTER_SIGNING_KEY_PATH=./keys/jwt-signing.pem \
AI_ROUTER_SIGNING_PUB_PATH=./keys/jwt-signing.pub \
AI_ROUTER_DB_PATH=./data/devices.db \
node gateway/server.mjs
```

默认地址 `https://0.0.0.0:8443`。完整环境变量见 [../README.md](../README.md)。

## 设备认证流程

不使用账号密码。新设备流程：

1. 管理员在数据库中生成一次性注册码（见 [docs/deploy.md](../docs/deploy.md)）。
2. App 调用 `POST /api/auth/register` 携带注册码与设备 Ed25519 公钥。
3. Gateway 返回 `activationToken` 与 `challenge`，App 用 HUKS 私钥签名后调用 `POST /api/auth/activate`。
4. 激活成功返回 `accessToken`/`refreshToken`，之后请求携带 `authorization: Bearer <accessToken>`。

注册码仅限本设备注册一次；重新注册使用 `POST /api/auth/reregister`。

## 常用接口

```text
GET    /health
POST   /api/auth/register
POST   /api/auth/activate
POST   /api/auth/challenge
POST   /api/auth/verify
POST   /api/auth/refresh
POST   /api/auth/logout
POST   /api/auth/reregister
GET    /api/auth/me
GET    /api/turn/ice-config
GET    /api/projects
GET    /api/opencode/resumes
POST   /api/opencode/resumes
POST   /api/opencode/resumes/{id}/resume
POST   /api/opencode/resumes/{id}/archive
POST   /api/opencode/resumes/{id}/name
DELETE /api/opencode/resumes/{id}
POST   /api/opencode/resumes/{id}/messages
POST   /api/projects/{name}/tasks
GET    /api/tasks/{id}
```

查看真实 OpenCode 会话：

```bash
TOKEN=$(curl -ks https://127.0.0.1:8443/api/auth/me -o /dev/null; echo) # 示意
curl -ks https://127.0.0.1:8443/api/opencode/resumes \
  -H "authorization: Bearer $TOKEN"
```

（获取 `$TOKEN` 的完整注册/激活调用需先完成上面的设备认证流程。）

## 测试

```bash
cd gateway && node --test server.test.mjs opencode-server.test.mjs
```

## 手机访问（WSL 场景）

Windows 下用 `netsh interface portproxy` 把 WSL 端口暴露到局域网：

```powershell
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=8443 connectaddress=<WSL-IP> connectport=8443
New-NetFirewallRule -DisplayName "AIRouter Gateway 8443" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8443
```

App 中填写 `https://<服务器IP>:8443`。注意 App 使用固定证书校验，请确保服务器使用与
`entry/src/main/resources/rawfile/codex-router-cert.pem` 一致的证书。
