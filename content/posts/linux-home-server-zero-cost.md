+++
title = '零成本搭一个家用 Linux 自托管栈'
date = 2026-08-23T17:00:00+08:00
draft = false
tags = ['Linux', '自托管', 'Hugo', 'Cloudflare']
categories = ['笔记']
summary = '不买域名、不开端口、不动路由器，靠一台 Ubuntu 家用主机搭起静态博客 + 公网入口的全过程记录。'
+++

## 目标

一台 Ubuntu 家用主机，想做点服务器的事：博客、网盘、监控……但现实是：

- 没公网 IP（运营商大内网）；
- 不想花钱买域名 / 备案；
- 不想动路由器开端口（也有可能开不了）；
- 不想给本机开过多对外端口。

最终方案：**Hugo + Cloudflare Tunnel**，跑通了一个零成本公开博客。

## 技术栈

| 层 | 选项 | 理由 |
|---|---|---|
| 站点 | Hugo（静态生成器） | 生成纯静态文件，性能强、维护成本低 |
| 主题 | PaperMod | 现代简洁，支持暗色、TOC、搜索、归档、标签 |
| 公网入口 | Cloudflare Tunnel（quick tunnel） | 出站连接，绕 NAT/防火墙，免域名 |
| HTTPS | Cloudflare 自动签 | 不用 Let's Encrypt，不用 acme.sh |
| 系统 | Ubuntu 24.04 + GNOME + Wayland | 家用桌面顺便当服务器 |

## 关键决定

### 为什么不用 WordPress / Ghost？

动态站需要 PHP / Node，吃内存，要管数据库，更新麻烦。家用主机静态站更稳：断电重启只要把两个进程拉起来即可，无需恢复数据库。

### 为什么不用 Nginx + frp / nps？

- Nginx 要开 80/443 入站，运营商封端口直接 GG；
- frp / nps 需要一台有公网 IP 的中转服务器，**那台机器要花钱**，违背"零成本"。

Cloudflare Tunnel 把"中转"这件事外包给 Cloudflare 免费 quick tunnel，没机器成本。

### 为什么选 Hugo 而不是 Hexo / Jekyll？

- Hugo 单二进制，不依赖 Node/Ruby 环境，装一次永久用；
- extended 版支持内嵌 SCSS，主题生态成熟；
- 构建速度对家用机零压力。

## 网络下载避坑

> 国内访问 GitHub 直连经常失败；如果机器装过 Watt Toolkit，`/etc/hosts` 里 `github.com` 会被指向 `127.0.0.1`，**任何走 GitHub 的下载都会 502**。

绕开办法：

- `cloudflared`：从 [Cloudflare 自己的 CDN](https://pkg.cloudflare.com/cloudflared/) 下，不碰 GitHub；
- `hugo_extended`：用 GitHub 代理（[ghproxy.net](https://ghproxy.net)）下载；
- 其它走 apt 的包：换 USTC / 清华镜像源即可。

## 目录约定

```
~/Files/blog/                       # Hugo 站点根
├── hugo.toml                       # 配置
├── content/posts/                 # 文章
├── themes/PaperMod/               # 主题
└── public/                        # 生成的静态站

~/.local/bin/
├── hugo                           # wrapper 脚本
├── hugo.real                      # 0.165 extended 二进制
└── cloudflared                    # Cloudflare 守护
```

## 重启后恢复

家里断电后两个进程都没了。恢复命令：

```bash
# 1. 拉起 Hugo（本地静态站）
nohup ~/.local/bin/hugo server \
    --bind 127.0.0.1 -p 1313 \
    --buildDrafts -s ~/Files/blog \
    >/tmp/hugo.log 2>&1 &

# 2. 拉起 cloudflared quick tunnel（注意：URL 会变）
nohup ~/.local/bin/cloudflared tunnel \
    --url http://localhost:1313 \
    >/tmp/cf.log 2>&1 &
```

新地址在 `/tmp/cf.log` 里 grep `trycloudflare.com` 即可。

## 还能加什么

零成本栈还能扩展的方向：

- **Gitea / Forgejo**：自托管 Git，配合 Cloudflare Tunnel 暴露；
- **Vaultwarden**：自托管密码管理器（Bitwarden 兼容）；
- **Uptime Kuma**：监控其它服务存活；
- **Nextcloud**：自托管网盘（吃资源，慎用）。

这些都不需要公网 IP，全部走 Cloudflare Tunnel 即可。

## 结论

家用 Linux 当服务器，最大的难点不是性能，是 **网络入口**。Cloudflare Tunnel 把这件事彻底简化了。剩下的只是挑软件、写配置——一晚上能搭出像模像样的自托管栈。
