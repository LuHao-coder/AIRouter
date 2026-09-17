# AIRouter ECS 换 IP 服务器侧操作手册（8.153.174.88）

> 前提：在本地项目根目录 `/mnt/d/DEVECO/project/codex-router-master` 执行第 1 步上传。
> 之后均在 ECS 上执行（先 ssh 登录上去）。
>
> ⚠️ **重要（固定地址 + 证书固定）**：App 内置了固定服务器地址与证书
> （`entry/src/main/ets/model/AppConfig.ets` 和 `entry/src/main/resources/rawfile/codex-router-cert.pem`）。
> **更换服务器 IP / 证书后，必须同步更新这两处，并重新构建、上架 App**，否则已安装的 App 将连接失败。

---

## 第 1 步：上传新证书（本地执行）

替换旧的 `8.153.175.142` 证书，上传新证书到服务器网关目录：

```bash
scp cert/codex-router-cert.pem cert/codex-router-key.pem root@8.153.174.88:/opt/codex-router/certs/
```

> 系统会提示输入 root 密码。

---

## 第 2 步：登录服务器

```bash
ssh root@8.153.174.88
```

---

## 第 3 步：更新 COTURN_HOST 并重启网关

```bash
sed -i 's|COTURN_HOST=.*|COTURN_HOST=8.153.174.88|g' /etc/systemd/system/codex-router.service
systemctl daemon-reload
systemctl restart codex-router
sleep 2
systemctl status codex-router --no-pager | head -12
```

验证健康检查（期望返回 `{"status":"ok",...}`）：

```bash
curl -ks https://127.0.0.1:8443/health
```

---

## 第 4 步：检查 coturn 配置（若网关用了 TURN）

查看当前 coturn 配置里的 IP：

```bash
grep -nE "external-ip|relay-ip|^realm|listening-ip" /etc/turnserver.conf 2>/dev/null
```

如果里面还是旧 IP `8.153.175.142`，需要改成新 IP：

```bash
sed -i 's|8.153.175.142|8.153.174.88|g' /etc/turnserver.conf
systemctl restart coturn
systemctl status coturn --no-pager | head -8
```

> 如果 grep 没有任何输出，说明 coturn 可能不在 `/etc/turnserver.conf`，用下面命令找配置文件：
> ```bash
> find /etc -name "turnserver.conf" 2>/dev/null
> systemctl status coturn --no-pager | head -5
> ```

验证 TURN/STUN 端口：

```bash
ss -lntp | grep -E "3478|5349"
curl -s http://8.153.174.88:8080/health
```

---

## 第 5 步：验证公网可达（ECS 上执行）

```bash
curl -ks https://8.153.174.88:8443/health
curl -s  http://8.153.174.88:8080/health
```

两个都应返回 `{"status":"ok","sessionName":"opencode-main"}`。

---

## 收尾检查清单

- [ ] `scp` 上传成功（cert.pem / key.pem 在 `/opt/codex-router/certs/`）
- [ ] `systemctl status codex-router` 显示 active (running)
- [ ] `curl -ks https://8.153.174.88:8443/health` 返回 ok
- [ ] `/etc/turnserver.conf` 的 IP 已更新（如需）
- [ ] `coturn` 已重启且端口 3478/5349 在监听

> 本地 App 用**已重新构建的 signed HAP**（内置证书已含 8.153.174.88）连接新 IP。
> 服务器侧完成后，把第 3、5 步输出贴给我确认。
