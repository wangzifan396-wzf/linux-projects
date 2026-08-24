---
title: "在 Linux 上自托管 Gitea：零域名零备案零端口的私有 Git 服务"
date: 2026-08-25T02:15:00+08:00
tags: ["gitea", "self-host", "cloudflare-tunnel", "linux"]
categories: ["self-host"]
description: "用 Gitea v1.27.2 + SQLite + Cloudflare Tunnel 在一台家用 Linux 主机上搭起私有 Git 服务，不用域名、不用备案、不开外网端口"
math: false
---

> 目标：不花一分钱、不用域名、不用备案、不在路由器开任何端口，就能从公网访问自己机器上的 Git 服务。这要么是魔法，要么是 Cloudflare Tunnel。两者其实是同一个东西。

> 本机环境：Ubuntu 24.04 + GNOME + Wayland，x86_64，家庭宽带（无公网 IP）。

---

## 0. 为什么选 Gitea 而不是 GitLab / Gogs

| 维度 | Gitea | GitLab | Gogs |
| --- | --- | --- | --- |
| 资源占用 | 单二进制，~100 MB 内存 | 重，2 GB+ 内存，需 PostgreSQL/Redis | 单二进制，更轻 |
| 功能完整度 | 仓库、Issue、PR、Wiki、CI/CD（Gitea Actions）、OAuth | 全套 DevOps | 基础仓库管理 |
| 维护活跃度 | 高，月度 release | 商业主导 | 基本停更 |
| 二进制大小 | ~120 MB | 不可单二进制部署 | ~50 MB |

一句话：**Gitea 是"轻量但功能齐全"的最佳平衡点**。

---

## 1. 前置条件

- Linux 主机，已装 `curl`、`tar`、`git`、`python3`（用来改 ini）
- 一个能访问 dl.gitea.com 或 GitHub releases 的网络（国内可能要镜像）
- 已有 Cloudflare Tunnel 二进制（参见本博客 [Hugo 博客栈升级]({{< relref "/posts/blog-stack-upgrade" >}})）

---

## 2. 下载 Gitea 二进制

```bash
mkdir -p ~/Files/gitea/{custom,data,log}
cd ~/Files/gitea

# 直连 dl.gitea.com（国内偶尔慢，可改 ghproxy 镜像）
curl -L --progress-bar -o gitea https://dl.gitea.com/gitea/1.27.2/gitea-1.27.2-linux-amd64
chmod +x gitea

# 验证
./gitea --version
# 期望：gitea version 1.27.2 built with go1.26.5...
```

国内网络太慢时可换镜像：

```bash
curl -L -o gitea https://ghproxy.net/https://github.com/go-gitea/gitea/releases/download/v1.27.2/gitea-1.27.2-linux-amd64
```

---

## 3. 写 `app.ini`（一次到位，避免网页安装页）

`custom/conf/app.ini` 是 Gitea 主配置。很多人第一次跑 Gitea 会进网页安装页填表，但其实完全可以预先写好跳过：

```ini
APP_NAME = Gitea: Git with a cup of tea
RUN_MODE = prod

[database]
DB_TYPE  = sqlite3
PATH     = /home/wzf/Files/gitea/data/gitea.db

[repository]
ROOT = /home/wzf/Files/gitea/data/repo

[server]
DOMAIN = localhost        ; cloudflared tunnel 起来后改成 trycloudflare 域名
HTTP_PORT = 3000
ROOT_URL = http://localhost:3000/
DISABLE_SSH = true         ; 本机没装 openssh-server，关掉内置 SSH（默认 2441 端口）
LFS_START_SERVER = false
OFFLINE_MODE = true        ; 不去拉外部 CDN（国内访问 GitHub raw 不稳）
PROTOCOL = http

[security]
INSTALL_LOCK = true       ; 跳过网页安装页，用 CLI 建管理员

[service]
DISABLE_REGISTRATION = false  ; 第一次允许注册；建完管理员后改 true 锁注册

[log]
MODE = console
LEVEL = Info
ROOT_PATH = /home/wzf/Files/gitea/log

[other]
SHOW_FOOTER_VERSION = false
```

> 关键设计点：
> - `INSTALL_LOCK = true`：跳过网页安装页（默认安装页是给非技术用户填 db 设置的，我们 app.ini 都写好了没必要再走一遍）
> - `DISABLE_SSH = true`：本机没 openssh-server，关掉 Gitea 内置 SSH（避免起 2441 端口却连不上）
> - `OFFLINE_MODE = true`：Gitea 默认会去 `cdn.jsdelivr.net` / GitHub raw 拉一些前端资源，国内访问不稳，关掉它改用本地内嵌资源

---

## 4. 用 systemd --user 守护（不需 sudo）

Gitea 是单二进制，直接 `./gitea web` 就能跑，但重启就死。用 systemd --user 让它开机自启、崩溃自动重启：

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

[Install]
WantedBy=default.target
```

启用并启动：

```bash
systemctl --user daemon-reload
systemctl --user enable --now gitea.service

# 验证
systemctl --user status gitea.service --no-pager | head -12
curl -sS -o /dev/null -w "Gitea: HTTP=%{http_code} time=%{time_total}s\n" http://localhost:3000/
# 期望：Gitea: HTTP=200 time=0.01s
```

---

## 5. 用 CLI 建管理员（不走网页安装页）

```bash
cd ~/Files/gitea
GITEA_WORK_DIR=/home/wzf/Files/gitea ./gitea admin user create \
  --username wzf \
  --password '你的密码' \
  --email wzf@localhost \
  --admin \
  --config /home/wzf/Files/gitea/custom/conf/app.ini \
  --work-path /home/wzf/Files/gitea
# 期望：New user 'wzf' has been successfully created!
```

> 提示：
> - 邮箱用 `wzf@localhost` 即可，本机没装邮件服务，只在 UI 显示用
> - `--admin` 标志让该用户直接是管理员；不加的话第一个注册的用户自动是管理员

---

## 6. 用 Cloudflare Tunnel 暴露公网

家庭宽带通常没公网 IP，没法在路由器上做端口转发。但 Cloudflare Tunnel 让你**主动出站连接**到 Cloudflare 边缘节点，相当于一条反向隧道——**不需要任何公网入站端口**：

```bash
# 后台起 quick tunnel（URL 每次重启都会变，详见第 7 节）
nohup /home/wzf/.local/bin/cloudflared tunnel --url http://localhost:3000 \
  >~/Files/gitea/log/cloudflared-gitea.log 2>&1 &
disown

# 几秒后从日志抓 URL
grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' \
  ~/Files/gitea/log/cloudflared-gitea.log | head -1
# 期望：https://neighbor-nightlife-guide-lit.trycloudflare.com
```

拿到 URL 后改 `app.ini` 的 `DOMAIN` 和 `ROOT_URL` 为该 URL，重启 Gitea：

```bash
# 改 app.ini 中 DOMAIN 和 ROOT_URL 两个字段
systemctl --user restart gitea.service
```

公网验证：

```bash
curl -sS -o /dev/null -w "Gitea 公网: HTTP=%{http_code} time=%{time_total}s\n" \
  https://neighbor-nightlife-guide-lit.trycloudflare.com/
# 期望：HTTP=200
```

---

## 7. trycloudflare quick tunnel 的坑：URL 每次都变

quick tunnel 是 Cloudflare 给的免费体验模式，**每次重启 cloudflared 都会换一个随机子域名**。这意味着：

1. 重启 cloudflared → 新 URL
2. 必须更新 Gitea `app.ini` 的 `DOMAIN` / `ROOT_URL`
3. 重启 Gitea

否则别人访问旧 URL 会 404，且 Gitea 内部生成的链接（邮件、OAuth 回调）会指向错误的域名。

我写了个脚本自动完成这一串：`~/Files/gitea/refresh-gitea-tunnel.sh`（脚本会用 cloudflared 的 `--metrics` 端口 20242 区分"Gitea 的 tunnel" vs "博客的 tunnel"，不会误杀）。

> 想要**稳定 URL** 的方案：注册 Cloudflare 账号，把自己一个域名托管到 Cloudflare DNS，用 `cloudflared tunnel create <name>` 起命名 tunnel，绑定到 `git.你的域名.com`。这样 URL 永不变。代价是要一个域名（一年几十块）。

---

## 8. 用 API 建第一个仓库

不打开浏览器，直接用 API 建仓：

```bash
curl -sS -u wzf:你的密码 -X POST http://localhost:3000/api/v1/user/repos \
  -H "Content-Type: application/json" \
  -d '{
    "name": "hello-gitea",
    "description": "First repo on self-hosted Gitea via API",
    "private": false,
    "auto_init": true,
    "gitignores": "Go",
    "license": "MIT",
    "readme": "Default"
  }' -w "\nHTTP=%{http_code}\n"
# 期望：HTTP=201
```

通过公网域名拿仓库信息（验证 ROOT_URL 已生效）：

```bash
curl -sS -u wzf:你的密码 \
  https://你的-tunnel-url.trycloudflare.com/api/v1/repos/wzf/hello-gitea \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('html_url:',d['html_url'])"
# 期望：html_url: https://你的-tunnel-url.trycloudflare.com/wzf/hello-gitea
```

如果 `html_url` 里的域名是 `localhost`，说明 `ROOT_URL` 没改对，公网访问会跳到死链。

---

## 9. 日常运维速查

| 场景 | 命令 |
| --- | --- |
| 看状态 | `systemctl --user status gitea.service` |
| 重启 | `systemctl --user restart gitea.service` |
| 看日志 | `journalctl --user -u gitea.service -f` |
| 改完 app.ini 生效 | `systemctl --user restart gitea.service` |
| 公网 tunnel 死了/URL 变了 | `~/Files/gitea/refresh-gitea-tunnel.sh` |
| 建管理员 | `cd ~/Files/gitea && GITEA_WORK_DIR=$PWD ./gitea admin user create --username xxx ...` |
| 列出所有用户 | `./gitea admin user list --config custom/conf/app.ini` |
| 备份 | `tar czf gitea-backup-$(date +%F).tar.gz custom data` |
| 升级 | 下新版二进制覆盖 `gitea`，`systemctl --user restart gitea.service` |

---

## 10. 安全注意

1. `DISABLE_REGISTRATION = false` 让你能注册第一个管理员；建完管理员后改成 `true` 重启，避免公网被人乱注册
2. 公网暴露意味着任何人都能访问你的 Gitea 首页。即便如此，未登录只能看公开仓库（私有仓库要登录）
3. **不要把 `wzf@localhost` 邮箱的密码用于其他地方**。Gitea 是自托管，密码 hash 在 `data/gitea.db`，被入侵就泄露
4. trycloudflare 域名公开后，扫描器可能尝试登录。建议改 `DISABLE_REGISTRATION = true`，把 admin 密码设成长密码
5. 定期 `tar czf` 备份整个 `data/` 目录（含 SQLite db + 仓库）

---

## 11. 一图看清架构

{{< mermaid >}}
graph LR
  A[Internet 用户] --> B[Cloudflare 边缘]
  B -.->|trycloudflare.com 公网域名| C
  C[本机 cloudflared<br/>主动出站 QUIC] --> D[localhost:3000]
  D --> E[Gitea systemd --user 服务]
  E --> F[(SQLite<br/>data/gitea.db)]
  E --> G[仓库数据<br/>data/repo]
{{< /mermaid >}}

整套链路没有任何一个公网入站端口：本机防火墙不开 3000，路由器不开端口转发，全靠 cloudflared 一条**主动出站**的 QUIC 隧道把内网服务暴露到 Cloudflare 边缘。

---

## 12. 完整一页速查

```bash
# 1. 下载
mkdir -p ~/Files/gitea/{custom,data,log} && cd ~/Files/gitea
curl -L -o gitea https://dl.gitea.com/gitea/1.27.2/gitea-1.27.2-linux-amd64
chmod +x gitea

# 2. 写 custom/conf/app.ini（见第 3 节）

# 3. 写 systemd user unit（见第 4 节）
systemctl --user daemon-reload && systemctl --user enable --now gitea.service

# 4. 建管理员
GITEA_WORK_DIR=$PWD ./gitea admin user create --username wzf --password 你的密码 \
  --email wzf@localhost --admin --config custom/conf/app.ini

# 5. 起 cloudflared 公网隧道
nohup /home/wzf/.local/bin/cloudflared tunnel --url http://localhost:3000 \
  >log/cloudflared-gitea.log 2>&1 &
URL=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' log/cloudflared-gitea.log | head -1)
echo "Gitea 公网: $URL/"

# 6. 改 app.ini 的 DOMAIN / ROOT_URL 为 $URL，重启 Gitea
systemctl --user restart gitea.service

# 7. 验证
curl -sS -o /dev/null -w "HTTP=%{http_code}\n" "$URL/"
```

---

## 附：本机当前配置快照

| 项 | 值 |
| --- | --- |
| Gitea 版本 | v1.27.2 (go1.26.5) |
| 二进制路径 | `/home/wzf/Files/gitea/gitea` |
| 数据目录 | `/home/wzf/Files/gitea/data/` |
| 数据库 | SQLite @ `data/gitea.db` |
| 监听端口 | `0.0.0.0:3000` |
| systemd unit | `~/.config/systemd/user/gitea.service`（enabled） |
| 公网 URL | https://neighbor-nightlife-guide-lit.trycloudflare.com/ |
| tunnel 二进制 | `/home/wzf/.local/bin/cloudflared` v2026.8.2 |
| 管理员 | `wzf`（admin） |
| refresh 脚本 | `~/Files/gitea/refresh-gitea-tunnel.sh` |
