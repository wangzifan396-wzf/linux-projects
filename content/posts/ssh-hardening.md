---
title: "家用 Linux SSH 安全加固 7 步：从 22 端口裸奔到 fail2ban 自动封禁"
date: 2026-08-26T04:30:00+08:00
draft: false
tags: ["SSH", "安全", "fail2ban", "sshd_config", "Linux", "运维"]
categories: ["运维"]
summary: "查本机现状：openssh-server 装了、22 端口监听 0.0.0.0、fail2ban 没装——这是家用 Ubuntu 默认状况。这篇做 SSH 加固 7 步实战：ed25519 密钥+密码短语、sshd_config.d/hardening.conf 关键项、fail2ban 自动封禁爆破 IP、ufw 白名单、authorized_keys 限制、audit 日志、mermaid 握手图，附 sshd -t 语法检查和踩坑记录。所有配置以 snippet 形式在 scripts/ssh-hardening/ 下可抄走即用。"
---

跑这条命令看看你家 Linux 主机的 SSH 现状：

```bash
$ systemctl status ssh | head -3
● ssh.service - OpenBSD Secure Shell server
     Loaded: loaded (/usr/lib/systemd/system/ssh.service; enabled; preset: enabled)
     Active: active (running) since Sun 2026-08-23 15:15:00 HKT; 2 days ago

$ ss -tlnp | grep :22
LISTEN 0  4096  0.0.0.0:22  0.0.0.0:*
LISTEN 0  4096  [::]:22     [::]:*

$ which fail2ban-client
（空）

$ ls /etc/ssh/sshd_config.d/
（空）
```

这台家用 Ubuntu 24.04 的真实状况：**openssh-server 装着、2 天前开机就自动启动、22 端口监听所有 IPv4+IPv6 接口、fail2ban 没装、sshd_config.d 一片空白**。

很多人以为自己只是"家用桌面不对外开 SSH"，但其实：
1. 桌面版 Ubuntu 装 openssh-server 后默认就开机自启
2. 家用宽带虽然没有公网 IP，但只要同 Wi-Fi 的任何设备被植入恶意软件，22 端口立刻是内网可达的攻击面
3. 如果你之前用 [Cloudflare Tunnel](/posts/cloudflare-tunnel-guide/) 暴露过服务，又顺手把 SSH 也走隧道——那等于 SSH 直接对公网开放

这篇做 SSH 加固 7 步实战，配置 snippet 都放在 [scripts/ssh-hardening/](https://github.com/wangzifan396-wzf/linux-projects/tree/main/scripts/ssh-hardening) 下，可抄走即用。

## 一、先看风险面：22 端口默认开着会怎样

SSH 服务暴露面 = 攻击者能尝试的所有路径：

| 路径 | 风险 | 默认是否开 |
| --- | --- | --- |
| 22 端口扫描爆破（小字典 / 几万次/分钟脚本） | 中（家用无公网时仅内网可达，但 IoT/恶意设备风险） | ✅ 开 |
| 密码弱口令登录 | 高（家用人通常用同一个密码） | ✅ 开（`PasswordAuthentication yes`） |
| root 直接登录 | 高（root 是高价值目标） | ⚠️ Ubuntu 默认 `PermitRootLogin prohibit-password`，但仍然允许 root 用密钥登 |
| known_hosts 钓鱼（你 ssh 进别人机器被记录密钥指纹） | 低 | - |
| 中间人攻击首次连接（TOFU 信任 host key） | 低 | ✅ 默认接受 |

家用场景下，**最值得担心的是前两条**：密码爆破和弱口令。即使没公网 IP，同 Wi-Fi 内的恶意设备或被劫持的 IoT 设备都能尝试 22 端口。

## 二、SSH 一次连接的握手 + 加固点

{{< mermaid >}}
flowchart LR
    C[客户端 ssh user@host] -->|"1. TCP 22 连接<br/>（加固3: ufw 白名单 + 加固2: 改 Port）"| S[sshd 监听]
    S -->|"2. 协议版本协商"| C
    S -->|"3. 服务器 host key<br/>（TOFU 第一次问用户信任）"| C
    C -->|"4. 客户端公钥认证<br/>（加固1: ed25519+密码短语）"| S
    S -->|"5. 查 authorized_keys<br/>（加固6: from= 限制 + command=）"| A[(~/.ssh/authorized_keys]
    S -->|"6. 查 AllowUsers / MaxAuthTries<br/>（加固3: sshd_config.d/hardening.conf）"| P[(/etc/ssh/sshd_config.d/)]
    S -->|"7. 登录成功 / 失败日志"| J[(journalctl -u ssh)]
    J -->|"8. 连续失败 N 次<br/>（加固4: fail2ban 自动封禁）"| F[(fail2ban iptables DROP)]
    F -.->|DROP| C

    style S fill:#e3f2fd,stroke:#1565c0
    style A fill:#fff3e0,stroke:#e65100
    style P fill:#fff3e0,stroke:#e65100
    style F fill:#ffebee,stroke:#c62828
    style J fill:#e8f5e9,stroke:#2e7d32
{{< /mermaid >}}

7 个加固点都标在图上了。下面逐项实战。

## 三、加固 1：ed25519 密钥 + 密码短语（替代密码登录）

SSH 公钥认证的核心理念：**私钥永远不离开你的客户端**。服务器只存公钥，登录时客户端用私钥签一个挑战，服务器用公钥验签。攻击者就算全程监听也拿不走私钥。

ed25519 是 2015 年 OpenSSL 推出的现代曲线算法，比老牌 RSA 更短（68 字符 vs 2048 字符的 RSA 公钥）、更快、抗侧信道攻击。

```bash
# 生成 ed25519 私钥，强制加密码短语（如果之前生成时没加密，用 ssh-keygen -p -f ~/.ssh/id_ed25519 补）
ssh-keygen -t ed25519 -a 100 -C "wzf@home" -f ~/.ssh/id_ed25519
# -a 100 = KDF 迭代 100 轮，提高私钥加密强度（默认 16）
# 提示 Enter passphrase: 务必填一个≠账户密码的独立密码短语
```

如果嫌每次输密码短语烦，配 ssh-agent + `AddKeysToAgent`：

```bash
# ~/.ssh/config 顶部加：
Host *
    AddKeysToAgent yes
    IdentitiesOnly yes
# 然后 ssh-add ~/.ssh/id_ed25519 输入一次密码短语
# 之后桌面会话内 ssh-agent 自动缓存，重启就要再输一次
```

把公钥推到服务器：
```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@host
# 等价于手动追加到 ~/.ssh/authorized_keys
```

确认能用密钥登进去了**再**禁用密码登录（加固 3）。

## 四、加固 2：改 Port 22 → 非常规端口

改端口**不是真正的安全**（nmap 一扫就见），但能挡掉 99% 的自动化扫描脚本——那些脚本就是无脑扫 22。

Ubuntu 24.04 的 sshd 读 `/etc/ssh/sshd_config.d/*.conf`，所以新增一个文件比改主配置干净：

```bash
# /etc/ssh/sshd_config.d/hardening.conf
Port 2222                     # 改非常规端口，同步要改 ufw allow 2222
AddressFamily inet            # 只监听 IPv4，家用没 IPv6 必要
ListenAddress 0.0.0.0         # 只绑特定接口的话写 192.168.1.10
```

改完先 `sshd -t` 语法检查，再 `systemctl reload ssh` 重载（不是 restart，不会断当前会话）。**务必先 `ufw allow 2222/tcp` 再 reload**，不然锁死自己进不去。

## 五、加固 3：sshd_config.d/hardening.conf 关键项

这是核心，完整可抄的配置片段在 [scripts/ssh-hardening/sshd_config.d/hardening.conf](https://github.com/wangzifan396-wzf/linux-projects/blob/main/scripts/ssh-hardening/sshd_config.d/hardening.conf)。挑关键项讲：

```ini
# /etc/ssh/sshd_config.d/hardening.conf

# --- 认证类 ---
PermitRootLogin no              # 完全禁止 root 登录（Ubuntu 默认是 prohibit-password 还允许 root 用密钥）
PasswordAuthentication no      # 禁止密码登录，只允许公钥（前提：你的公钥已能登）
KbdInteractiveAuthentication no # 禁止键盘交互（PAM 提问），PasswordAuthentication 的兄弟
PubkeyAuthentication yes        # 允许公钥认证（默认就是 yes，写明以便排查）
PermitEmptyPasswords no         # 不允许空密码账户登录

# --- 限制类 ---
AllowUsers wzf                  # 只允许 wzf 用户登录（多个用空格分隔：wzf admin@192.168.1.0/24）
MaxAuthTries 3                  # 单次连接最多 3 次认证失败就断（默认 6，太多给爆破留机会）
MaxSessions 4                   # 单连接最多 4 个 session（防资源占用）
LoginGraceTime 30               # 30 秒没认证成功就断（默认 120，太久）
MaxStartups 10:30:60            # 并发未认证连接数限制（10 时开始 30% 丢，60 时全丢）

# --- 网络类 ---
ClientAliveInterval 300         # 5 分钟无活动发心跳包
ClientAliveCountMax 2            # 2 次心跳无响应就断（共 10 分钟）
AllowTcpForwarding no           # 禁止 SSH 端口转发（家用通常用不到；如果你用 -L 调试，临时改 yes）
X11Forwarding no                # 禁止 X11 转发（家用桌面 SSH 时偶尔用，权衡关闭）
AllowAgentForwarding no         # 禁止 ssh-agent 转发（防被劫持用你的私钥）
PermitTunnel no                 # 禁止 tun 设备转发
```

**AllowUsers 的写法很灵活**：`wzf admin@192.168.1.0/24` = wzf 任意来源 + admin 只来自 192.168.1.0/24 网段。

## 六、加固 4：fail2ban 自动封禁爆破 IP

sshd_config 限制了"同一连接 3 次失败"，但攻击者可以不断换连接尝试。fail2ban 监控 ssh 日志，**对同一 IP 在 10 分钟内失败 5 次，直接 iptables DROP 1 小时**。

```bash
sudo apt install fail2ban
# Ubuntu 24.04 自带 systemd journal 后端，fail2ban 默认读 journal
```

fail2ban 的正确做法是**不要改 /etc/fail2ban/jail.conf**（升级会被覆盖），而是新建 `/etc/fail2ban/jail.local` 覆盖：

```ini
# /etc/fail2ban/jail.local  （scripts/ssh-hardening/fail2ban/jail.local 抄）
[DEFAULT]
backend = systemd             # Ubuntu 24.04 默认已 systemd 后端，显式声明
bantime = 3600                 # 封禁 1 小时（可写 -1 永久，但太狠）
findtime = 600                 # 10 分钟内
maxretry = 5                   # 5 次失败触发
banaction = ufw               # 用 ufw 而不是 iptables 多协议封禁

[sshd]
enabled = true
port = 2222                    # 改了端口这里也要改！默认是 ssh=22
maxretry = 3                   # sshd 的失败比其他敏感，3 次封
bantime = 86400                # sshd 失败封 1 天
```

启动 + 自启：
```bash
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd      # 看 sshd jail 状态
sudo fail2ban-client status sshd     # 看当前封了多少 IP
```

跑一阵后用 `fail2ban-client status sshd` 就能看到被封的 IP 列表，爆破 IP 一目了然。

## 七、加固 5：ufw 防火墙白名单

即使有 fail2ban 也建议加一层 ufw 白名单：

```bash
# 默认拒绝入站，允许出站
sudo ufw default deny incoming
sudo ufw default allow outgoing

# 允许 SSH（如果改了端口就改这里）
sudo ufw allow 2222/tcp
# 如果 Cloudflare Tunnel 还在跑，cloudflared 出站不需要入站
# 如果你开了内网 SMB、Hugo dev server 等，按需 allow：
# sudo ufw allow from 192.168.1.0/24 to any port 1313   # Hugo dev 只给内网

# 启用
sudo ufw enable
sudo ufw status verbose
```

**关键点**：`ufw allow 22/tcp` vs `ufw allow from 192.168.1.0/24 to any port 22`。前者对全开，后者只对内网。家用几乎没必要对公网开 SSH——需要远程时走 [Cloudflare Tunnel](/posts/cloudflare-tunnel-guide/) 暴露具体服务（Hugo、Gitea）而不是 22 端口。

## 八、加固 6：authorized_keys 限制选项

公钥也能加额外约束，在 `~/.ssh/authorized_keys` 每行最前面加 option：

```bash
# ~/.ssh/authorized_keys
from="192.168.1.0/24",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... wzf@home
```

意思：这把公钥**只能从 192.168.1.0/24 来源登录、不能端口转发、不能 X11 转发、不能 agent 转发、不能开 pty（只能跑 `ssh user@host <command>` 模式）**。

家用场景中，你日常登录的那把钥匙可以保留 pty，但给 CI / cron / 自动化脚本生成的"只跑特定命令"的钥匙，**强烈建议加 command= 限制**：

```bash
# 给 backup 自动化用的只读备份钥匙
command="/home/wzf/Files/scripts/backup.sh",from="192.168.1.5",no-pty,no-port-forwarding ssh-ed25519 AAAA... backup@cron
```

这把钥匙无论客户端 ssh 后输入什么命令，**服务器永远只跑 backup.sh**。即使私钥泄露，攻击者也只能触发备份，不能 `rm -rf` 你。

## 九、加固 7：审计日志

加固完要看效果：

```bash
# 1. 看最近的 SSH 登录尝试（成功的、失败的都在 journal）
journalctl -u ssh --since "1 hour ago" | grep -E 'Accepted|Failed|invalid'

# 2. 看当前有哪些人成功登过
last -f /var/log/wtmp | head -20

# 3. 看失败登录的 top IP（确认 fail2ban 工作）
journalctl -u ssh --since today | grep -oE 'from [0-9.]+' | sort | uniq -c | sort -rn | head

# 4. fail2ban 当前封禁列表
sudo fail2ban-client status sshd

# 5. 测试当前 sshd 配置（不重启）会不会有问题
sudo sshd -t   # 输出空 = OK；输出 error = 有问题，别 reload
```

把第 3 条加进 [health-check.sh](/posts/health-check/) 也很合理——"最近 1 小时失败登录次数 > 50" 算一个异常信号。

## 十、一键应用：apply.sh

把所有片段写成一个 dry-run 优先的部署脚本，放仓库 [scripts/ssh-hardening/apply.sh](https://github.com/wangzifan396-wzf/linux-projects/blob/main/scripts/ssh-hardening/apply.sh)。**默认 --dry-run**，要看 diff 才真正改：

```bash
cd ~/Files/blog/scripts/ssh-hardening
./apply.sh --dry-run          # 看：会把 hardening.conf 复制到哪、fail2ban jail.local 有没有差异
./apply.sh                    # 真改：复制配置 + sshd -t 检查 + reload ssh + enable fail2ban + ufw allow 2222
```

脚本核心逻辑：

```bash
#!/bin/bash
set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

SSHD_SRC="$(dirname "$0")/sshd_config.d/hardening.conf"
SSHD_DST="/etc/ssh/sshd_config.d/hardening.conf"
FAIL2BAN_SRC="$(dirname "$0")/fail2ban/jail.local"
FAIL2BAN_DST="/etc/fail2ban/jail.local"
NEW_PORT=2222

echo "[1/5] 检查 openssh-server 是否安装"
dpkg -l openssh-server | grep -q '^ii' || { echo "ERROR: 先装 openssh-server"; exit 1; }

echo "[2/5] 部署 sshd_config.d/hardening.conf"
if $DRY_RUN; then
    diff -u "$SSHD_DST" "$SSHD_SRC" 2>/dev/null || true
    echo "(dry-run) 会复制到 $SSHD_DST"
else
    sudo install -m 644 "$SSHD_SRC" "$SSHD_DST"
    sudo sshd -t   # 关键：语法检查，fail 立刻退
    sudo systemctl reload ssh
fi

echo "[3/5] 部署 fail2ban jail.local"
if $DRY_RUN; then
    echo "(dry-run) 会复制到 $FAIL2BAN_DST"
else
    if ! dpkg -l fail2ban | grep -q '^ii'; then
        sudo apt install -y fail2ban
    fi
    sudo install -m 644 "$FAIL2BAN_SRC" "$FAIL2BAN_DST"
    sudo systemctl enable --now fail2ban
    sudo systemctl restart fail2ban
fi

echo "[4/5] ufw 放行新端口"
if $DRY_RUN; then
    echo "(dry-run) 会执行: ufw allow $NEW_PORT/tcp"
else
    sudo ufw allow "$NEW_PORT/tcp"
    # 注意：这里不主动 ufw enable，避免把用户锁死
fi

echo "[5/5] 提示下一步手动操作"
cat <<EOF
完成。下一步：
1. 在另一个终端测试: ssh -p $NEW_PORT wzf@localhost
2. 确认能登录后，再禁用 22 端口: sudo ufw delete allow 22/tcp
3. 想完全关闭 22 监听，编辑 $SSHD_DST 注释 Port 22 那行（如果有）后 reload ssh
EOF
```

## 十一、踩坑沉淀

1. **改 sshd_config 前留一个 SSH 会话别退出**。sshd reload 不会断已连会话，但如果配置写错 reload 后下次连接就进不去——这时已开的会话还能救你。更稳的做法：`sudo sshd -t` 先语法检查再 reload。
2. **改 Port 必须同步改 ufw**。`/etc/ssh/sshd_config.d/hardening.conf` 改 Port 2222 后立刻 `sudo ufw allow 2222/tcp`，否则 ufw 还在 deny 2222 → 你新端口连不进。
3. **fail2ban 的 port = 2222 必须改**。`jail.local` 里 `[sshd]` 段默认 port=ssh=22，你 sshd 改了 2222 但 fail2ban 还在监听 22 的失败日志和封 22，等于白装。
4. **PermitRootLogin prohibit-password vs no**。Ubuntu 默认 prohibit-password（允许 root 用密钥登，禁密码）。家用加固到 `no` 完全禁 root 登录更稳，需要 root 操作就 `sudo`。
5. **禁用密码登录前先确认公钥能登**。`PasswordAuthentication no` 一旦生效、你的公钥又因为权限问题登不进 → 物理机操作。建议：改完留一个 ssh 会话开着，再开一个新终端测试公钥登录成功，再退出原会话。
6. **fail2ban 的 backend = systemd 在 Ubuntu 24.04 是关键**。Ubuntu 22.04 之前默认读 `/var/log/auth.log`，24.04 默认 journald，老教程会让你 `sudo touch /var/log/auth.log` 创建文件——不需要了，只要 `backend = systemd` fail2ban 直接读 journal。
7. **ufw enable 一定先 allow 自己的 SSH 端口**。`ufw enable` 会提示 "Command may disrupt existing ssh connections"，确认前必须先 `ufw allow <port>/tcp`。
8. **authorized_keys 文件权限严格**。`~/.ssh` 必须 700，`~/.ssh/authorized_keys` 必须 600，否则 sshd 直接忽略（视为不安全）。`chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`。
9. **改了 sshd_config 后用 `sudo sshd -T | grep <key>` 验证生效**。`-T` 打印所有生效配置项（合并了主文件 + sshd_config.d/*），能看到 `PermitRootLogin no` 真的生效了没。

## 十二、为什么不直接关 SSH

有人会问：既然家用，干脆 `systemctl disable --now ssh` 不就最安全？

对，但前提是你永远不需要远程访问。现实场景：
- 在外面想推代码：[SSH 规范工作流](/posts/ssh-workflow/) 里讲过 ssh.github.com:443 走 GitHub，需要本机 SSH 客户端但**不需要本机 sshd 服务端**
- 在外面想远程桌面操作家里主机：需要 sshd（或 [Tailscale](https://tailscale.com/) 等内网穿透方案）
- 在家里另一台笔记本连主机跑命令：需要 sshd

所以加固 SSH 比关 SSH 更实用。后续如果想做"手机在外面连家里"，写另一篇讲 Tailscale 的会更合适——Tailscale 是 WireGuard-based 的内网穿透，比直接暴露 SSH 更安全（私有协调服务器 + WireGuard 加密），但需要 tailscale.com 账号登录 OAuth 授权（本文不展开，留作下回分解）。

## 十三、尾巴：加固不是一次性的

加固一次写好 sshd_config.d/hardening.conf + fail2ban + ufw，之后**定期检查**：

```bash
# 每周看一次：
journalctl -u ssh --since "7 days ago" | grep -c Failed   # 失败次数趋势
sudo fail2ban-client status sshd                          # 当前封禁数
sudo ufw status verbose                                   # 防火墙规则是否被改动
```

爆破 IP 列表是真实威胁的晴雨表——家用宽带即使没公网 IP，内网恶意设备扫 22 端口也会留下痕迹。**fail2ban 封禁列表从 0 长到几十的那天，就是你加固见效的那天**。

相关阅读：
- [GitHub SSH 规范工作流](/posts/ssh-workflow/) —— ed25519 key + ssh.github.com:443 绕封锁 + push.sh 重试，客户端侧
- [轻量健康检查](/posts/health-check/) —— 把 SSH 失败计数加进健康检查脚本
- [Cloudflare Tunnel 实战](/posts/cloudflare-tunnel-guide/) —— 不开 SSH 公网端口，用隧道暴露服务
