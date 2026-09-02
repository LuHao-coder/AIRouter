#!/bin/bash
# 阿里云 coturn 一键部署脚本
# 在阿里云ECS上执行

set -e

echo "=== 安装 coturn ==="
sudo apt update && sudo apt install -y coturn

echo "=== 配置 coturn ==="
sudo tee /etc/turnserver.conf << 'EOF'
# 监听端口
listening-port=3478
tls-listening-port=5349
listening-ip=0.0.0.0

# 认证方式
fingerprint
lt-cred-mech
user=codexrouter:ChangMe123!

# 域名（替换为你的域名或IP）
realm=8.153.174.88

# 日志
log-file=/var/log/turnserver.log
simple-log

# 安全配置
no-multicast-peers
no-cli
no-tlsv1
no-tlsv1_1

# 带宽限制
total-quota=100
stale-nonce=600

# 中继IP（阿里云公网IP）
relay-ip=8.153.174.88
external-ip=8.153.174.88/8.153.174.88
EOF

echo "=== 配置防火墙 ==="
sudo ufw allow 3478/tcp
sudo ufw allow 3478/udp
sudo ufw allow 5349/tcp
sudo ufw allow 5349/udp
sudo ufw allow 49152:65535/udp

echo "=== 启动 coturn ==="
sudo systemctl enable coturn
sudo systemctl restart coturn

echo "=== 验证状态 ==="
sudo systemctl status coturn

echo ""
echo "=== 部署完成 ==="
echo "STUN/TURN 服务器地址: 8.153.174.88:3478"
echo "用户名: codexrouter"
echo "密码: ChangMe123!"
echo ""
echo "请在阿里云安全组中开放以下端口:"
echo "  - 3478/tcp, 3478/udp"
echo "  - 5349/tcp, 5349/udp"
echo "  - 49152:65535/udp"
