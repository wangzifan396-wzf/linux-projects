---
title: "systemd --user 工作流：家用 Linux 不给 sudo 也能让服务开机自启"
date: 2026-08-25T13:40:00+08:00
draft: false
tags: ["systemd", "Linux", "自托管", "服务管理"]
categories: ["运维"]
summary: "家用 Linux 主机上不轻易给 sudo，但 wireproxy、Gitea、cloudflared 都需要开机自启 + 崩溃重启。用 systemd --user 管理，配合 enable-linger 让用户不登录也能跑服务，记录 unit 文件写法、常用命令、调试技巧，以及 cloudflared 用 nohup 跑的反面教材。"
---

家用 Linux 主机上跑着一堆自托管服务：wireproxy（WARP 代理）、Gitea（私有 Git）、cloudflared（公网隧道）、Hugo server（本机预览）。这些都要满足两个要求：**开机自启** + **崩溃自动重启**。但家用主机不轻易给 sudo——家人共用、怕误改系统。`systemd --user` 正好解决这个矛盾。

## 一、方案对比

| 方案 | 需要 sudo | 开机自启 | 崩溃重启 | 日志 | 适合 |
| --- | --- | --- | --- | --- | --- |
| **systemd --user** | ❌ | ✅（配合 linger） | ✅ | journalctl --user | 家用、个人服务 |
| 系统级 systemd | ✅ | ✅ | ✅ | journalctl | 系统服务、多用户共用 |
| nohup / disown | ❌ | ❌（重启就没了） | ❌ | 手动重定向 | 临时跑、一次性 |
| supervisor / runit | ✅ | ✅ | ✅ | 自己管 | 不想用 systemd 的场景 |
| docker compose | ✅（docker 守护） | ✅ | ✅ | docker logs | 容器化部署 |

systemd --user 的好处：**所有操作在用户目录完成**，unit 文件在 `~/.config/systemd/user/`，二进制在 `~/Files/`，日志走 `journalctl --user`，零系统配置修改，卸载干净（删 unit 文件 + disable 即可）。

## 二、关键概念：user lingering

systemd --user 服务默认**只在用户登录时跑**——因为 user session 在登录时才启动。这有个坑：

> reboot 后如果用户没登录，所有 systemd --user 服务都不会启动。

家用主机虽然通常自动登录，但万一没自动登录，wireproxy 和 Gitea 就不会自启。解决：**启用 lingering**，让 user session 在不登录时也跑。

```bash
# 需要 sudo 执行一次（之后无需再管）
sudo loginctl enable-linger $USER

# 验证
loginctl show-user $USER | grep Linger
# 期望：Linger=yes
```

启用 linger 后，reboot 时 user session 会自动启动（不需要登录），所有 `systemctl --user enable` 的服务都会自启。这是一次性操作，之后所有 user services 都享受这个待遇。

## 三、unit 文件结构

位置：`~/.config/systemd/user/<name>.service`

```ini
[Unit]
Description=服务描述
After=network-online.target nss-lookup.target   # 等网络就绪
Wants=network-online.target

[Service]
Type=simple
ExecStart=/path/to/binary args   # 启动命令（用绝对路径）
WorkingDirectory=/path/to/workdir
Restart=on-failure                # 崩溃自动重启
RestartSec=5                      # 重启间隔 5 秒
StartLimitIntervalSec=60          # 60 秒内
StartLimitBurst=5                 # 最多重试 5 次，避免死循环
StandardOutput=journal            # 日志走 journald --user
StandardError=journal

[Install]
WantedBy=default.target           # enable 时挂到 default.target
```

关键点：
- `ExecStart` 用**绝对路径**（systemd 不走 PATH）
- `Restart=on-failure` + `StartLimitBurst` 防止崩溃死循环重启
- `After=network-online.target` 确保网络就绪再启动（代理/Web 服务必需）
- 日志走 journal，用 `journalctl --user -u <name>` 查看

## 四、实战 unit

### 4.1 wireproxy（WARP 代理）

`~/.config/systemd/user/wireproxy-warp.service`：

```ini
[Unit]
Description=wireproxy (userspace WireGuard→Cloudflare WARP) local SOCKS5+HTTP proxy
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/home/wzf/Files/proxy/wireproxy -c /home/wzf/Files/proxy/wireproxy.conf
WorkingDirectory=/home/wzf/Files/proxy
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
```

启用：

```bash
systemctl --user daemon-reload
systemctl --user enable --now wireproxy-warp.service
systemctl --user status wireproxy-warp.service --no-pager
```

### 4.2 Gitea（私有 Git）

`~/.config/systemd/user/gitea.service`：

```ini
[Unit]
Description=Gitea self-hosted git server (userspace, SQLite, port 3000)
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/home/wzf/Files/gitea/gitea web --config /home/wzf/Files/gitea/custom/conf/app.ini
WorkingDirectory=/home/wzf/Files/gitea
Environment=GITEA_WORK_DIR=/home/wzf/Files/gitea
Environment=GITEA_CUSTOM=/home/wzf/Files/gitea/custom
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
```

Gitea 需要两个环境变量 `GITEA_WORK_DIR` 和 `GITEA_CUSTOM` 指向工作目录，用 `Environment=` 注入。

## 五、常用命令速查

```bash
# 改了 unit 文件后必须 reload
systemctl --user daemon-reload

# 启用 + 立即启动 + 开机自启
systemctl --user enable --now <name>.service

# 单独操作
systemctl --user start <name>
systemctl --user stop <name>
systemctl --user restart <name>
systemctl --user disable <name>

# 查状态
systemctl --user status <name> --no-pager
systemctl --user is-active <name>
systemctl --user is-enabled <name>

# 看日志（实时跟踪）
journalctl --user -u <name> -f
# 看最近 100 行
journalctl --user -u <name> -n 100 --no-pager
# 看今天的
journalctl --user -u <name> --since today

# 列出所有 user services
systemctl --user list-unit-files --type=service
systemctl --user list-units --type=service --state=running
```

## 六、调试技巧

### 6.1 unit 文件语法检查

```bash
systemd-analyze verify ~/.config/systemd/user/<name>.service
```

会报错告诉你哪里写错了（路径不存在、字段名拼错等）。

### 6.2 服务启动失败排查

```bash
# 看详细状态（含最近日志）
systemctl --user status <name> --no-pager -l

# 看 journal 完整日志
journalctl --user -u <name> --no-pager
```

常见失败原因：
- `ExecStart` 路径错（用相对路径或路径不存在）
- 二进制没有执行权限（`chmod +x`）
- 端口被占（`ss -tlnp | grep <port>`）
- 配置文件路径错

### 6.3 Restart 策略

```ini
Restart=on-failure   # 退出码非 0 才重启（推荐）
Restart=always       # 不管什么原因退出都重启（包括正常退出）
Restart=on-abnormal  # 信号异常才重启
```

配合 `StartLimitBurst` 防死循环：如果 60 秒内重启 5 次都失败，systemd 会放弃重启（避免反复崩溃拖垮系统）。

## 七、反面教材：cloudflared 用 nohup 跑的坑

cloudflared 之前是用 `nohup` 跑的：

```bash
nohup cloudflared tunnel --url http://localhost:1313 >cloudflared.log 2>&1 &
disown
```

三个坑：

1. **reboot 后不自启**：nohup 进程在 user session 里，session 结束（登出/重启）进程也没了。每次重启都得手动启动。
2. **崩溃不重启**：cloudflared 偶尔会挂（网络抖动、内存泄漏），nohup 不会自动拉起来。
3. **日志管理乱**：手动重定向到文件，没有 journal 的索引和过滤能力。

正确做法：写 systemd --user unit。

`~/.config/systemd/user/cloudflared.service`：

```ini
[Unit]
Description=cloudflared quick tunnel (reverse proxy to local Hugo server on 127.0.0.1:1313)
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/home/wzf/.local/bin/cloudflared tunnel --url http://localhost:1313
WorkingDirectory=/home/wzf
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
```

从 nohup 切换到 systemd：

```bash
# 1. 杀掉 nohup 跑的 cloudflared（避免两个进程冲突）
pkill -f "cloudflared tunnel"

# 2. reload + enable + start
systemctl --user daemon-reload
systemctl --user enable --now cloudflared.service

# 3. 从 journal 拿新的 quick tunnel URL（每次重启都会变）
journalctl --user -u cloudflared --no-pager | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1
```

> 注意：cloudflared quick tunnel 的 URL **每次重启都变**，这是 quick tunnel 的固有限制（不用域名）。systemd 只能保证它崩溃重启 + reboot 自启，没法固定 URL。想要固定 URL 得用 named tunnel + 自己的域名。本博客的生产固定 URL 走 GitHub Pages，cloudflared 只作本机实时预览，URL 变可接受。

## 八、整体架构

{{< mermaid >}}
graph TD
    A[开机 / reboot] --> B{user linger 启用?}
    B -->|是| C[user session 自动启动]
    B -->|否| D[等用户登录才启动]
    C --> E[systemd --user 触发 default.target]
    D --> E
    E --> F[wireproxy-warp.service 启动]
    E --> G[gitea.service 启动]
    E --> H[cloudflared.service 启动]
    F --> I[SOCKS5 代理 127.0.0.1:1080]
    G --> J[Gitea Web 127.0.0.1:3000]
    H --> K[cloudflared tunnel 反代 1313]
    K --> L[本机 Hugo server]
    L --> M[公网实时预览 URL]
{{< /mermaid >}}

## 九、现状

本机当前状态（所有服务都已 systemd --user 化 + linger 已启用）：

| 服务 | 管理方式 | 状态 |
| --- | --- | --- |
| wireproxy-warp | systemd --user | enabled + active ✓ |
| gitea | systemd --user | enabled + active ✓ |
| cloudflared | systemd --user | enabled + active ✓（已从 nohup 切换）|
| user linger | 已启用 | `Linger=yes`，reboot 后不登录也跑 ✓ |

reboot 后三个服务都会自启，崩溃会自动重启（`Restart=on-failure` + `StartLimitBurst=5`）。从 nohup 切到 systemd 的命令见第七节。

## 十、设计取舍

1. **systemd --user 而非系统级**：所有改动在用户目录，零系统配置修改，卸载干净，符合"不给 sudo"的家用约束。
2. **enable-linger 是一次性 sudo**：只在启用时需要一次 sudo，之后所有 user services 都享受 reboot 自启，性价比极高。
3. **cloudflared 仍走 quick tunnel**：不引入域名，URL 变是已知代价；生产固定 URL 走 GitHub Pages，cloudflared 只作本机实时预览。
4. **日志走 journal**：不手动重定向文件，`journalctl --user` 有索引、过滤、跟随，比 nohup 重定向强得多。

> 这篇博文里提到的三个服务（wireproxy、Gitea、cloudflared）都跑在写这篇博文的那台家用 Linux 主机上——systemd --user 是它们能稳定跑的根基。
