---
title: "给博客加自动化巡检 CI：Hugo 构建 + 内链审计 + 死链检查"
date: 2026-08-27
categories: ["运维", "自托管"]
tags: ["Hugo", "CI", "GitHub Actions", "内部链接", "质量保障"]
draft: false
---

我家这个博客之前的质量保障，全靠手：改完博文跑一遍 `hugo` 看能不能编过，偶尔手动 grep 一下内链有没有断。问题在于——人是会忘的。上一轮巡检就发现，本地化改造后好几篇博文还残留着 jsdelivr CDN 引用，读者照旧文会踩超时坑；还有两篇博文互相之间零内链，导航和 SEO 都吃亏。

与其靠记忆力，不如把巡检交给机器。这篇记录我怎么给这个零成本自托管栈加上**自动化巡检 CI**：每次 push 自动跑 Hugo 构建、内链审计、外链死链检查。

## 为什么是这三件事

1. **Hugo 构建必须通过**——最基础的门禁，模板或 front matter 写错立刻暴露。
2. **内链审计**——博文之间互相引用（`/posts/<slug>/`）是我这个站的内部导航和 SEO 命脉。出现「指了个不存在的 slug」这种死链，必须拦下；出现「没有任何其它博文链到我」的孤立博文，至少得警告。
3. **外链死链检查**——引用了外部资源（文档、仓库）时间长了会 404，顺手扫一遍。

前两项是**硬门槛**（CI 红了就不让合并/部署），外链检查是**顾问项**（只报不拦，因为外网偶发抖动不该阻断部署）。

## 内链审计脚本

核心是一个不到 60 行的 bash 脚本 `scripts/internal-link-audit.sh`：

- 收集 `content/posts/*.md` 的文件名作为「合法 slug 集合」；
- 用 `grep -nonE "/posts/[a-zA-Z0-9_-]+/"` 抽出每篇博文里的内链引用；
- 引用指向的 slug 不在合法集合里 → **死链，直接失败**；
- 统计每篇博文的「来自其它博文的入站链接数」，为 0 → **孤立，仅警告**。

本地跑一行就能查：

```bash
bash scripts/internal-link-audit.sh content/posts
# 有效博文: 17  死链: 0  孤立: 0
# ✅ 内链审计通过
```

把「孤立」设计成警告而非失败，是有意的：将来新写篇博文还没来得及互链时，CI 不该直接红，但会在日志里提醒你补链接。死链则是零容忍——指向不存在的页面是实打实的 bug。

## CI 工作流

`.github/workflows/ci.yml` 在 push/PR 到 `main` 时触发，三步一气呵成：

```yaml
jobs:
  quality:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: peaceiris/actions-hugo@v3
        with:
          hugo-version: '0.165.0'
          extended: true
      - run: hugo --minify --gc          # 硬门槛：构建必须过
      - run: bash scripts/internal-link-audit.sh content/posts   # 硬门槛：无死链
      - uses: lycheeverse/lychee-action@v2   # 顾问：外链死链只报不拦
        continue-on-error: true
```

注意它和既有的 `hugo.yml`（负责部署到 GitHub Pages）是**两个独立工作流**：部署只在 `content/`、`layouts/`、`hugo.toml` 等变化时跑，CI 则在每次 push 都跑质量校验。两者并行不打架。

## 收益

这套门禁直接把我前几轮手动做的事固化成了自动关卡：

- 以后再改某个组件（比如又动 mermaid/KaTeX 加载方式），只要忘了同步博文、留下死链，CI 当场拦下，**不会再出现「博文与实现漂移」**——这正是我这个栈最在意的工程纪律；
- 新博文默认会被审计是不是孤立的，逼着我把内链织密，导航和 SEO 自然变好；
- 外链悄悄 404 也能被 lychee 扫出来，人工复查即可。

零成本、零外部依赖，纯 GitHub Actions 算力。

## 后续规划（尚未实施）

巡检 CI 只是「质量门禁」这一环。顺着「让家机更省心」的思路，下面几件我已经想清楚但还没落地，留作下一批：

- **监控告警闭环**：现在 `scripts/health-check.sh` 只写日志，已预留 Telegram / Webhook 通知钩子（设好 `TG_BOT_TOKEN`、`TG_CHAT_ID` 即生效），服务真挂了能主动推到手机；
- **隐私友好访问统计 Umami**：完全自托管，通过 Cloudflare Tunnel 暴露，不追踪用户，贴合「本地托管」洁癖；
- **Vaultwarden 自托管密码库**、**Tailscale 组网**（远程任意访问家机，不止 web）；
- 这些一旦发生，对应博文会同步更新，绝不「文档与实现两张皮」。

相关：[家用 Linux 自托管栈全景](/posts/self-hosted-stack-overview/)、[博客技术栈升级：KaTeX / Mermaid / Giscus](/posts/blog-stack-upgrade/)。
