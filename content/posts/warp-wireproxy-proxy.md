---
title: "用 wireproxy + Cloudflare WARP 解决国内访问 GitHub 等外国网站不稳"
date: 2026-08-25T02:16:00+08:00
tags: ["wireproxy", "cloudflare-warp", "proxy", "linux"]
categories: ["network"]
description: "不需要 root，不装 tun 设备，纯用户态 WireGuard→Cloudflare WARP，给 Firefox 提供 SOCKS5 代理，稳定访问 GitHub、Google、Wikipedia 等被卡站点"
math: false
---

> 国内访问 GitHub、Wikipedia、Google 时好时坏，git push 已经走 SSH-over-443 解决（参见仓库 [GitHub SSH 规范工作流](https://github.com/wangzifan396-wzf/linux-projects/blob/main/docs/ssh-workflow.md) 文档），但**网页浏览**还是会随机失败。本文给一条不需要 root、不污染系统路由表、纯用户态的代理方案。

> 关键约束：家用 Linux 主机，sudo 密码不轻易给（防止误改系统），wireproxy 是**用户态 WireGuard 实现**，不需要 `/dev/net/tun`、不需要 root、不需要内核模块。

---

## 0. 方案对比与取舍

| 方案 | 需要 root | 稳定性 | 出口节点 | 是否合规* |
| --- | --- | --- | --- | --- |
| Cloudflare WARP 官方客户端 | ✅ 需要 sudo | 高 | Cloudflare 边缘 | 国内多数地区可访问 |
| **wireproxy + WARP（本文）** | ❌ 不需要 | 高 | Cloudflare 边缘 | 同上 |
| wireproxy + 自建 WG 节点 | ❌ | 看节点 | 看节点 | 节点合法性自负 |
| mihomo + 免费机场节点 | ❌ | 看机场 | 各种墙外 | 节点本身常不合规 |

\* 这里"合规"指 Cloudflare 在国内的合规情况，不是法律建议。WARP 在国内多数地区能直连，少数地区（香港、美西出口）被 Cloudflare 限制。

**为什么选 wireproxy + WARP**：
- **不要 root**：所有操作在用户目录 + systemd --user 完成
- **出口是 Cloudflare**：不是某个可疑的免费节点，IP 干净，访问 Google/GitHub 不会触发 "unusual traffic" 验证码
- **稳定**：Cloudflare 边缘国内多地有节点（成都、北京、广州、上海），延迟低
- **不要流量**：只是浏览器走代理，下载大文件等仍走直连

---

## 1. 前置条件

- Linux 主机（x86_64 / arm64 都行，wireproxy 都有 release）
- `curl`、`tar`、`python3`（用来生成 WireGuard 密钥 + 改配置）
- 网络能访问 `api.cloudflareclient.com`（注册 WARP 用，国内多数地区通）

---

## 2. 下载 wireproxy

```bash
mkdir -p ~/Files/proxy && cd ~/Files/proxy

# 直连 GitHub release（国内可能慢，可用 ghproxy 镜像）
curl -L -o wireproxy.tar.gz \
  https://github.com/windtf/wireproxy/releases/download/v1.1.3/wireproxy_linux_amd64.tar.gz

# 国内网络慢时用镜像
# curl -L -o wireproxy.tar.gz \
#   https://ghproxy.net/https://github.com/windtf/wireproxy/releases/download/v1.1.3/wireproxy_linux_amd64.tar.gz

tar xzf wireproxy.tar.gz && rm -f wireproxy.tar.gz
chmod +x wireproxy
./wireproxy --version
# 期望：wireproxy, version 1.1.3
```

---

## 3. 用 Cloudflare WARP API 注册账号（拿 WireGuard 配置）

WARP 协议的本质是：你和 Cloudflare 之间建立一条 WireGuard 隧道，你的流量从 Cloudflare 边缘出口出去。这条 WireGuard 隧道需要：
- 你的私钥（本地生成）
- 你的公钥（注册到 Cloudflare，让 WARP 服务器认识你）
- WARP 服务器的公钥（固定值，所有人共用）
- WARP 服务器 endpoint（engage.cloudflareclient.com:2408，UDP）

注册流程：本地生成 X25519 密钥对 → POST 公钥到 `api.cloudflareclient.com/v0a2154/reg` → 拿到 account_id、peer info、interface 地址。

```python
# 文件名：register-warp.py（一次性运行）
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives import serialization
import base64, json, uuid, time, urllib.request

# 1. 生成 WireGuard 密钥对（X25519 raw 32 字节 = WireGuard 私钥格式）
priv = X25519PrivateKey.generate()
priv_bytes = priv.private_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PrivateFormat.Raw,
    encryption_algorithm=serialization.NoEncryption(),
)
priv_b64 = base64.b64encode(priv_bytes).decode()
pub_b64 = base64.b64encode(
    priv.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
).decode()
print('private_key:', priv_b64)
print('public_key :', pub_b64)

# 2. 用真实公钥注册 WARP 账号（"key" 字段就是 WG 公钥）
tos = time.strftime('%Y-%m-%dT%H:%M:%S.000Z', time.gmtime())
body = json.dumps({
    'key': pub_b64,
    'install_id': '',
    'fcm_token': '',
    'tos': tos,
    'model': 'Linux',
    'serial_number': str(uuid.uuid4()),
    'locale': 'en_US',
}).encode()
req = urllib.request.Request(
    'https://api.cloudflareclient.com/v0a2154/reg',
    data=body, method='POST',
    headers={
        'CF-Client-Version': 'a-6.10-2154',
        'Content-Type': 'application/json',
        'User-Agent': 'okhttp/3.12.1',
        'Accept': '*/*',
    },
)
with urllib.request.urlopen(req, timeout=15) as r:
    d = json.loads(r.read())
peer = d['config']['peers'][0]
print('account_id  :', d['id'])
print('license_key:', d['account']['license'])
print('peer.pubkey :', peer['public_key'])
print('peer.endpoint:', peer['endpoint']['host'])
print('iface.v4   :', d['config']['interface']['addresses']['v4'])
print('iface.v6   :', d['config']['interface']['addresses']['v6'])

# 3. 写 wireproxy 配置
open('wireproxy.conf', 'w').write(f'''[Interface]
PrivateKey = {priv_b64}
Address = {d['config']['interface']['addresses']['v4']}/32
Address = {d['config']['interface']['addresses']['v6']}/128
DNS = 1.1.1.1, 2606:4700:4700::1111
MTU = 1280

[Peer]
PublicKey = {peer['public_key']}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = {peer['endpoint']['host']}

[Socks5]
BindAddress = 127.0.0.1:1080

[HTTP]
BindAddress = 127.0.0.1:1081
''')
import os; os.chmod('wireproxy.conf', 0o600)
print('=== wireproxy.conf 已写入 ===')
```

运行：

```bash
python3 register-warp.py
```

> 几个关键点：
> - WARP API 的 `key` 字段 **就是你 WireGuard 公钥**，不是随便填的 install_id
> - 私钥 **本地生成不上传**，只把公钥发给 Cloudflare。这是标准 WireGuard 协议做法
> - 注册响应里有 `account.license`（一个 24 字符的 key），那是 WARP+ 升级用，普通免费用户可忽略
> - `Endpoint` 默认用域名 `engage.cloudflareclient.com:2408`，但国内很多运营商封了 2408 端口的 UDP，**建议直接写 IPv4 IP + 备用端口**，见第 8.1 节实测排查（本机实测 `188.114.96.1:500` 可用）

---

## 4. 启动 wireproxy

```bash
cd ~/Files/proxy
./wireproxy -c wireproxy.conf
# 期望日志：
#   Interface state was Down, requested Up, now Up
#   peer(...) - Starting
```

后台跑：

```bash
nohup ./wireproxy -c wireproxy.conf >wireproxy.log 2>&1 &
disown
```

测试 SOCKS5：

```bash
curl -sS --max-time 12 --socks5-hostname 127.0.0.1:1080 \
  https://1.1.1.1/cdn-cgi/trace | grep -E '^(ip|warp|colo)='
# 期望：
#   ip=104.28.x.x
#   colo=LAX  （或其他 Cloudflare 边缘机房）
#   warp=on   ← 这一行必须有

curl -sS --max-time 15 --socks5-hostname 127.0.0.1:1080 \
  -o /dev/null -w "Google: HTTP=%{http_code}\n" https://www.google.com/
# 期望：HTTP=200 或 302
```

如果 `warp=on` 出现，说明 WireGuard 握手成功，流量已经在走 Cloudflare 边缘出口。

---

## 5. 用 systemd --user 守护（开机自启）

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

[Install]
WantedBy=default.target
```

启用：

```bash
systemctl --user daemon-reload
systemctl --user enable --now wireproxy-warp.service
systemctl --user status wireproxy-warp.service --no-pager | head -8
```

---

## 6. 配置 Firefox 走 SOCKS5 + 远程 DNS

只有 SOCKS5 还不够——**Firefox 默认 DNS 走本地系统**，意味着虽然 TCP 流量走了代理，但 DNS 查询还是经过本地 DNS（可能被污染），导致部分网站还是访问失败。

正确做法是设 `network.proxy.socks_remote_dns = true`，让 DNS 也走 SOCKS5 远端解析。

直接给 Firefox profile 写 `user.js`（每次 Firefox 启动都会读，覆盖 prefs.js 对应键）：

Snap Firefox 的 profile 路径是 `~/snap/firefox/common/.mozilla/firefox/<随机>.default/user.js`，传统 deb/tar 版是 `~/.mozilla/firefox/<随机>.default/user.js`。先找：

```bash
ls -d ~/snap/firefox/common/.mozilla/firefox/*.default* ~/.mozilla/firefox/*.default* 2>/dev/null
```

往该目录写 `user.js`：

```javascript
// user.js —— 强制走 wireproxy SOCKS5 代理
user_pref("network.proxy.type", 1);               // 1 = 手动配置代理
user_pref("network.proxy.socks", "127.0.0.1");
user_pref("network.proxy.socks_port", 1080);
user_pref("network.proxy.socks_version", 5);
user_pref("network.proxy.socks_remote_dns", true); // ★关键：DNS 走代理远端
user_pref("network.proxy.http", "");
user_pref("network.proxy.http_port", 0);
user_pref("network.proxy.ssl", "");
user_pref("network.proxy.ssl_port", 0);
user_pref("network.proxy.no_proxies_on",
  "127.0.0.1, ::1, localhost, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, *.local");
user_pref("network.dns.disablePrefetch", true);   // 关闭 DNS 预取，防泄露
user_pref("network.trr.mode", 0);                 // DoH 走系统（即走代理）
```

**重启 Firefox** 后代理生效。验证：在地址栏输入 `https://1.1.1.1/cdn-cgi/trace`，看 `warp=on` 即说明流量走了代理。

> **想临时关闭代理**：删掉 `user.js` 重启 Firefox，或在 `about:preferences#general` 的 Network Settings 里临时改成 "No proxy"。但下次重启又会被 user.js 覆盖。

---

## 7. 关键设计点详解

### 7.1 为什么"用户态 WireGuard"不要 root

标准 WireGuard（`wg-quick`）需要：
- 内核模块 `wireguard`（Linux 5.6+ 已自带）
- 创建 `/dev/net/tun` 设备（需要 root）
- 修改路由表（需要 root）

wireproxy 用纯 Go 实现 WireGuard 协议，**所有包都从用户态 socket 进出**，不需要 tun 设备、不需要改路由表。它对外只暴露一个 SOCKS5/HTTP 代理端口，应用程序**主动**连接这个端口才走代理，不影响系统其他流量。

好处：
- 系统其他进程（apt、systemd、DNS resolver）不受影响
- 关掉 wireproxy 后一切如常，不留痕迹
- 可以同时跑多个 wireproxy 实例（多账号 / 多 endpoint）

### 7.2 `socks_remote_dns` 为什么必须开

如果不开，Firefox 会：
1. 用本地 DNS 解析 `www.google.com` → 国内 DNS 可能返回污染 IP（如 `6.x.x.x`）
2. 通过 SOCKS5 连接"污染后的 IP"
3. 浏览器收到错误证书或超时

开了 `socks_remote_dns`：
1. Firefox 把"我要连 www.google.com"通过 SOCKS5 发给 wireproxy
2. wireproxy 通过 WARP 隧道向 Cloudflare 的 DNS（1.1.1.1）查询
3. 拿到正确 IP，建立连接

### 7.3 为什么 WARP 不算"翻墙"

WARP 是 Cloudflare 的产品，目的是加密 + 加速，**不是匿名 VPN**：
- 出口 IP 是 Cloudflare 的，能看到你的流量经过 Cloudflare
- Cloudflare 边缘节点国内合规（多数地区可直连）
- 不能用来"伪装地理位置"（出口 IP 大致和你地理位置一致）

它解决的是"DNS 污染 + 部分站点 TCP 阻断"问题，不是"完全匿名上网"。

---

## 8. 故障排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `wireproxy` 启动后没有 `warp=on` | WireGuard 握手失败 | 看 `journalctl --user -u wireproxy-warp -f`，常见是 endpoint 被运营商 QoS（UDP 丢包），**见 8.1 节批量测可用 IP+端口** |
| `curl: (97) Can't complete SOCKS5 connection to xxx` (code 4) | 目标域名解析后的 IP 在 `0.0.0.0/0` 范围内，wireproxy 拒绝环回 | 这是预期行为，访问 Cloudflare 自家服务（如 trycloudflare.com）会出现，**忽略即可** |
| Firefox 显示 "Unable to connect" 但 curl SOCKS5 OK | Firefox 没读到 user.js | 确认 Firefox 完全退出后重启（不是关窗）；用 `about:support` 看 profile 路径 |
| 速度慢 | 选到了远的 Cloudflare 边缘 | 多测几次 `1.1.1.1/cdn-cgi/trace` 看 `colo`，通常国内会选 `LAX`/`SJC`，香港出口被 Cloudflare 限制时改 endpoint |
| `warp=off` 但 HTTP=200 | 站点可能用了 Cloudflare CDN | 看 `1.1.1.1/cdn-cgi/trace` 的 `warp` 字段，必须是 `on` 才算走代理 |

---

## 8.1 WARP endpoint 被封怎么办（实测排查）

**现象**：`journalctl --user -u wireproxy-warp -f` 一直刷 `Handshake did not complete after 5 seconds, retrying`，curl SOCKS5 超时，但 `nc -u -z 162.159.192.1 2408` 显示 "succeeded"。

**原因**：运营商对 WARP 默认 endpoint（`162.159.192.1:2408`）的 UDP 流量做了 QoS/丢包。注意 `nc -u -z` 对 UDP **不可靠**——它发空包，只要没收到 ICMP port unreachable 就报 "succeeded"，但 WireGuard 握手包（含真实载荷）会被丢弃。**所以 nc 通 ≠ WG 握手能通**。

**排查**：批量测不同 IP + 端口组合，找到能握手的。WARP 有多个 endpoint IP（`162.159.192.x`、`188.114.9x.x`）+ 支持几十个端口。实测 `162.159.192.1` 的所有端口都被封，换到 `188.114.96.1` 后端口 500 能通。

```bash
# 批量测 IP + 端口，第一个能 warp=on 的就停
cd ~/Files/proxy
for ep in 188.114.96.1:500 188.114.97.1:500 162.159.192.8:500 \
          188.114.96.1:854 188.114.96.1:4500 188.114.96.1:2408; do
  sed -i "s/^Endpoint = .*/Endpoint = $ep/" wireproxy.conf
  systemctl --user restart wireproxy-warp.service
  sleep 4
  if curl -sS --max-time 5 --socks5-hostname 127.0.0.1:1080 \
      https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -q "warp=on"; then
    echo ">>> $ep 可用!"
    break
  else
    echo "$ep 不通"
  fi
done
```

**本机实测可用**：`Endpoint = 188.114.96.1:500`（出口 LAX，IP `104.28.251.46`）。不同地区/运营商可用的组合不同，以批量测试结果为准。

> WARP 支持的备用端口（社区常用，挨个试到能握手为止）：500, 854, 859, 864, 878, 880, 890, 891, 894, 903, 908, 928, 934, 939, 942, 943, 945, 946, 955, 968, 987, 988, 1002, 1010, 1012, 1014, 1018, 1070, 1074, 1180, 1387, 1703, 1843, 2371, 2408, 2506, 3138, 3476, 3581, 3854, 4177, 4198, 4233, 4500, 5279, 5956, 7103, 7152, 7156, 7281, 7558, 8319, 8742, 8854, 8886。

---

## 9. 一图看清架构

{{< mermaid >}}
graph LR
  F[Firefox] -->|SOCKS5 1080| W[wireproxy<br/>用户态进程]
  W -->|WireGuard UDP| C[Cloudflare 边缘<br/>engage.cloudflareclient.com:2408]
  C --> E[Cloudflare 出口<br/>104.28.x.x]
  E --> G[(GitHub / Google / Wikipedia)]
{{< /mermaid >}}

整个过程：
- 不需要 root
- 不创建 tun 设备
- 不改系统路由表
- 不影响其他程序
- 不影响本机 systemctl / apt / DNS

---

## 10. 完整一页速查

```bash
# 1. 下 wireproxy
mkdir -p ~/Files/proxy && cd ~/Files/proxy
curl -L -o wireproxy.tar.gz \
  https://ghproxy.net/https://github.com/windtf/wireproxy/releases/download/v1.1.3/wireproxy_linux_amd64.tar.gz
tar xzf wireproxy.tar.gz && rm wireproxy.tar.gz && chmod +x wireproxy

# 2. 注册 WARP + 写 wireproxy.conf（见第 3 节 Python 脚本）
python3 register-warp.py

# 3. 起 + 自启
systemctl --user daemon-reload
systemctl --user enable --now wireproxy-warp.service

# 4. 验证
curl --socks5-hostname 127.0.0.1:1080 https://1.1.1.1/cdn-cgi/trace | grep warp=on

# 5. 写 Firefox user.js（见第 6 节），重启 Firefox
```

---

## 附：本机当前配置快照

| 项 | 值 |
| --- | --- |
| wireproxy 版本 | v1.1.3 |
| 二进制路径 | `/home/wzf/Files/proxy/wireproxy` |
| 配置文件 | `/home/wzf/Files/proxy/wireproxy.conf` |
| SOCKS5 端口 | `127.0.0.1:1080` |
| HTTP 代理端口 | `127.0.0.1:1081` |
| systemd unit | `~/.config/systemd/user/wireproxy-warp.service`（enabled） |
| WARP endpoint | `188.114.96.1:500`（默认 `engage.cloudflareclient.com:2408` 被封，见 8.1 节） |
| 出口 colo | LAX（洛杉矶，Cloudflare 边缘） |
| Firefox profile | `~/snap/firefox/common/.mozilla/firefox/q9wwwobd.default/` |
| Firefox user.js | 该 profile 目录下 `user.js` |
