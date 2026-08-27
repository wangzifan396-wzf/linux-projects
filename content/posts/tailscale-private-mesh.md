---
title: "用 Tailscale 把家机变成随身可访问的私密网"
date: 2026-08-27
categories: ["自托管", "网络"]
tags: ["Tailscale", "WireGuard", "VPN", "自托管", "Linux", "远程访问"]
draft: false
---

之前在 [家用 Linux 自托管栈全景](/posts/self-hosted-stack-overview/) 里，Gitea 是走 Cloudflare Tunnel 暴露到公网的——别人也能进，靠一层访问凭证挡着。但 Gitea 本质是我的私有 Git，只该我自己设备能摸。于是给家机加了一层 **Tailscale**：一张只有我设备能进的加密虚拟网，在外也能像连着家里 WiFi 一样访问 Gitea、SSH、文件，且**不暴露任何公网端口**。

这篇记录怎么装、原理、以及它在我这个零成本栈里卡在什么位置。

## 它到底干什么

先破除一个常见误解：**Tailscale 不是翻墙 / 代理，不帮你访问 GitHub、YouTube、ChatGPT**——那些公网站点你用自己的网络直接就能上。Tailscale 干的是反方向：把**你自己的设备**（家机、笔记本、手机）拉进一张私密虚拟局域网，让你在外能安全访问**自家服务**。

- 访问公网站点 → 走你自己的网络，与 Tailscale 无关
- 访问 `gitea.你的家机` → 走 Tailscale 加密隧道，只有你授权的设备进得去

它是 [Cloudflare Tunnel](/posts/cloudflare-tunnel-guide/) 的互补而非替代：Tunnel 把服务**公开**给外人，Tailscale 只让自己的设备进。最干净的做法是——私密管理走 Tailscale，真要对外共享再走 Tunnel，甚至把路由器上 Gitea 的公网端口关掉，只留 Tailscale 入口。

## 原理：为什么没公网 IP 也能连

底层是 **WireGuard**（极简高速加密 VPN 协议）。整件事分三步：

1. 每台设备安装 Tailscale 后，拿到一个内网 IP（形如 `100.x.x.x`，专门留给这类用途的地址段），并生成自己的加密密钥对；
2. Tailscale 的**协调服务器**只当"介绍人"：帮设备互相交换"对方 IP + 公钥"以及怎么穿透 NAT 打洞，**不经手实际数据**；
3. 设备之间**点对点（P2P）直连加密通信**（UDP 打洞）。只有打洞实在失败时才临时走一下 Tailscale 中继（DERP）。

所以：数据在你设备和家机之间端到端加密直连，Tailscale 公司看不到内容；"怎么找到彼此"才借用了它的协调服务。这也解释了为什么家用宽带没公网 IP、路由器没做端口转发，照样能从外连回家——NAT 穿透 + 中继兜底解决了可达性。

在我这个栈里的位置：

{{< mermaid >}}
flowchart LR
    Phone["📱 手机<br/>Tailscale App"] -->|"P2P 加密"| TS["🔒 Tailscale 虚拟网<br/>WireGuard"]
    Laptop["💻 笔记本<br/>tailscale ssh"] -->|"P2P 加密"| TS
    TS -->|"MagicDNS<br/>100.x.x.x"| Host["🏠 家机<br/>tailscaled"]
    Host --> G["gitea :3000"]
    Host --> S["SSH :22"]

    style TS fill:#e0f7fa,stroke:#006064
    style Host fill:#e8f5e9,stroke:#2e7d32
{{< /mermaid >}}

## 安装与登录（家机）

```bash
# 1. 安装（官方一键脚本，Debian/Ubuntu 通用）
curl -fsSL https://tailscale.com/install.sh | sh

# 2. 启动并登录（会打印一个 https 链接）
sudo tailscale up
```

`tailscale up` 输出一行 `https://login.tailscale.com/a/xxxxx`，复制到浏览器打开、用账号登录，家机就加入网络。装完自动注册成 systemd 服务、**开机自启**。

登录同一账号把其他设备也加进来：笔记本装客户端、手机装 App，登录同一账号即自动进同一张网。

## 日常怎么用

组网完成后就三件事：**开客户端 → 用 MagicDNS 访问服务 → 用 `tailscale ssh` 远程登录**。

```bash
tailscale status          # 看哪些设备在线 + 各自的 100.x.x.x
tailscale ip              # 本机在虚拟网里的 IP
tailscale ping 家机名      # 测某台通不通
```

- **访问 Gitea**：浏览器开 `http://<家机名>.<tailnet>.ts.net:3000`（或 `http://100.x.x.x:3000`）
- **远程 SSH**（开 `--ssh` 后免密）：`tailscale ssh 你的用户名@<家机名>`

`tailscale up --ssh` 开启的是 Tailscale SSH：用 Tailscale 身份做认证，连 SSH 不用记密码，还能配合后台策略管控谁能登哪台。

## 安全收口：关掉公网端口

Tailscale 能私密访问后，原来 Cloudflare Tunnel 暴露的 Gitea 公网入口就可以收掉，攻击面更小。建议顺序（**先确认 Tailscale 能访问再关**）：

1. 用 `http://100.x.x.x:3000` 确认 Gitea 在 Tailscale 下能开；
2. 在路由器 / 防火墙关掉 Gitea 的入站端口，只留 Tailscale 入口；
3. 顺手给 SSH 再上一道锁——参考 [SSH 安全加固](/posts/ssh-hardening/)，在 `/etc/ssh/sshd_config` 设 `PasswordAuthentication no`，只留 Tailscale SSH + 密钥登录，密码爆破直接废掉。

## 取舍

| 选项 | 选了 | 没选 | 理由 |
| --- | --- | --- | --- |
| 远程访问家机 | Tailscale | 路由器端口转发 / 商业 VPN | 不暴露端口、不依赖公网 IP、免费、P2P 加密 |
| Gitea 入口 | Tailscale 私有 + 按需 Tunnel 公开 | 长期公网暴露 | 私有 Git 只该自己进，最小化攻击面 |

代价：免费版设备数有限（个人够用）、Tailscale 协调服务器是第三方（但只看信令不看数据）。家用场景这些都不是问题。

## 和我这个栈的关系

它接在 [自托管栈全景](/posts/self-hosted-stack-overview/) 的"入口层"和"服务层"之间，是**私有访问层**：不替代 GitHub Pages（博客正式入口）、不替代 Cloudflare Tunnel（对外分享）、不替代 [WARP 代理](/posts/warp-wireproxy-proxy/)（访问外网），只补上"我自己随时安全摸回家机"这一块。配合 [自动化巡检 CI](/posts/blog-ci-automation/) 里预留的 Telegram 告警钩子，家机出事能直接推到手机——完整闭环。

栈又长出一层。下一批想做的是真正自托管的服务（Umami 统计、Vaultwarden 密码库），届时博文继续同步，绝不"文档与实现两张皮"。
