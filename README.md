# linux-projects

> 一台 Linux 家用主机上折腾出来的全部笔记 —— Hugo 静态博客 + Cloudflare Tunnel 自托管 + wireproxy WARP 代理 + Gitea 私有 Git，零域名、零备案、零端口、零成本。

本仓库既是**博客源码**（Hugo + PaperMod），也是**运维笔记**（`docs/` + `content/posts/`）。博客通过 GitHub Actions 自动构建并部署到 GitHub Pages，固定公网地址：

**https://wangzifan396-wzf.github.io/linux-projects/**

## 目录结构

```
linux-projects/
├── .github/workflows/hugo.yml   # GitHub Actions：push 到 main 自动构建部署
├── archetypes/                  # Hugo 文章模板
├── assets/css/extended/         # 自定义 CSS（覆盖在 PaperMod 之上）
├── content/
│   ├── posts/                   # 博文（Markdown）
│   ├── about.md                 # 关于页
│   ├── archives.md              # 归档页
│   └── search.md                # 搜索页
├── docs/                        # 独立技术文档（不进博客正文）
│   └── ssh-workflow.md          # GitHub SSH 规范工作流
├── layouts/
│   ├── _partials/               # 覆盖 PaperMod 的 partial（comments/extend_head/extend_footer 等）
│   └── _shortcodes/             # 自定义 shortcode（mermaid）
├── themes/PaperMod/             # 主题（git submodule 形式或直接内嵌）
├── hugo.toml                    # Hugo 配置
├── push.sh                      # 一键 commit + push（走 SSH，重试 5 次）
└── .gitignore
```

## 本地预览

需要 Hugo **extended** 版（用于 SCSS 编译），建议 ≥ 0.120：

```bash
# 安装（任选其一）
# 1. 从 https://github.com/gohugoio/hugo/releases 下载 hugo_extended_*_linux-amd64.tar.gz
# 2. 放到 ~/.local/bin/hugo 并 chmod +x

cd /path/to/linux-projects
hugo server -D --bind 127.0.0.1 --port 1313
# 浏览器打开 http://127.0.0.1:1313/
```

`-D` 启用 draft 草稿。生产构建：

```bash
hugo --minify
# 产物在 public/ 下
```

## 博文列表

按发布时间倒序：

| 日期 | 标题 | 关键词 |
| --- | --- | --- |
| 2026-08-25 | [家用 Linux 主机备份策略：rsync + systemd timer + 3-2-1 原则](content/posts/backup-strategy.md) | rsync, 备份, systemd-timer, Linux, 3-2-1 |
| 2026-08-25 | [systemd --user 工作流：家用 Linux 不给 sudo 也能让服务开机自启](content/posts/systemd-user-workflow.md) | systemd, Linux, 自托管, 服务管理, linger |
| 2026-08-25 | [GitHub Pages 自动部署：从临时隧道到固定 URL](content/posts/github-pages-deploy.md) | GitHub Pages, GitHub Actions, Hugo, CI/CD, 子路径 |
| 2026-08-25 | [用 wireproxy + Cloudflare WARP 解决国内访问 GitHub 等外国网站不稳](content/posts/warp-wireproxy-proxy.md) | wireproxy, WARP, SOCKS5, 用户态 WireGuard |
| 2026-08-25 | [在 Linux 上自托管 Gitea](content/posts/gitea-self-host.md) | Gitea, SQLite, Cloudflare Tunnel, systemd --user |
| 2026-08-25 | [博客技术栈升级：KaTeX / Mermaid / Giscus 与首屏 Hero](content/posts/blog-stack-upgrade.md) | Hugo, PaperMod, KaTeX, Mermaid, Giscus |
| 2026-08-23 | [Ubuntu 24.04 中文输入法折腾记](content/posts/ubuntu-ibus-pinyin.md) | Ubuntu, IBus, Wayland, fcitx, 搜狗 |
| 2026-08-23 | [零成本搭一个家用 Linux 自托管栈](content/posts/linux-home-server-zero-cost.md) | Linux, 自托管, Hugo, Cloudflare |
| 2026-08-23 | [Cloudflare Tunnel 实战：家用宽带没公网 IP 也能开站](content/posts/cloudflare-tunnel-guide.md) | Cloudflare, Tunnel, quick tunnel, 反向代理 |
| 2026-08-23 | [第一篇：博客上线了](content/posts/hello.md) | 博客, 记录 |

## 相关文档

- [GitHub SSH 规范工作流](docs/ssh-workflow.md) —— `ssh.github.com:443` 绕 22 端口封锁 + ed25519 密钥 + `~/.ssh/config` 配置 + `push.sh` 自动重试。

## 自动部署

仓库 push 到 `main` 分支后，[`.github/workflows/hugo.yml`](.github/workflows/hugo.yml) 会自动：

1. 拉取代码 + 安装 Hugo extended
2. `hugo --minify --baseURL "$GITHUB_PAGES_URL"` 构建
3. 上传 `public/` 为 Pages artifact
4. 调用 `actions/deploy-pages` 部署到 GitHub Pages

部署状态徽章：

[![Deploy Hugo to GitHub Pages](https://github.com/wangzifan396-wzf/linux-projects/actions/workflows/hugo.yml/badge.svg)](https://github.com/wangzifan396-wzf/linux-projects/actions/workflows/hugo.yml)

## 技术栈

| 层 | 选型 | 理由 |
| --- | --- | --- |
| 静态生成 | Hugo extended + PaperMod | 构建快、单二进制、主题简洁可扩展 |
| 数学公式 | KaTeX 0.16.11（按需加载） | 比 MathJax 轻、渲染快 |
| 图表 | Mermaid 10.9.1（懒加载 + IntersectionObserver） | 纯文本描述图，比截图易维护 |
| 评论 | Giscus（基于 GitHub Discussions） | 零后端、读者用 GitHub 账号登录 |
| 公网入口 | Cloudflare Tunnel（quick tunnel）+ GitHub Pages | 前者本机实时预览，后者固定 URL |
| 代理 | wireproxy + Cloudflare WARP | 用户态 WireGuard，不需要 root |
| 私有 Git | Gitea v1.27.2 + SQLite + systemd --user | 二进制部署、零依赖 |

## License

[MIT](LICENSE) © 2026 wangzifan396-wzf
