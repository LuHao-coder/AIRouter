#!/bin/bash
# 一键修复 Gateway 服务
set -e

echo "=== 1. 停止服务 ==="
systemctl stop codex-router 2>/dev/null || true

echo "=== 2. 杀掉残留 opencode 进程 ==="
pkill -f "opencode serve" 2>/dev/null || true
sleep 1

echo "=== 3. 复制 TLS 证书到稳定路径 ==="
mkdir -p /opt/codex-router/certs
cp /opt/codex-router/certs/key.pem /tmp/codex-router-gateway-key.pem 2>/dev/null || true
cp /opt/codex-router/certs/cert.pem /tmp/codex-router-gateway-cert.pem 2>/dev/null || true

echo "=== 4. 更新 service 文件 ==="
cat > /etc/systemd/system/codex-router.service << 'EOF'
[Unit]
Description=AIRouter Gateway
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/codex-router/codex-router-master
ExecStart=/usr/bin/node gateway/server.mjs
KillMode=control-group
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
Environment=COTURN_PASS=ChangMe123!
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "=== 5. 重载并启动 ==="
systemctl daemon-reload
systemctl start codex-router
sleep 5

echo "=== 6. 验证状态 ==="
systemctl status codex-router --no-pager -l

echo ""
echo "=== 7. 健康检查 ==="
curl -k https://localhost:8443/health

echo ""
echo "=== 8. opencode 进程 ==="
ps aux | grep opencode | grep -v grep

echo ""
echo "=== 完成 ==="
