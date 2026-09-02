#!/bin/bash
# 部署新 TLS 证书到 ECS（IP: 8.153.174.88），更新网关与 coturn 配置后重启
# 用法: ./scripts/apply-new-ip.sh <ECS_IP>  （默认 8.153.174.88）
set -euo pipefail

ECS_IP="${1:-8.153.174.88}"
CRT="cert/codex-router-cert.pem"
KEY="cert/codex-router-key.pem"

if [ ! -f "$CRT" ] || [ ! -f "$KEY" ]; then
  echo "错误：找不到证书/私钥，先运行 generate-certs.sh 生成 (cert/ 目录)。" >&2
  exit 1
fi

echo ">> 上传新证书到 $ECS_IP:/opt/codex-router/certs/"
scp "$CRT" "$KEY" "root@$ECS_IP:/opt/codex-router/certs/"

echo ">> 更新 systemd 服务中 COTURN_HOST 并重启网关"
ssh "root@$ECS_IP" "bash -s" <<EOF
set -euo pipefail
sed -i 's|COTURN_HOST=[0-9.]*|COTURN_HOST=$ECS_IP|g' /etc/systemd/system/codex-router.service
systemctl daemon-reload
systemctl restart codex-router
sleep 2
systemctl status codex-router --no-pager | head -12
echo "---- health check ----"
curl -ks https://127.0.0.1:8443/health
EOF

echo ">> 完成。如 coturn 的真实 IP 未变，请按需更新 /etc/turnserver.conf 的 external-ip/realm。"
