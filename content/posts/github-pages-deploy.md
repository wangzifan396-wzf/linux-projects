---
title: "GitHub Pages 自动部署：从临时隧道到固定 URL（含子路径踩坑）"
date: 2026-08-25T13:30:00+08:00
draft: false
tags: ["GitHub Pages", "GitHub Actions", "Hugo", "CI/CD"]
categories: ["建站"]
summary: "把 Hugo 博客从 cloudflared 临时隧道（URL 每次重启都变）迁移到 GitHub Pages 固定 URL，用 Actions 自动构建部署，记录项目仓库 baseURL 含子路径时 PaperMod 主题链接全部失效的踩坑与修复。"
---

前面几篇都用 cloudflared quick tunnel 把本机 Hugo server 暴露到公网。能用，但有个硬伤：**quick tunnel 的 URL 每次重启 cloudflared 都变**。今天 `xxx-aaa.trycloudflare.com`，重启后变 `yyy-bbb.trycloudflare.com`——分享出去的链接隔天 404，搜索引擎收录了也白搭，RSS 订阅者拿到的 URL 过几天就连不上。

GitHub Pages 给项目仓库的固定 URL `https://<user>.github.io/<repo>/`，永不改变。本机实时预览仍用 cloudflared tunnel（写文章看 draft），生产固定入口走 Pages。

## 一、方案选型

| 方案 | URL | 自定义域名 | 构建 | 国内访问 | 私有仓库 |
| --- | --- | --- | --- | --- | --- |
| **GitHub Pages** | `<user>.github.io/<repo>/` | 支持 | Actions | 中等 | 公开免费，私有要 Pro |
| Cloudflare Pages | `<proj>.pages.dev` | 支持 | 内置 | 好（边缘） | 支持 |
| Vercel | `<proj>.vercel.app` | 支持 | 内置 | 差（被墙频繁） | 支持 |
| Netlify | `<proj>.netlify.app` | 支持 | 内置 | 差 | 支持 |

选 GitHub Pages：仓库本来就在 GitHub（零额外账号）、Actions 流程透明可控、`github.io` 域"看起来正经"、国内访问比 Vercel 强。本机 cloudflared tunnel 可作国内加速备份。

## 二、整体流程

{{< mermaid >}}
graph TD
    A[本机写 Markdown] --> B[git push origin main]
    B --> C[GitHub 触发 Actions]
    C --> D[checkout + setup hugo extended]
    D --> E[configure-pages 输出 base_url]
    E --> F["hugo --minify --gc --baseURL base_url"]
    F --> G[upload-pages-artifact]
    G --> H[deploy-pages 部署]
    H --> I[Pages 固定 URL 上线]
    I --> J[访客访问固定 URL]
{{< /mermaid >}}

关键设计：Actions 里用 `configure-pages` 输出的 `base_url` 覆盖 hugo.toml 的 baseURL，仓库改名或迁移到 `<user>.github.io` 仓库时无需改 hugo.toml。

## 三、开 Pages + 写 workflow

### 3.1 用 API 开 Pages（build_type=workflow）

GitHub Pages 两种部署方式：
- **老式**：部署到 `gh-pages` branch，Pages source = branch
- **新式（推荐）**：`build_type=workflow`，Pages source = Actions workflow，用 `actions/deploy-pages` 部署 artifact

新式不用维护额外 branch，仓库更干净。开 Pages：

```bash
# 先 GET 检查是否已开
curl -sS -o /tmp/pages.json -w "%{http_code}" \
  -H "Authorization: token $PAT" \
  https://api.github.com/repos/<owner>/<repo>/pages

# 404 就 POST 开，200 就 PUT 更新
curl -X POST \
  -H "Authorization: token $PAT" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/<owner>/<repo>/pages \
  -d '{"build_type":"workflow"}'
```

响应里 `html_url` 就是固定 URL。

### 3.2 workflow

`.github/workflows/hugo.yml`：

```yaml
name: Deploy Hugo to GitHub Pages

on:
  push:
    branches: [main]
    paths: ['content/**','assets/**','layouts/**','themes/**','hugo.toml','.github/workflows/hugo.yml']
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: pages
  cancel-in-progress: true   # 新 push 取消旧部署

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 1 }
      - name: Setup Hugo
        uses: peaceiris/actions-hugo@v3
        with:
          hugo-version: '0.165.0'
          extended: true
      - name: Setup Pages
        id: pages
        uses: actions/configure-pages@v5
      - name: Build with Hugo
        env:
          HUGO_ENV: production
        run: hugo --minify --gc --baseURL "${{ steps.pages.outputs.base_url }}/"
      - uses: actions/upload-pages-artifact@v3
        with: { path: ./public, retention-days: 7 }

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - id: deployment
        uses: actions/deploy-pages@v4
```

几个关键点：
- `permissions: pages: write, id-token: write` —— deploy-pages 必需
- `concurrency.cancel-in-progress: true` —— 连续 push 时只跑最后一次
- `configure-pages` 输出 `base_url`，build step 用 `--baseURL` 覆盖 hugo.toml
- `upload-pages-artifact` 的 `retention-days: 7` —— artifact 过期自动清理省存储
- deploy job 的 `environment: github-pages`，GitHub 会自动创建这个 environment

## 四、子路径踩坑（重点）

第一次部署跑成功，HTML 都返回了，但点开发现 **菜单链接 404**。

### 4.1 现象

首页 HTML 里：

```html
<!-- 菜单链接（错） -->
<a href="https://wangzifan396-wzf.github.io/posts/">文章</a>
                              ↑ 少了 /linux-projects/ 子路径

<!-- hero CTA 按钮（对） -->
<a href="https://wangzifan396-wzf.github.io/linux-projects/posts/">📚 浏览文章</a>

<!-- favicon（错） -->
<link rel="icon" href="https://wangzifan396-wzf.github.io/favicon.ico">
                                              ↑ 少了子路径

<!-- stylesheet（对） -->
<link href=".../linux-projects/assets/css/stylesheet.xxx.css">
```

有的对有的错——说明不是 baseURL 配错，而是**不同模板用了不同函数处理 URL**。

### 4.2 根因：Hugo URL 函数行为差异

| 函数 | 输入 `/posts/`（以 / 开头） | 输入 `posts/`（相对） |
| --- | --- | --- |
| `absURL` / `absLangURL` | `https://host/posts/`（**丢 baseURL 子路径**） | `https://host/<baseURL子路径>/posts/`（拼接 baseURL） |
| `RelPermalink`（资源管道） | 自动处理 baseURL | 自动处理 baseURL |
| canonifyURLs（Markdown 内） | `https://host/<baseURL子路径>/posts/`（对） | 同 |

> 关键：**absURL 对 `/` 开头的输入，会从 host 根开始拼，丢掉 baseURL 里的子路径**。这是 Hugo 设计行为，不是 bug——`/foo` 在 web 语义里就是"host 根下的 foo"。

PaperMod 主题里：
- `header.html` 渲染 menu：`.URL | absLangURL` ← 错的来源
- `head.html` 渲染 favicon：`site.Params.assets.favicon | absURL` ← 错的来源
- `social_icons.html` 渲染社交图标：`.url | safeURL`（原样输出，相对路径在不同页面深度会解析错）
- `homeInfoParams.Content` 是 Markdown：走 Goldmark + canonifyURLs ← 对的来源
- 资源管道（`$stylesheet.RelPermalink`）：Hugo 自动处理 ← 对的来源

### 4.3 修复

三处改动：

**1. hugo.toml menu url 改相对（去掉开头 `/`）**：

```toml
[[menu.main]]
  identifier = 'posts'
  name = '文章'
  url = 'posts/'   # 不是 '/posts/'
  weight = 10
```

**2. hugo.toml favicon + rss url 改相对**：

```toml
[params.assets]
  favicon = 'favicon.ico'   # 不是 '/favicon.ico'

[[params.socialIcons]]
  name = 'rss'
  url = 'index.xml'   # 不是 '/index.xml'
```

**3. 覆盖 social_icons.html**（`layouts/_partials/social_icons.html`），用 `absURL` 替代 `safeURL`：

```go-html-template
<a href="{{ trim .url " " | absURL | safeURL }}" target="_blank" rel="noopener noreferrer me">
```

为什么需要覆盖？原模板 `safeURL` 原样输出，相对路径 `index.xml`：
- 首页（`/linux-projects/`）→ 浏览器解析成 `/linux-projects/index.xml` ✓
- 文章页（`/linux-projects/posts/hello/`）→ 解析成 `/linux-projects/posts/hello/index.xml` ✗

用 `absURL` 让相对路径在任意页面深度都拼接 baseURL。`absURL` 对带 scheme 的输入（`https://`、`mailto:`）原样返回，不影响外链。

## 五、验证

push 后 Actions 跑 ~90 秒，公网验证全路径 HTTP=200：

| 路径 | HTTP |
| --- | --- |
| `/linux-projects/` | 200 |
| 7 篇文章 `/linux-projects/posts/*/` | 全 200 |
| `/linux-projects/about/` `/archives/` `/tags/` `/search/` | 全 200 |
| `/linux-projects/index.xml` (RSS) | 200 |
| `/linux-projects/sitemap.xml` `index.json` | 200 |

RSS 里所有 `<link>` 都含 `/linux-projects/` 子路径，订阅者拿到的 URL 永久有效。

## 六、设计取舍

1. **Pages 是生产入口，cloudflared tunnel 是本机实时预览**：前者固定 URL，后者看 draft。职责分离。
2. **Actions 用 configure-pages 输出的 base_url**：不 hardcode URL，仓库迁移无痛。
3. **覆盖 social_icons.html 而非改主题**：改动在 `layouts/_partials/`，主题升级零冲突。
4. **公开仓库免费**：Pages 对公开仓库免费，博客源码本来就开源，公开是预期。

## 七、成果

| 项 | 状态 |
| --- | --- |
| 固定公网 URL | ✅ `wangzifan396-wzf.github.io/linux-projects/` |
| push 到 main 自动部署 | ✅ ~90 秒构建部署 |
| 菜单/资源/RSS 子路径正确 | ✅ |
| 本机实时预览（含 draft） | ✅ cloudflared tunnel 保留 |
| RSS/sitemap/OG meta 子路径 | ✅ |

> 这篇博文本身就是一个"活的演示"——你现在看到的固定 URL，就是这次部署的产物。
