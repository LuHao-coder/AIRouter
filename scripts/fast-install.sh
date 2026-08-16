#!/bin/bash
# AIRouter 快速安装脚本 - 使用 GitHub 代理
set -e

PROXY="https://gh-proxy.com"

echo "=== 1. npm 淘宝镜像 ==="
npm config set registry https://registry.npmmirror.com

echo "=== 2. 安装 OpenCode ==="
curl -fsSL https://opencode.ai/install | bash

echo "=== 3. 安装 Claude Code ==="
curl -fsSL https://claude.ai/install.sh | bash

echo "=== 4. 安装 Codex ==="
npm install -g @openai/codex

echo "=== 5. 验证 ==="
echo "opencode: $(which opencode 2>/dev/null || echo '未安装')"
echo "claude: $(which claude 2>/dev/null || echo '未安装')"
echo "codex: $(which codex 2>/dev/null || echo '未安装')"
