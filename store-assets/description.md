# AIRouter 应用描述

## 应用名称
AIRouter

## 简短描述（一句话）
远程连接并管理您的 AI 编码助手网关。

## 详细描述
AIRouter 是一款用于连接 OpenCode Gateway 的远程客户端应用。

### 主要功能
- 连接到您自己的服务器（支持 HTTPS）
- 管理多个网关连接
- 恢复和继续之前的 AI 会话
- 与 OpenCode AI 助手交互
- 支持手机、平板、二合一设备

### 使用场景
如果您在 ECS 或其他服务器上部署了 OpenCode Gateway，AIRouter 可以让您随时随地通过手机或平板与 AI 编码助手交互。

### 连接方式
1. 在服务器地址栏输入您的网关 IP 地址
2. 输入注册码完成设备激活
3. 选择 AI 代理类型
4. 开始与 AI 对话

### 技术特点
- 基于 HarmonyOS RemoteCommunicationKit
- 支持自签名证书校验
- 多设备响应式布局
- 会话历史管理

## 更新说明（v1.0.0）
- 首次发布
- 支持 OpenCode 代理
- 多设备适配
- 会话恢复功能