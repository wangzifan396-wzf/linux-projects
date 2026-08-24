+++
title = '第一篇：博客上线了'
date = 2026-08-23T15:00:00+08:00
draft = false
tags = ['博客', '记录']
categories = ['随笔']
summary = '用 Hugo + Cloudflare Tunnel，零成本把家用 Linux 主机变成公开博客站点。'
+++

## 你好，世界

这台 Linux 家用主机没有公网 IP，却通过 **Cloudflare Tunnel** 把本地服务安全地暴露到了公网。
整个过程：

1. 本地用 **Hugo** 生成静态站点，监听 `127.0.0.1:1313`；
2. **cloudflared** 建立一条到 Cloudflare 边缘的反向隧道；
3. Cloudflare 分配一个 `*.trycloudflare.com` 的 HTTPS 域名，外网即可访问。

## 为什么选这套

- **零成本**：Hugo 和 cloudflared 都免费，Cloudflare quick tunnel 不需要域名、不需要备案；
- **零端口**：家用宽带运营商通常封入站端口（80/443/8080），Cloudflare Tunnel 是出站连接，绕过 NAT 与防火墙；
- **安全**：本地服务只绑定 `127.0.0.1`，不对外开任何端口，所有流量经 Cloudflare 中转。

## 接下来

后续我会在这里记录折腾 Linux、服务器配置、以及各种技术小实验的过程。
