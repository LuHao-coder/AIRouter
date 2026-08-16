# 设备认证系统技术方案 v2

## 1. 架构概览

```
┌─────────────────────────┐              ┌──────────────────────────────────────┐
│  HarmonyOS 设备          │              │  Node.js Gateway (ECS)               │
│                          │              │                                      │
│  ┌────────────────────┐  │   HTTPS     │  ┌────────────────────────────────┐  │
│  │ HUKS 安全存储       │  │◄──────────►│  │ SQLite (devices.db)            │  │
│  │ 私钥永不导出        │  │             │  │ devices / refresh_tokens /     │  │
│  └────────────────────┘  │             │  │ activation_nonces / revoked    │  │
│                          │              │  └────────────────────────────────┘  │
│  ┌────────────────────┐  │             │                                      │
│  │ 公钥导出 PEM       │  │             │  ┌────────────────────────────────┐  │
│  │ 发送到服务器注册    │  │             │  │ 服务器签名密钥 (Ed25519)        │  │
│  └────────────────────┘  │             │  │ keys/jwt-signing.pem (600)     │  │
│                          │             │  └────────────────────────────────┘  │
└─────────────────────────┘              └──────────────────────────────────────┘
```

**核心原则：**
- 私钥永不离开客户端，服务器仅存储公钥
- 服务器使用独立的 Ed25519 密钥对签发 JWT（不依赖注册码）
- 所有逻辑判断只用 `device_id`，`device_name` 仅用于展示
- Nonce/挑战一次性有效，TTL ≤ 2 分钟
- RefreshToken 存储哈希值，设备挂失时删除该设备所有 token

---

## 2. 数据库设计

### SQLite 表结构

```sql
-- 设备公钥表
CREATE TABLE IF NOT EXISTS devices (
  device_id TEXT PRIMARY KEY,
  public_key_pem TEXT NOT NULL,
  device_name TEXT DEFAULT '',
  registered_at TEXT DEFAULT (datetime('now')),
  last_seen_at TEXT DEFAULT (datetime('now')),
  status TEXT DEFAULT 'active'  -- active | revoked
);

-- RefreshToken 存储（存哈希，不存原文）
CREATE TABLE IF NOT EXISTS refresh_tokens (
  token_hash TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  created_at TEXT DEFAULT (datetime('now')),
  expires_at TEXT NOT NULL,
  FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE
);

-- 激活挑战 nonce（一次性有效，TTL 2分钟）
CREATE TABLE IF NOT EXISTS activation_nonces (
  nonce_hash TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  activation_token TEXT NOT NULL,
  created_at TEXT DEFAULT (datetime('now')),
  expires_at TEXT NOT NULL,
  used INTEGER DEFAULT 0
);

-- 登录挑战 nonce（一次性有效，TTL 2分钟）
CREATE TABLE IF NOT EXISTS login_nonces (
  nonce_hash TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  created_at TEXT DEFAULT (datetime('now')),
  expires_at TEXT NOT NULL,
  used INTEGER DEFAULT 0
);

-- 注册码表
CREATE TABLE IF NOT EXISTS registration_codes (
  code TEXT PRIMARY KEY,
  used INTEGER DEFAULT 0,
  used_by_device TEXT DEFAULT NULL,
  used_at TEXT DEFAULT NULL
);
```

### 数据库位置

```
/opt/codex-router/codex-router-master/data/devices.db
```

### 服务器签名密钥

```
/opt/codex-router/codex-router-master/keys/jwt-signing.pem    (Ed25519 私钥)
/opt/codex-router/codex-router-master/keys/jwt-signing.pub    (Ed25519 公钥)
权限: 600 (仅 root 可读写)
```

首次部署时自动生成，后续可通过管理员脚本轮换。

---

## 3. 认证流程

### 3.1 首次注册（设备激活）

```
App                                        Server
────                                       ──────
1. 本地生成 Ed25519 密钥对
   (HUKS 安全存储，私钥不可导出)
2. 导出公钥 PEM
3. 用户输入服务器地址 + 注册码
4. POST /api/auth/register {
     deviceId, publicKey, deviceName,
     registrationCode
   }
                                          5. 验证注册码有效且未使用
                                          6. 生成 ActivationToken (UUID)
                                          7. 生成随机 challenge (128bit)
                                          8. 存储 nonce_hash + activation_token
                                             绑定 deviceId，TTL=2分钟
                                          9. 返回 { activationToken, challenge }
10. 用私钥签名 challenge
11. POST /api/auth/activate {
      deviceId,              ← 必须与 register 时一致
      activationToken,
      signedChallenge
    }
                                         12. 验证 ActivationToken:
                                             - 未过期
                                             - 未使用
                                             - 绑定的 deviceId 与请求一致
                                         13. 验证 nonce 未使用且未过期
                                         14. 用公钥验证签名
                                         15. 存储设备公钥到 devices 表
                                         16. 标记注册码为已使用
                                         17. 标记 nonce 为已使用
                                         18. 签发 JWT (15min Access + 7d Refresh)
                                         19. 返回 { accessToken, refreshToken }
20. 本地保存 RefreshToken
```

### 3.2 后续登录（签名验证）

```
App                                        Server
────                                       ──────
1. POST /api/auth/challenge {
      deviceId
    }
                                         2. 验证设备已注册且 status='active'
                                         3. 生成随机 nonce (128bit)
                                         4. 存储 nonce_hash，TTL=2分钟
                                         5. 返回 { nonce, expiresAt }
6. 用私钥签名 nonce
7. POST /api/auth/verify {
      deviceId, nonce, signature
    }
                                         8. 验证 nonce 未使用且未过期
                                         9. 标记 nonce 为已使用（一次性）
                                        10. 从 SQLite 获取该设备公钥
                                        11. 验证签名
                                        12. 更新 last_seen_at
                                        13. 签发 JWT (15min Access + 7d Refresh)
                                        14. 返回 { accessToken, refreshToken }
```

### 3.3 Token 刷新

```
App                                        Server
────                                       ──────
1. POST /api/auth/refresh {
      refreshToken
    }
                                         2. 计算 hash(refreshToken)
                                         3. 查询 refresh_tokens 表
                                         4. 验证未过期
                                         5. 签发新 AccessToken (15min)
                                         6. 返回 { accessToken }
```

### 3.4 设备重新注册

#### 场景 A：正常重置（用户主动，如卸载重装）

```
App                                        Server
────                                       ──────
1. 本地无密钥
2. 用户输入服务器地址 + 注册码
3. POST /api/auth/reregister {
      deviceId, publicKey,
      registrationCode, mode: 'reset'
    }
                                         4. 验证注册码有效
                                         5. 查找该 deviceId 的旧记录
                                         6. 替换公钥，更新 device_name
                                         7. 删除该设备所有旧 refresh_token
                                         8. 标记注册码已使用
                                         9. 签发新 JWT
                                        10. 返回 { accessToken, refreshToken }
```

#### 场景 B：疑似泄露（需管理员审批）

```
App                                        Server
────                                       ──────
1. 用户发现异常（如收到非本人操作告警）
2. POST /api/auth/reregister {
      deviceId, publicKey,
      registrationCode, mode: 'compromise'
    }
                                         3. 验证注册码有效
                                         4. 创建 reactivation_request 记录
                                            status='pending'
                                         5. 返回 { status: 'pending_approval' }
                                         6. ← 管理员在后台审批

─── 审批通过后 ───

7. App 轮询 POST /api/auth/reregister-status {
      deviceId, requestToken
    }
                                         8. 返回 { status: 'approved' }
9. App 自动执行激活流程（同首次注册）
```

---

## 4. API 端点设计

### 4.1 POST /api/auth/register

注册码验证，返回激活挑战。

**请求：**
```json
{
  "deviceId": "uuid-xxxx",
  "publicKey": "-----BEGIN PUBLIC KEY-----\n...\n-----END PUBLIC KEY-----",
  "deviceName": "HarmonyOS Phone",
  "registrationCode": "huaweI1234"
}
```

**成功响应 (200)：**
```json
{
  "activationToken": "act-uuid-xxxx",
  "challenge": "base64-random-128bit"
}
```

**错误响应：**
- 400: 注册码无效或已使用
- 409: 该设备已注册（需用 /reregister）
- 429: 速率限制

### 4.2 POST /api/auth/activate

用私钥签名激活挑战，完成注册。

**请求：**
```json
{
  "deviceId": "uuid-xxxx",
  "activationToken": "act-uuid-xxxx",
  "signedChallenge": "base64-ed25519-signature"
}
```

**成功响应 (200)：**
```json
{
  "accessToken": "eyJhbGciOiJFZERTQSJ9...",
  "refreshToken": "rt-uuid-xxxx",
  "expiresIn": 900
}
```

**错误响应：**
- 400: ActivationToken 无效/过期/已使用
- 403: deviceId 与 ActivationToken 绑定的不一致
- 403: 签名验证失败

### 4.3 POST /api/auth/challenge

获取登录签名挑战 nonce。

**请求：**
```json
{
  "deviceId": "uuid-xxxx"
}
```

**成功响应 (200)：**
```json
{
  "nonce": "base64-random-128bit",
  "expiresAt": "2026-07-25T12:30:00Z"
}
```

### 4.4 POST /api/auth/verify

用私钥签名验证登录。

**请求：**
```json
{
  "deviceId": "uuid-xxxx",
  "nonce": "base64-random-128bit",
  "signature": "base64-ed25519-signature"
}
```

**成功响应 (200)：**
```json
{
  "accessToken": "eyJhbGciOiJFZERTQSJ9...",
  "refreshToken": "rt-uuid-xxxx",
  "expiresIn": 900
}
```

### 4.5 POST /api/auth/refresh

刷新 Access Token。

**请求：**
```json
{
  "refreshToken": "rt-uuid-xxxx"
}
```

### 4.6 POST /api/auth/logout

注销（删除当前 RefreshToken）。

**请求：**
```json
{
  "refreshToken": "rt-uuid-xxxx"
}
```

### 4.7 POST /api/auth/reregister

重新注册。

**请求：**
```json
{
  "deviceId": "uuid-xxxx",
  "publicKey": "-----BEGIN PUBLIC KEY-----\n...\n-----END PUBLIC KEY-----",
  "registrationCode": "huaweI1234",
  "deviceName": "HarmonyOS Phone",
  "mode": "reset"
}
```

**mode 说明：**
- `reset`: 正常重置，直接替换公钥
- `compromise`: 疑似泄露，需要管理员审批

### 4.8 POST /api/auth/reregister-status

查询重新注册审批状态（仅 compromise 模式）。

**请求：**
```json
{
  "deviceId": "uuid-xxxx",
  "requestToken": "req-uuid-xxxx"
}
```

---

## 5. JWT 设计

### 服务器签名密钥

- 算法: Ed25519
- 存储: `/opt/codex-router/codex-router-master/keys/jwt-signing.pem`
- 权限: 600
- 轮换: 管理员运行 `node scripts/rotate-signing-key.mjs`
- 轮换后旧 token 在过期前仍有效（验证时尝试当前 + 上一个密钥）

### AccessToken

```
Header:  { "alg": "EdDSA", "typ": "JWT" }
Payload: {
  "sub": "device-uuid",
  "iat": 1690000000,
  "exp": 1690000900,
  "jti": "unique-token-id",
  "type": "access"
}
```

- 签名算法: EdDSA (Ed25519)
- 有效期: 15 分钟

### RefreshToken

```
格式: rt-{uuid}
存储: hash(token) in refresh_tokens 表
有效期: 7 天
设备挂失: DELETE FROM refresh_tokens WHERE device_id = ?
```

---

## 6. 心跳与设备状态

### last_seen_at 更新策略

| 事件 | 更新 last_seen_at |
|------|-------------------|
| POST /api/auth/verify 成功 | ✅ 更新 |
| POST /api/auth/activate 成功 | ✅ 更新 |
| POST /api/auth/refresh 成功 | ✅ 更新 |
| 任意 API 请求（带 AccessToken） | ✅ 更新 |

### 僵尸设备识别

```sql
-- 超过 30 天未活跃的设备
SELECT device_id, device_name, last_seen_at
FROM devices
WHERE last_seen_at < datetime('now', '-30 days')
  AND status = 'active';
```

管理员可通过后台 API 或脚本查看僵尸设备列表。

### 设备状态显示

```
后台管理页格式: {device_name} ({device_id 前8位})
示例: "HarmonyOS Phone (a1b2c3d4)"
```

---

## 7. 速率限制

### 实现方式：内存滑动窗口计数器

```javascript
class RateLimiter {
  constructor(windowMs, maxRequests) {
    this.windowMs = windowMs;
    this.maxRequests = maxRequests;
    this.clients = new Map();
  }

  check(key) {
    const now = Date.now();
    const record = this.clients.get(key);
    if (!record || now > record.resetAt) {
      this.clients.set(key, { count: 1, resetAt: now + this.windowMs });
      return true;
    }
    if (record.count >= this.maxRequests) return false;
    record.count++;
    return true;
  }
}
```

### 限制规则

| 端点 | 限制 | 窗口 | 限制维度 |
|------|------|------|----------|
| /api/auth/register | 5 次 | 15 分钟 | IP |
| /api/auth/activate | 3 次 | 5 分钟 | activation_token |
| /api/auth/challenge | 10 次 | 15 分钟 | device_id |
| /api/auth/verify | 5 次 | 15 分钟 | device_id |
| /api/auth/refresh | 10 次 | 15 分钟 | device_id |
| /api/auth/reregister | 3 次 | 1 小时 | IP |

---

## 8. 安全注意事项

### 私钥存储

- **HarmonyOS**: 使用 HUKS (`@kit.UniversalKeystoreKit`) 存储私钥
  - 私钥存储在安全硬件中，应用无法直接读取
  - 仅能通过 HUKS API 使用，不可导出
- **降级方案**: 若 HUKS 不可用，使用 Preferences + 文件权限 `0600`
- **永不传输**: 私钥永远不会出现在网络请求中

### 公钥格式

- 统一使用 PEM 格式 (SPKI/X.509)
- Ed25519 密钥对
- 签名算法: EdDSA (Ed25519)

### 注册码安全

- 注册码仅在首次注册和重新注册时使用
- 使用后立即标记 `used=1`
- 每个注册码只能激活一个设备

### device_name 安全

- `device_name` 仅用于展示，所有逻辑判断只用 `device_id`
- 后台管理页显示格式: `{device_name} ({device_id 前8位})`
- 不校验唯一性，允许多设备同名

---

## 9. 文件结构

```
gateway/
├── server.mjs              # 主网关（修改认证逻辑）
├── auth.mjs                # 新增：认证模块
├── db.mjs                  # 新增：SQLite 数据库
├── rate-limiter.mjs        # 新增：速率限制
├── keys/
│   ├── jwt-signing.pem     # Ed25519 私钥 (600)
│   └── jwt-signing.pub     # Ed25519 公钥 (600)
└── data/
    └── devices.db          # SQLite 数据库

entry/src/main/ets/
├── api/GatewayClient.ets   # 修改：新增注册/激活/挑战/验证请求
├── model/
│   ├── DeviceKeyManager.ets # 新增：Ed25519 密钥对管理
│   ├── DeviceIdManager.ets  # 修改：复用已有的 deviceId
│   └── AuthManager.ets      # 新增：认证状态管理
```

---

## 10. 实现阶段

### 阶段一：基础认证

1. 生成服务器签名密钥对 (`scripts/generate-signing-key.mjs`)
2. `db.mjs` - SQLite 初始化 + 表结构
3. `auth.mjs` - 注册码验证 + ActivationToken + 签名验证 + nonce 管理
4. `rate-limiter.mjs` - 速率限制
5. `server.mjs` - 新增认证端点，移除旧密钥认证
6. `DeviceKeyManager.ets` - Ed25519 密钥对生成 + HUKS 存储
7. `GatewayClient.ets` - 新增注册/激活/挑战/验证请求方法
8. `ConnectionHome.ets` - 更新登录流程

### 阶段二：会话安全

9. JWT 签发/验证（Ed25519）
10. RefreshToken 存储（哈希） + 吊销
11. Token 刷新端点
12. 设备心跳更新

### 阶段三：加固

13. 重新注册流程（reset + compromise）
14. 设备管理 API（管理员查看/删除设备）
15. 僵尸设备检测
16. 签名密钥轮换脚本
