+++
title = 'Cloudflare Tunnel 实战：家用宽带没公网 IP 也能开站'
date = 2026-08-23T16:00:00+08:00
draft = false
tags = ['Cloudflare', 'Tunnel', '自托管', '网络']
categories = ['教程']
summary = '零域名、零备案、零端口：用 cloudflared quick tunnel 把家用 Linux 上的本地服务暴露到公网 HTTPS。'
+++

## 背景

家用宽带的两个常见痛点：

1. **没公网 IP**：运营商 NAT 多层叠加，外网根本找不到你；
2. **入站端口被封**：80/443/8080 这些常用端口运营商基本都封了。

Cloudflare Tunnel 的妙处在于：你的机器 **主动出站** 连 Cloudflare 边缘，外网访问时由 Cloudflare 反向转发给你——于是 NAT、防火墙、端口封锁全部失效。

## 步骤

### 1. 装 cloudflared

Ubuntu 用户直接从 Cloudflare 自己的 apt 仓库装：

```bash
# 添加仓库
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /etc/apt/keyrings/cloudflare-main.gpg >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list

sudo apt update && sudo apt install -y cloudflared
```

不想用 sudo 也行，直接下 deb 包解压到 `~/.local/bin`：

```bash
mkdir -p ~/.local/bin
cd /tmp
wget https://pkg.cloudflare.com/cloudflared/pool/main/c/cloudflared/cloudflared_2026.8.2_amd64.deb
ar p cloudflared_*.deb data.tar.xz | xz -d | tar xf - ./usr/bin/cloudflared -O > ~/.local/bin/cloudflared
chmod +x ~/.local/bin/cloudflared
```

### 2. 跑一个本地服务

比如 Hugo：

```bash
hugo server --bind 127.0.0.1 -p 1313
```

注意只绑定 `127.0.0.1`，**不要** 绑 `0.0.0.0`，没必要直接对外。

### 3. 起 quick tunnel

```bash
cloudflared tunnel --url http://localhost:1313
```

第一条日志里会打印一个 `https://<随机>.trycloudflare.com` 的域名，这就是你的公网地址，HTTPS 自动配好。

## 想要固定域名？

quick tunnel 每次重启 URL 都会变。如果想要固定域名，需要：

1. 准备一个自己的域名（接入 Cloudflare，不需要备案）；
2. `cloudflared tunnel login` 完成交互式授权；
3. `cloudflared tunnel create <name>` 建一个命名隧道；
4. 写 `~/.cloudflared/config.yml`：

```yaml
tunnel: <tunnel-uuid>
credentials-file: /home/you/.cloudflared/<tunnel-uuid>.json
ingress:
  - hostname: blog.example.com
    service: http://localhost:1313
  - service: http_status:404
```

5. 在 Cloudflare 后台给这个 hostname 加一条 CNAME 指向 `<tunnel-uuid>.cfargotunnel.com`；
6. `cloudflared tunnel run <name>`。

## 优点与代价

**优点**：零成本、零域名（quick 模式）、零端口、HTTPS 自动、CF 边缘加速。

**代价**：
- quick tunnel 域名重启就变；
- 流量经过 CF 中转，国内访问会绕海外边缘节点（延迟略高）；
- 适合个人低流量站点，不适合高并发业务。

## 总结

最适合家用 Linux 主机的"开站姿势"之一：不用买域名、不用备案、不用动光猫/路由器。等你哪天想要固定域名，再升级到命名隧道即可。
