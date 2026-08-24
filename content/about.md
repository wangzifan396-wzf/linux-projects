+++
title = '关于'
date = 2026-08-23T15:00:00+08:00
draft = false
tags = ['关于']
categories = ['随笔']
summary = '关于这个博客和我，以及我的各个平台主页。'
+++

## 关于本站

这是一个跑在 **家用 Linux 主机** 上的个人技术博客。

- 站点生成器：[Hugo](https://gohugo.io/) v0.165 extended
- 主题：[PaperMod](https://github.com/adityatelange/hugo-PaperMod)
- 公网入口：[Cloudflare Tunnel](https://www.cloudflare.com/products/tunnel/)（quick tunnel）
- 系统：Ubuntu 24.04，GNOME + Wayland

家里没有公网 IP，运营商也封了入站端口，但 Cloudflare Tunnel 是 **出站连接**，于是绕过 NAT 与防火墙，把本地 `127.0.0.1:1313` 安全地暴露到 `*.trycloudflare.com` 的 HTTPS 域名。

## 我会写什么

- Linux 桌面与服务器折腾笔记
- Cloudflare / 自托管 / 静态站点
- 输入法、桌面环境、各种小工具
- 一些随手记和实验结果

## 我在用的平台

下面是我比较活跃的几个平台，顶部导航栏右上角也有对应的图标入口（**点击直接跳到我的主页**，不是分享按钮）：

| 平台 | 主页地址 |
|---|---|
| GitHub | [https://github.com/wangzifan396-wzf](https://github.com/wangzifan396-wzf) |
| 哔哩哔哩 | [https://space.bilibili.com/319363325](https://space.bilibili.com/319363325) |
| CSDN | [https://blog.csdn.net/m0_74023007](https://blog.csdn.net/m0_74023007) |
| 小黑盒 | [https://www.xiaoheihe.cn/community/45509815](https://www.xiaoheihe.cn/community/45509815) |
| RSS 订阅 | [/index.xml](/index.xml) |

QQ 和微信是封闭生态，没有公开主页 URL，所以不放右上角图标。需要的话可以加我：

- **QQ**：530142376
- **微信**：（暂未公开，需要可以 QQ 联系后单独加）

## 联系

- 文章底部有 3 个按钮：**微博 / 微信扫码 / 复制链接** —— 全是分享功能，可以把当前文章发到对应平台。
- 顶部右上角图标是 **个人主页链接**，跳转到我在各平台的主页。
- 想私下交流：上面列的 QQ / 微信都可以。

## 说明

由于使用 Cloudflare quick tunnel，**重启 cloudflared 后域名会变**；博客内容本身是本地静态生成，不影响数据。
