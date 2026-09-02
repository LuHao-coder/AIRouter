#!/bin/bash
# AIRouter 完整部署脚本 - ECS (8.153.174.88)
set -e

echo "=== 1. 系统更新 ==="
apt-get update && apt-get upgrade -y

echo "=== 2. 安装 Node.js 22 ==="
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

echo "=== 3. 安装基础工具 ==="
apt-get install -y git curl wget coturn openssl

echo "=== 4. 加速配置 ==="
# npm 使用淘宝镜像
npm config set registry https://registry.npmmirror.com

echo "=== 5. 安装 AI 编码工具 ==="
# OpenCode
npm install -g opencode-ai

# Claude Code
npm install -g @anthropic-ai/claude-code

# Codex
npm install -g @openai/codex

echo "=== 6. 验证安装 ==="
echo "Node: $(node -v)"
echo "npm: $(npm -v)"
echo "opencode: $(which opencode)"
echo "claude: $(which claude)"
echo "codex: $(which codex)"

echo "=== 7. 配置 coturn ==="
PUBLIC_IP=$(curl -s ifconfig.me)
cat > /etc/coturn/turnserver.conf << TURNCONF
listening-port=3478
tls-listening-port=5349
listening-ip=0.0.0.0
relay-ip=0.0.0.0
external-ip=$PUBLIC_IP
realm=codex-router
lt-cred-mech
user=codexrouter:ChangMe123!
log-file=/var/log/turnserver.log
simple-log
TURNCONF

systemctl enable coturn
systemctl restart coturn

echo "=== 8. 生成 TLS 证书 ==="
mkdir -p /opt/codex-router/certs
openssl req -x509 -newkey rsa:2048 -keyout /opt/codex-router/certs/key.pem \
  -out /opt/codex-router/certs/cert.pem -days 365 -nodes \
  -subj "/CN=codex-router" \
  -addext "subjectAltName=IP:$PUBLIC_IP"

echo "=== 9. 部署网关 ==="
mkdir -p /opt/codex-router
cd /opt/codex-router

cat > start-gateway.sh << 'GATEWAYSTART'
#!/bin/bash
export OPENCODE_COMMAND="opencode"
export OPENCODE_WORKDIR="/opt/codex-router"
export OPENCODE_SERVER_URL="http://127.0.0.1:4096"
export GATEWAY_HOST="0.0.0.0"
export GATEWAY_PORT=8443
export GATEWAY_HTTP_PORT=8080
export GATEWAY_TLS_KEY="/opt/codex-router/certs/key.pem"
export GATEWAY_TLS_CERT="/opt/codex-router/certs/cert.pem"
export AI_ROUTER_SIGNING_KEY_PATH="/opt/codex-router/codex-router-master/keys/jwt-signing.pem"
export AI_ROUTER_SIGNING_PUB_PATH="/opt/codex-router/codex-router-master/keys/jwt-signing.pub"
export AI_ROUTER_DB_PATH="/opt/codex-router/codex-router-master/data/devices.db"
export COTURN_HOST="8.153.174.88"
export COTURN_PORT=3478
export COTURN_USER="codexrouter"
export COTURN_PASS="ChangMe123!"
cd /opt/codex-router/codex-router-master/gateway
node server.mjs
GATEWAYSTART
chmod +x start-gateway.sh

echo "=== 10. 创建 systemd 服务 ==="
cat > /etc/systemd/system/codex-router.service << 'SERVICE'
[Unit]
Description=AIRouter Gateway
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/codex-router
ExecStart=/bin/bash /opt/codex-router/start-gateway.sh
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload

echo ""
echo "========================================="
echo "  基础环境部署完成！"
echo "  公网 IP: $PUBLIC_IP"
echo "========================================="
echo ""
echo "下一步："
echo "1. 将项目代码上传到 /opt/codex-router/codex-router-master/"
echo "2. 运行: systemctl start codex-router"
echo "3. 测试: curl -k https://$PUBLIC_IP:8443/health"
