#!/bin/bash
# 生成自签名 TLS 证书（开发用途）

KEY_PATH=/tmp/codex-router-gateway-key.pem
CERT_PATH=/tmp/codex-router-gateway-cert.pem
RAWFILE_DIR=$(dirname "$0")/../entry/src/main/resources/rawfile

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$KEY_PATH" \
  -out "$CERT_PATH" \
  -days 365 \
  -subj "/CN=codex-router" \
  -addext "subjectAltName=IP:127.0.0.1,IP:8.153.175.142"

# 复制证书到 rawfile 目录（用于鸿蒙应用证书固定）
if [ -d "$RAWFILE_DIR" ]; then
  cp "$CERT_PATH" "$RAWFILE_DIR/codex-router-cert.pem"
  echo "证书已复制到 rawfile 目录"
fi

echo "证书已生成:"
echo "  私钥: $KEY_PATH"
echo "  证书: $CERT_PATH"
