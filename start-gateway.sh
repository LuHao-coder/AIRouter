#!/bin/bash

# AIRouter Gateway 启动脚本
# ECS 部署时修改为 ECS 上的实际路径

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# OpenCode 配置
export OPENCODE_COMMAND=/root/.opencode/bin/opencode
export OPENCODE_SERVER_URL=http://127.0.0.1:4096
export OPENCODE_WORKDIR=/root

# Gateway 配置
export GATEWAY_HOST=0.0.0.0
export GATEWAY_PORT=8443
export GATEWAY_HTTP_PORT=8080
export GATEWAY_TLS_KEY=/opt/codex-router/certs/key.pem
export GATEWAY_TLS_CERT=/opt/codex-router/certs/cert.pem

# 设备认证密钥（Ed25519 签名密钥）
export AI_ROUTER_SIGNING_KEY_PATH=/opt/codex-router/codex-router-master/keys/jwt-signing.pem
export AI_ROUTER_SIGNING_PUB_PATH=/opt/codex-router/codex-router-master/keys/jwt-signing.pub

# 数据库
export AI_ROUTER_DB_PATH=/opt/codex-router/codex-router-master/data/devices.db

# Coturn/TURN 配置
export COTURN_HOST=8.153.175.142
export COTURN_PORT=3478
export COTURN_USER=codexrouter
export COTURN_PASS=ChangMe123!

# 启动网关
cd "$SCRIPT_DIR"
node gateway/server.mjs
