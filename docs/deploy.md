# OpenCode Gateway 部署指南

## 系统要求

- 操作系统：Ubuntu 22.04+ / Debian 12+
- 内存：1GB+
- 磁盘：10GB+
- 网络：公网 IP，开放 8443（HTTPS）和 8080（HTTP）端口

## 一、安装 Node.js 22

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
node -v  # 确认版本 >= 22
```

## 二、安装 coturn（ TURN 服务器）

```bash
sudo apt-get install -y coturn
```

编辑 `/etc/turnserver.conf`：

```bash
sudo nano /etc/turnserver.conf
```

添加以下配置：

```
listening-port=3478
fingerprint
lt-cred-mech
user=codexrouter:ChangMe123!
realm=codex-router
total-quota=100
stale-nonce=600
no-multicast-peers
no-cli
```

启用 coturn 服务：

```bash
sudo systemctl enable coturn
sudo systemctl start coturn
```

## 三、部署网关服务

### 1. 克隆项目

```bash
mkdir -p /opt/codex-router
cd /opt/codex-router
git clone https://github.com/LuHao-coder/AIRouter.git codex-router-master
# 或从本地上传：scp -r codex-router-master root@<服务器IP>:/opt/codex-router/
cd codex-router-master/gateway
npm install
```

### 2. 生成 TLS 证书

```bash
mkdir -p certs
openssl req -x509 -newkey rsa:2048 -keyout certs/key.pem -out certs/cert.pem -days 365 -nodes -subj "/CN=localhost"
```

如需正式证书，可使用 Let's Encrypt：

```bash
sudo apt-get install -y certbot
sudo certbot certonly --standalone -d your-domain.com
sudo cp /etc/letsencrypt/live/your-domain.com/fullchain.pem certs/cert.pem
sudo cp /etc/letsencrypt/live/your-domain.com/privkey.pem certs/key.pem
```

### 3. 生成 Ed25519 签名密钥

```bash
mkdir -p keys
node scripts/generate-signing-key.mjs
```

输出 `keys/jwt-signing.pem`（私钥）和 `keys/jwt-signing.pub`（公钥）。

### 4. 初始化数据库

数据库在网关首次启动时自动创建（`data/devices.db`），无需手动初始化。首次启动后生成一个注册码：

```bash
cd /opt/codex-router/codex-router-master
node -e "
const Database = require('better-sqlite3');
const db = new Database('./data/devices.db');
const crypto = require('crypto');
const code = crypto.randomBytes(8).toString('hex');
db.prepare('INSERT INTO registration_codes (code) VALUES (?)').run(code);
console.log('新注册码:', code);
"
```

### 5. 配置环境变量

创建 `.env` 文件（供 systemd `EnvironmentFile` 使用）：

```bash
cat > .env << 'EOF'
OPENCODE_COMMAND=opencode
OPENCODE_SERVER_URL=http://127.0.0.1:4096
OPENCODE_WORKDIR=/root
GATEWAY_HOST=0.0.0.0
GATEWAY_PORT=8443
GATEWAY_HTTP_PORT=8080
GATEWAY_TLS_KEY=/opt/codex-router/certs/key.pem
GATEWAY_TLS_CERT=/opt/codex-router/certs/cert.pem
AI_ROUTER_SIGNING_KEY_PATH=/opt/codex-router/codex-router-master/keys/jwt-signing.pem
AI_ROUTER_SIGNING_PUB_PATH=/opt/codex-router/codex-router-master/keys/jwt-signing.pub
AI_ROUTER_DB_PATH=/opt/codex-router/codex-router-master/data/devices.db
COTURN_HOST=8.153.175.142
COTURN_PORT=3478
COTURN_USER=codexrouter
COTURN_PASS=ChangMe123!
EOF
```

> 注：当前 ECS 使用 coturn 部署在网关同一台机器上，`COTURN_HOST` 需为公网可达的 IP（`8.153.175.142`），否则手机无法建立 TURN 连接。

### 6. 启动服务

```bash
node gateway/server.mjs
```

测试访问：

```bash
curl -k https://localhost:8443/health
```

## 四、配置 systemd 服务（开机自启）

创建服务文件：

```bash
sudo nano /etc/systemd/system/codex-router.service
```

内容：

```ini
[Unit]
Description=OpenCode Router Gateway
After=network.target coturn.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/codex-router/codex-router-master
ExecStart=/usr/bin/node gateway/server.mjs
Restart=always
RestartSec=5
KillMode=control-group
EnvironmentFile=/opt/codex-router/codex-router-master/.env

[Install]
WantedBy=multi-user.target
```

启用并启动：

```bash
sudo systemctl daemon-reload
sudo systemctl enable codex-router
sudo systemctl start codex-router
sudo systemctl status codex-router
```

## 五、查看注册码

```bash
cd /opt/codex-router/codex-router-master
node -e "
const Database = require('better-sqlite3');
const db = new Database('./data/devices.db');
const codes = db.prepare('SELECT code, used FROM registration_codes').all();
console.log('注册码列表：');
codes.forEach(c => console.log(c.code, c.used ? '(已使用)' : '(未使用)'));
"
```

## 六、App 配置

用户安装 App 后，输入：

- 服务器地址：`https://你的公网IP:8443`
- 注册码：向你获取

## 七、安全建议

1. **修改默认注册码**
   在数据库中删除默认注册码，生成新的：
   ```bash
   cd /opt/codex-router/codex-router-master
   node -e "
   const crypto = require('crypto');
   const code = crypto.randomBytes(8).toString('hex');
   const Database = require('better-sqlite3');
   const db = new Database('./data/devices.db');
   db.prepare('INSERT INTO registration_codes (code) VALUES (?)').run(code);
   console.log('新注册码:', code);
   "
   ```

2. **配置防火墙**
   ```bash
   sudo ufw allow 22/tcp
   sudo ufw allow 8443/tcp
   sudo ufw allow 8080/tcp
   sudo ufw allow 3478/tcp
   sudo ufw enable
   ```

3. **定期更新系统**
   ```bash
   sudo apt update && sudo apt upgrade -y
   ```

4. **监控日志**
   ```bash
   sudo journalctl -u codex-router -f
   ```

## 八、常见问题

### 服务无法启动
- 检查端口是否被占用：`sudo lsof -i:8443`
- 查看日志：`sudo journalctl -u codex-router -n 50`

### App 无法连接
- 确认防火墙已开放 8443 端口
- 确认服务器地址格式正确：`https://IP:8443`
- 确认证书有效：`curl -k https://IP:8443/health`

### coturn 无法连接
- 确认 3478 端口已开放
- 检查 coturn 状态：`sudo systemctl status coturn`
