#!/bin/bash
# deploy.sh - 一键部署到新 ECS
# 用法: ./deploy.sh <ECS_IP>

set -e

if [ -z "$1" ]; then
  echo "用法: ./deploy.sh <ECS_IP>"
  exit 1
fi

ECS_IP=$1
PROJECT_DIR="/mnt/d/DEVECO/project/codex-router-master"

echo "=== 1. 生成 TLS 证书 ==="
cd "$PROJECT_DIR"
bash scripts/generate-certs.sh

echo "=== 2. 打包项目 ==="
tar czf /tmp/codex-router.tar.gz -C "$(dirname $PROJECT_DIR)" "$(basename $PROJECT_DIR)"

echo "=== 3. 上传到 ECS ==="
scp /tmp/codex-router.tar.gz root@$ECS_IP:/opt/

echo "=== 4. 远程安装 ==="
ssh root@$ECS_IP << 'REMOTE_SCRIPT'
set -e
cd /opt

echo "--- 解压项目 ---"
tar xzf codex-router.tar.gz -C /opt/
mv codex-router-master codex-router 2>/dev/null || true
cd /opt/codex-router

echo "--- 安装 Node.js (如果没有) ---"
if ! command -v node &> /dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
node -v
npm -v

echo "--- 安装 Gateway 依赖 ---"
cd gateway && npm install && cd ..

echo "--- 安装 Agent 工具 ---"
npm install -g @openai/codex @anthropic-ai/claude-code opencode

echo "--- 验证安装 ---"
which codex claude opencode

echo "--- 安装 coturn ---"
apt-get update && apt-get install -y coturn

echo "--- 配置 coturn ---"
cat > /etc/coturn/turnserver.conf << 'TURN'
listening-port=3478
listening-ip=0.0.0.0
relay-ip=0.0.0.0
external-ip=0.0.0.0
realm=codex-router
lt-cred-mech
user=codexrouter:ChangMe123!
 TURN

echo "--- 生成 TLS 证书 ---"
cd /opt/codex-router
bash scripts/generate-certs.sh

echo "--- 配置启动脚本 ---"
sed -i "s|OPENCODE_COMMAND=.*|OPENCODE_COMMAND=opencode|" start-gateway.sh
sed -i "s|OPENCODE_WORKDIR=.*|OPENCODE_WORKDIR=/opt/codex-router|" start-gateway.sh

echo "--- 创建 systemd 服务 ---"
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

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable codex-router
systemctl start coturn
systemctl start codex-router

echo "--- 验证服务 ---"
sleep 3
curl -sk https://localhost:8443/health || curl -s http://localhost:8080/health
echo ""
echo "=== 部署完成 ==="
REMOTE_SCRIPT

echo "=== 本地更新 IP ==="
echo "请手动更新以下文件中的 IP 地址为 $ECS_IP:"
echo "  - scripts/deploy-coturn.sh"
echo "  - start-gateway.sh"
echo ""
echo "部署完成！网关地址: https://$ECS_IP:8443"
