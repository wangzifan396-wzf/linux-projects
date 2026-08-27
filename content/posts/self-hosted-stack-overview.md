---
title: "家用 Linux 自托管栈全景：18 篇文章串起的零成本体系"
date: 2026-08-25T19:30:00+08:00
draft: false
tags: ["Linux", "自托管", "总结", "systemd", "Cloudflare", "GitHub-Pages"]
categories: ["总结"]
summary: "过去几天在一台 Ubuntu 家用主机上折腾出了一整套自托管栈：Cloudflare Tunnel 公网入口、GitHub Pages 固定博客、WARP 代理、Gitea 私有 Git、Tailscale 私有访问、systemd --user 服务管理、rsync 备份、bash 健康检查。18 篇文章分散写完容易忘了整体，这篇用一张大架构图把它们串起来，记录四个'零'设计哲学、分层取舍和踩坑沉淀。"
---

过去几天我在一台 Ubuntu 24.04 家用主机上折腾出了一整套自托管栈。从最早"用 Cloudflare Tunnel 把 Hugo 暴露到公网"开始，一路写到 WARP 代理、Gitea 私有 Git、GitHub Pages 部署、Tailscale 私有访问、systemd --user 服务管理、rsync 备份、bash 健康检查……零零散散 18 篇。

写多了容易忘整体。这篇是总结，用一张大架构图把 18 篇串起来，回答一个问题：**家用主机到底是怎么变成一个对外可见、自我运维、零成本运行的栈的？**

如果你是第一次来，建议先看这篇找方向，再按需要跳到具体某一篇。

## 一、设计哲学：四个"零"

整栈的每一个选择都围绕四个"零"展开，先把这四个原则讲清楚，后面所有取舍才有依据。

| 原则 | 含义 | 对应做法 |
| --- | --- | --- |
| **零成本** | 不买域名、不租 VPS、不开付费 CDN | 用 Cloudflare 免费档 + GitHub Pages 免费托管 + 家用宽带 |
| **零域名** | 不注册任何域名 | Cloudflare Tunnel 自带 `*.trycloudflare.com` 子域；GitHub Pages 自带 `*.github.io` 子域 |
| **零端口** | 家用路由器不做端口转发、不开 DMZ | 所有公网入口走 Cloudflare 边缘反向代理出站，不暴露监听端口 |
| **零系统配置** | 不动 `/etc/`、不要 root、不改发行版默认 | 全部用 `systemd --user` + 用户空间脚本，`sudo` 只用过一次（`enable-linger`） |

这四个"零"不是凑出来的口号，是真实约束：**家用宽带没公网 IP、路由器不想动、不想给应用 root、不想花钱买域名**。很多自托管教程默认你有 VPS + 域名 + sudo，这套没有，所以每一层都得换思路。

## 二、整体架构图

下面这张图是整栈的全景。家用 Linux 主机在最中间，左边是用户访问路径，右边是部署路径，上面是 systemd 服务层，下面是运维保障层。中间多了一条 **Tailscale 私有访问路径**——只让自己设备进家机，不开任何公网端口。

{{< mermaid >}}
flowchart TB
    subgraph User["👤 用户"]
        Browser["Firefox / Git 客户端 / Tailscale 客户端"]
    end

    subgraph Host["🏠 家用 Linux 主机<br/>Ubuntu 24.04 + GNOME/Wayland"]
        Hugo["Hugo server :1313"]
        subgraph SD["systemd --user 服务层 (Linger=yes)"]
            WP["wireproxy-warp<br/>SOCKS5 :1080"]
            G["gitea :3000"]
            CF["cloudflared<br/>反代 :1313"]
            HC["health-check.timer<br/>每 5min"]
        end
        TSd["tailscaled<br/>WireGuard 系统服务"]
        Scripts["~/Files/scripts/<br/>push.sh / health-check.sh"]
        BK["备份盘 rsync"]
    end

    subgraph CFnet["☁️ Cloudflare 边缘"]
        WARP["WARP endpoint"]
        Tun["Quick Tunnel HTTPS"]
    end

    subgraph TS["🔒 Tailscale 虚拟网<br/>WireGuard P2P 直连"]
        Mesh["手机 / 笔记本 / 家机<br/>100.x.x.x"]
    end

    subgraph GH["🐙 GitHub"]
        Repo["linux-projects 仓库"]
        Act["Actions 构建"]
        Pg["Pages 固定 URL"]
    end

    Ext["🌐 外部站点<br/>GitHub / Google / Wiki"]

    Browser -.->|"SOCKS5 代理"| WP
    Browser -.->|"SSH 443 推送"| Ext
    WP --> WARP --> Ext

    Hugo --> CF --> Tun
    Tun -.->|"临时公网入口<br/>URL 每次重启变"| Browser

    Browser -->|"Tailscale 私有访问<br/>仅授权设备"| TS
    TS -->|"MagicDNS"| TSd
    TSd --> G

    Hugo -->|"push.sh 一键部署"| Repo --> Act --> Pg
    Pg -.->|"固定 URL 分享"| Browser

    HC --> Scripts
    Scripts -->|"curl 重试 3 次"| WP
    Scripts -->|"curl :3000"| G
    Scripts -->|"is-active + 端口监听"| CF
    Scripts -->|"日志 + 状态机"| Log["~/Files/monitor/<br/>health.log"]

    BK -->|"每日 03:00<br/>3-2-1 原则"| Host

    style Host fill:#e8f5e9,stroke:#2e7d32
    style SD fill:#f1f8e9,stroke:#558b2f
    style CFnet fill:#e3f2fd,stroke:#1565c0
    style GH fill:#fff3e0,stroke:#e65100
    style Ext fill:#fce4ec,stroke:#ad1457
    style User fill:#f3e5f5,stroke:#6a1b9a
    style TS fill:#e0f7fa,stroke:#006064
    style TSd fill:#e0f7fa,stroke:#006064
{{< /mermaid >}}

看图说话，整栈有 **两条对外路径**、**一条对内保障路径**，以及新增的 **Tailscale 私有访问路径**：

- **路径 A（用户访问站点）**：用户 → Cloudflare 边缘 → cloudflared 出站反代 → 本地 Hugo :1313。这条是"临时公网入口"，URL 每次重启 cloudflared 都变，适合调试和分享给少数人。
- **路径 B（用户访问正式博客）**：用户 → GitHub Pages 固定 URL → Actions 自动构建的静态站点。这条是"正式入口"，URL 永远不变，是最终分享给外界的地址。
- **路径 C（用户访问外部）**：用户 → SOCKS5 :1080 → wireproxy → WARP 边缘 → GitHub/Google/Wikipedia。解决国内访问抽风。
- **路径 D（私有访问家机）**：用户设备 → Tailscale 虚拟网（WireGuard P2P 加密）→ tailscaled → Gitea / SSH。这条是"私密入口"，只有你授权的设备进得去，**不开任何公网端口**，可替代 Cloudflare Tunnel 暴露 Gitea。
- **对内保障**：health-check.timer 每 5 分钟 curl 一遍服务真实可用性记日志；rsync 每天 03:00 增量备份到外接盘。

这五条路径下面分层展开。

## 三、分层串讲

### 1. 入口层：从临时隧道到固定 URL

最早只有 Cloudflare Tunnel 一条路径。家用宽带没公网 IP，路由器不想动，但 cloudflared 能让本地服务通过 Cloudflare 边缘反代到公网 HTTPS，域名用 `*.trycloudflare.com` 免费子域。这一步记录在 [Cloudflare Tunnel 实战](/posts/cloudflare-tunnel-guide/)。

临时隧道有个致命问题：**URL 每次重启 cloudflared 都变**，没法长期分享。所以最终博客搬到了 GitHub Pages：push 源码到 `main` 分支 → GitHub Actions 自动 `hugo --minify` → 部署到固定 URL `wangzifan396-wzf.github.io/linux-projects/`。整个过程在 [GitHub Pages 自动部署](/posts/github-pages-deploy/)，含项目仓库 baseURL 含子路径时 PaperMod 主题链接全部失效的踩坑记录。

两条路径现在并存：Cloudflare Tunnel 用来开发期实时预览（本地改完 `hugo server` 立刻能看到效果），GitHub Pages 用来发布最终版。详见 [博客技术栈升级](/posts/blog-stack-upgrade/)。

### 2. 代理层：让国内主机能稳定访问外网

GitHub 在国内访问抽风——22 端口常被封、HTTPS 时好时坏。两条配套路径解决：

- **SSH 推送通道**：ed25519 key + `ssh.github.com:443` 端口绕封锁，配套 `push.sh` 自动重试 5 次应对 WARP 抖动。记录在 [GitHub SSH 规范工作流](/posts/ssh-workflow/)。
- **SOCKS5 代理通道**：[wireproxy + Cloudflare WARP](/posts/warp-wireproxy-proxy/) 把 WARP 装成用户态 SOCKS5 代理，浏览器配 `127.0.0.1:1080` 就能稳定访问 Google/GitHub/Wikipedia。WARP 默认 endpoint 162.159.192.1:2408 可能被 ISP 封，换 188.114.96.1:500 解决。

这两条路径配合起来，国内主机访问外网的成功率从 ~70% 提到 ~99%。

### 3. 服务层：systemd --user 而不是 docker

家用主机不轻易给 sudo，但 wireproxy、Gitea、cloudflared 都要开机自启 + 崩溃重启。常规做法是 docker-compose 起一排容器，但 docker 要装 daemon + 给用户 docker 组权限 + 镜像更新维护，对家用来说太重。改用 **`systemd --user`**：

- 全部服务以普通用户身份跑，不要 root
- `enable-linger` 一次（让用户 session 在不登录时也启动），所有 enabled user 服务开机自启
- `Restart=on-failure` + `StartLimitBurst=5` 崩溃自动拉起
- 一个服务两个文件：`xxx.service` + `xxx.timer`，全在 `~/.config/systemd/user/`

详见 [systemd --user 工作流](/posts/systemd-user-workflow/)，含 unit 文件写法、常用命令、调试技巧，以及早期用 `nohup` 跑 cloudflared 的反面教材。

目前主机跑着 4 个 user 服务：

| 服务 | 端口 | 作用 |
| --- | --- | --- |
| `wireproxy-warp` | 1080 | SOCKS5 代理 → WARP |
| `gitea` | 3000 | 私有 Git 服务 |
| `cloudflared` | 反代 1313 | 公网隧道到本地 Hugo |
| `health-check.timer` | — | 每 5min 健康检查 |

此外 `tailscaled` 以**系统服务**常驻（不在 user 服务层），提供 Tailscale 私有访问；Gitea 现在同时能从 Cloudflare Tunnel（公开）和 Tailscale（私有）两个入口访问，推荐私密管理走 Tailscale、对外分享才走 Tunnel。

Gitea 单独写了一篇 [在 Linux 上自托管 Gitea](/posts/gitea-self-host/)，讲为什么不用 GitHub 付费 private repo、Gitea 怎么以 user 服务跑、SQLite 后端够用、怎么用 cloudflared 暴露到公网。Tailscale 那层见 [用 Tailscale 把家机变成随身私密网](/posts/tailscale-private-mesh/)。

### 4. 内容层：Hugo + PaperMod

博客本身是 Hugo + PaperMod 主题。最早一篇 [第一篇：博客上线了](/posts/hello/) 记下从零搭起来的过程，[零成本搭一个家用 Linux 自托管栈](/posts/linux-home-server-zero-cost/) 是全过程总览。后来给 PaperMod 加了 KaTeX 数学公式、Mermaid 流程图、Giscus 评论、首屏 Hero、移动端响应式、阅读进度条、滚动淡入，记录在 [博客技术栈升级](/posts/blog-stack-upgrade/)。

输入法折腾是插曲但值得一记：Wayland 下 fcitx4 + 搜狗会让终端闪烁，最终回到 IBus 智能拼音，学会用 Shift 切换中英。详见 [Ubuntu 24.04 中文输入法折腾记](/posts/ubuntu-ibus-pinyin/)。

### 5. 运维层：监控 + 备份

服务跑起来只是开始，长期运维还需要 **观察** 和 **备份** 两个视角。

**监控**不引入 uptime-kuma（Node.js 太重），改用 bash + systemd timer 每 5 分钟 curl 一遍真实可用性，记日志看趋势。脚本设计、重试机制、抖动过滤、状态机告警门槛都在 [轻量健康检查](/posts/health-check/) 里。关键设计：

- WARP 抖动 ~30%（单次 curl 经常超时），脚本重试 3 次后误报率降到 ~3%
- 状态机记 `fail_streak`，连续失败 N 次才告警，避免抖动误报
- 日志 1000 行轮转，~3.5 天历史趋势可查
- 已预留 Telegram / Webhook 通知钩子（`TG_BOT_TOKEN` + `TG_CHAT_ID` 即生效），服务真挂了能主动推到手机

**备份**用 rsync `--link-dest` 做增量 + systemd --user timer 每日 03:00 + 3-2-1 原则（3 份副本、2 种介质、1 份离线）。含可恢复性验证（备份不复原等于没备份）。详见 [家用 Linux 主机备份策略](/posts/backup-strategy/)。

## 四、设计取舍

为什么这套栈长这样？每一层都有替代方案，记下取舍依据，方便后来人判断。

| 层 | 选了 | 没选 | 理由 |
| --- | --- | --- | --- |
| 公网入口 | Cloudflare Tunnel | 路由器端口转发 | 家用宽带没公网 IP，且不想暴露监听端口 |
| 博客托管 | GitHub Pages | VPS 自托管 | 零成本 + 固定 URL + Actions 自动构建 |
| 代理 | wireproxy + WARP | 商业 VPN / 自建 SS | 零成本 + Cloudflare 背书 + 用户态不用 root |
| 服务管理 | systemd --user | docker-compose | 不用 root、不用 daemon、镜像维护负担 |
| 私有 Git | Gitea + SQLite | GitHub 付费 private | 零成本 + 数据完全本地 + 资源占用低 |
| 私有访问 | Tailscale | 路由器端口转发 / 商业 VPN | 只让自己设备进、不暴露端口、免端口转发 |
| 监控 | bash + systemd timer | uptime-kuma | 零依赖、零 Web UI、和现有架构同体系 |
| 备份 | rsync --link-dest | restic / borg | 系统自带、增量硬链接省空间、调试透明 |
| 推送通道 | SSH 443 + push.sh 重试 | HTTPS + PAT | 22 端口常被封、443 走 HTTPS 几乎不被封 |

这些取舍的共同点：**能用系统自带工具就不引新依赖，能给用户态就不给 root，能零成本就不花钱**。代价是缺少 Web UI、缺少告警推送、缺少跨机分布式能力——但家用场景下这些都不重要。

## 五、踩坑沉淀

18 篇文章里散落着不少坑，集中记一遍最关键的 5 条，避免重蹈：

1. **Hugo 文章 `date` 不能设未来时间**。Hugo 默认跳过 future-dated 文章，会导致 GitHub Pages 上 404 但本地构建无报错。判断当前时间用 `date` 命令，不要看 IDE 或 memory 时间戳（往往是最后写入时间，可能是未来）。详见 [GitHub Pages 部署](/posts/github-pages-deploy/)。
2. **TOML 子表吞 key**。hugo.toml 里 `images = ['og-default.jpg']` 必须放在 `[params]` 段下、`[params.assets]` 等任何子表之前，否则会被解析成 `params.assets.images` 静默失败，OG 图 meta 不输出。
3. **Mermaid 必须本地托管**。jsdelivr CDN 在国内 30%+ 超时（6.8s+ 甚至 ERR_CONNECTION_RESET），导致流程图永远不渲染。改成 `static/js/mermaid.min.js` 本地托管（212KB gzip），同源加载 + GitHub Pages CDN + 浏览器缓存，一次加载永久复用。
4. **Mermaid 不能用 IntersectionObserver 懒加载**。headless 浏览器和部分真机不触发 IO，`.mermaid` 会一直停留在源码文本状态。直接在 `extend_footer.html` 加载脚本 + `mermaid.run({nodes: ...})` 渲染更稳。
5. **baseURL 含子路径时菜单 url 不能以 `/` 开头**。GitHub Pages 项目仓库的 baseURL 是 `host/<repo>/`，Hugo 的 `absLangURL` 对 `/`-开头的 url 会从 host 根拼接，丢掉 `<repo>/` 子路径。所有 menu url、favicon、socialIcons rss 都用相对路径，并 override `social_icons.html` 用 `absURL` 而非 `safeURL`。

## 六、仍在路上

栈跑起来了，但还有几件事可以做：

- **Tailscale 私有访问层（已落地）**：见 [用 Tailscale 把家机变成随身私密网](/posts/tailscale-private-mesh/)。家机现已能从任意授权设备安全访问，Gitea 公网端口可收口。
- **配置版本化（已基本完成）**：`scripts/` 与 `systemd/` 已在本仓库版本控制（含 health-check 的告警环境变量模板）；若想让家机 `~/Files/scripts/` 与仓库实时同步，把两者符号链接起来即可，迁移 / 回滚直接用 git。
- **SEO 与性能**：sitemap 已生成但没主动提交到搜索引擎；robots.txt 可优化；图片可加 `loading="lazy"` 和 `width/height` 防 CLS。静态站点性能评测见 [Lighthouse 实战](/posts/lighthouse-evaluation/)。
- **真正自托管的服务**：隐私统计 Umami、密码库 Vaultwarden——完全自托管、数据归己，顺延"本地托管"洁癖。这些需要家机起服务 + Tunnel 暴露，尚未实施。
- **正式域名**：等哪天觉得 `wangzifan396-wzf.github.io/linux-projects/` 太长，可以买个短域名 CNAME 到 GitHub Pages，但目前免费子域够用。

## 七、整体部署流程图

最后补一张"写完一篇文章到上线"的完整流程，是日常最常用的：

{{< mermaid >}}
flowchart LR
    A["写 .md<br/>front matter<br/>date 早于当前"] --> B["hugo --minify<br/>--baseURL=生产"]
    B --> C{"本地构建<br/>页数 +N?"}
    C -->|"否, date 是未来"| A
    C -->|"是"| D["./push.sh 'msg'<br/>add+commit+push<br/>SSH 443 重试 5 次"]
    D --> E["GitHub Actions<br/>自动 hugo 构建<br/>~90s"]
    E --> F["curl 固定 URL<br/>HTTP=200 + 标题"]
    F -->|"失败"| D
    F -->|"成功"| G["✅ 上线"]

    style A fill:#fff3e0,stroke:#e65100
    style B fill:#e8f5e9,stroke:#2e7d32
    style D fill:#e3f2fd,stroke:#1565c0
    style E fill:#f3e5f5,stroke:#6a1b9a
    style G fill:#c8e6c9,stroke:#2e7d32
{{< /mermaid >}}

这个流程现在已经跑通十几次，每次写完一篇文章从 push 到上线验证 ~100s，失败率几乎为 0（push.sh 重试 5 次覆盖了 WARP 抖动）。

## 尾巴

这套栈不是一天搭起来的，是 18 篇文章逐步长出来的。最早只想"用 Cloudflare Tunnel 把 Hugo 暴露到公网"，写着写着发现国内访问 GitHub 抽风得先解决代理，代理解决了发现 push 还得绕 443 端口，推上去了发现 Pages 子路径会让主题链接失效，链接修好了发现没监控不踏实，监控跑起来发现没备份不放心，备份稳了又想"在外也能摸回家机"于是加了 Tailscale……每一步都是上一步逼出来的。

这是工程的真实样子：**不是一开始设计好架构，而是遇到一个解决一个，最后回头看才发现自己搭出了一个栈**。写这篇总结的时候我才第一次把所有零件摆在一起看，发现居然挺整齐——四个"零"贯穿每一层，systemd --user 一套体系管所有服务，bash 脚本接住所有运维缺口，Tailscale 补上私有访问。这不是巧合，是约束倒逼出来的：家用、没钱、没公网 IP、不想给 root，能用的工具就那几个，反而促成了连贯的设计。

如果你也想搭一套类似的，按下面顺序读最快：

1. [零成本搭一个家用 Linux 自托管栈](/posts/linux-home-server-zero-cost/) — 全过程总览
2. [Cloudflare Tunnel 实战](/posts/cloudflare-tunnel-guide/) — 公网入口
3. [systemd --user 工作流](/posts/systemd-user-workflow/) — 服务管理基础
4. [GitHub Pages 自动部署](/posts/github-pages-deploy/) — 固定 URL
5. [用 wireproxy + WARP 解决国内访问](/posts/warp-wireproxy-proxy/) — 代理通道
6. [GitHub SSH 规范工作流](/posts/ssh-workflow/) — 推送通道
7. [轻量健康检查](/posts/health-check/) — 监控
8. [家用 Linux 主机备份策略](/posts/backup-strategy/) — 备份
9. [用 Tailscale 把家机变成随身私密网](/posts/tailscale-private-mesh/) — 私有访问层

剩下 5 篇（[博客技术栈升级](/posts/blog-stack-upgrade/)、[在 Linux 上自托管 Gitea](/posts/gitea-self-host/)、[Ubuntu 24.04 中文输入法折腾记](/posts/ubuntu-ibus-pinyin/)、[第一篇：博客上线了](/posts/hello/)、[给博客加自动化巡检 CI](/posts/blog-ci-automation/)）按需读。

栈还会继续长，新的文章会继续写。这篇只是阶段性总结，不是终态。
