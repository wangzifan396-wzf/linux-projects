# systemd --user unit 文件

这个目录收录家用 Linux 自托管栈的 systemd --user 服务 unit 文件（目前 4 个服务：1 个 oneshot + 1 个 timer + 3 个 simple 长驻；Tailscale 的 `tailscaled` 是系统服务，不在此列）。

## 服务清单

| unit 文件 | 类型 | 作用 | 依赖 |
| --- | --- | --- | --- |
| `wireproxy-warp.service` | simple 长驻 | wireproxy 把 Cloudflare WARP 跑成用户态 SOCKS5 代理（127.0.0.1:1080） | `~/Files/proxy/wireproxy` + `wireproxy.conf` |
| `gitea.service` | simple 长驻 | Gitea 自托管 Git 服务（**0.0.0.0:3000**，SQLite 后端，绑全网卡以便 Tailscale / 局域网访问） | `~/Files/gitea/gitea` + `app.ini` |
| `cloudflared.service` | simple 长驻 | cloudflared quick tunnel 反代本地 Hugo server（127.0.0.1:1313 → 公网 HTTPS，仅博客预览，不暴露 Gitea） | `~/.local/bin/cloudflared` + hugo server 在跑 |
| `health-check.service` | oneshot | 跑 `~/Files/scripts/health-check.sh`，检查上面 3 个服务 + 外网连通性；可选 Telegram / Webhook 告警 | `~/Files/scripts/health-check.sh` + 可选 `~/.config/health-check.env` |
| `health-check.timer` | timer | 每 5 分钟触发 `health-check.service` | `health-check.service` |

## 健康检查告警通知（可选）

`health-check.sh` 内置 Telegram / Webhook 通知钩子，由环境变量激活，`health-check.service` 已通过 `EnvironmentFile=-%h/.config/health-check.env` 接入。

```bash
# 1. 复制模板
cp systemd/health-check.env.example ~/.config/health-check.env
# 2. 编辑填入真实值
vim ~/.config/health-check.env
#    TG_BOT_TOKEN=...   TG_CHAT_ID=...   （可选 TG_PROXY=socks5://127.0.0.1:1080）
#    或 NOTIFY_WEBHOOK=https://hooks.example.com/xxx
# 3. 重新加载让 EnvironmentFile 生效
systemctl --user daemon-reload
systemctl --user restart health-check
```

未设置任何通知变量时，脚本静默只写日志，绝不误报。详见 [轻量健康检查](../content/posts/health-check/)。

## 部署

不要直接复制到 `~/.config/systemd/user/` ——unit 文件里硬编码了 `/home/wzf/` 路径（我本机的用户名）。

用仓库根目录的 `install.sh`，它会自动把 `/home/wzf/` 替换成当前 `$HOME`：

```bash
./install.sh             # 全部部署
./install.sh --dry-run   # 先看会做什么，不实际执行
```

install.sh 做的事：
1. `scripts/*.sh` → `~/Files/scripts/`（保留可执行权限）
2. `systemd/*.service|timer` → `~/.config/systemd/user/`（sed 替换 `/home/wzf/` → `$HOME`）
3. `systemctl --user daemon-reload`
4. 逐个 `enable` + `start`（不存在的服务跳过，不影响其他）
5. 检查 `loginctl show-user $USER -p Linger`，如果不是 `yes` 会提示 `sudo loginctl enable-linger $USER`

## enable-linger 是关键

systemd --user 服务默认只在用户登录时跑。要让用户不登录也能跑（reboot 后自动起来），需要：

```bash
sudo loginctl enable-linger $USER
```

只跑一次。跑过后所有 enabled 的 user 服务开机自启。详见 [systemd --user 工作流](../content/posts/systemd-user-workflow/)。

## 常用命令

```bash
# 查看所有 user 服务运行状态
systemctl --user list-units --type=service --state=running

# 查看某个服务详情（日志、PID、退出码）
systemctl --user status wireproxy-warp

# 实时日志
journalctl --user -u wireproxy-warp -f

# 重启某个服务
systemctl --user restart gitea

# 改了 unit 文件后
systemctl --user daemon-reload
systemctl --user restart xxx

# 健康检查日志
tail -f ~/Files/monitor/health.log
```

## 设计要点

- 全部用 `Type=simple` 长驻或 `oneshot` 跑完即退，不用 `forking`（systemd 推荐简单类型）
- `Restart=on-failure` + `StartLimitBurst=5` + `StartLimitIntervalSec=60`：崩溃自动拉起，但单分钟内最多 5 次避免死循环
- `StandardOutput=journal` + `StandardError=journal`：日志走 journald，用 `journalctl --user -u xxx` 查
- `WantedBy=default.target`：enable 后开机自启
- 依赖 `network-online.target`：等网络就绪再起，避免 wireproxy/cloudflared 启动时没网导致首次失败
- `health-check.service` 用 `EnvironmentFile=-%h/.config/health-check.env` 注入告警变量，`-` 前缀保证文件缺失也不影响健康检查本身

## 相关博文

- [systemd --user 工作流：家用 Linux 不给 sudo 也能让服务开机自启](../content/posts/systemd-user-workflow/)
- [轻量健康检查：bash + systemd timer 监控家用 Linux 自托管服务](../content/posts/health-check/)
- [用 Tailscale 把家机变成随身可访问的私密网](../content/posts/tailscale-private-mesh/)
- [家用 Linux 自托管栈全景：18 篇文章串起的零成本体系](../content/posts/self-hosted-stack-overview/)
