---
title: "博客技术栈升级：给 PaperMod 加上 KaTeX / Mermaid / Giscus 与首屏 Hero"
date: 2026-08-25T01:50:00+08:00
draft: false
math: true
tags: ["Hugo", "PaperMod", "博客", "KaTeX", "Mermaid", "Giscus"]
categories: ["建站"]
summary: "在一台 Linux 家用主机上，给 PaperMod 博客补齐数学公式、流程图、评论系统、首屏 Hero 和移动端响应式，记录全流程实现与设计取舍。"
---

前面几篇已经把"零成本搭站"的主线讲完了：Hugo 生成静态页 + Cloudflare Tunnel 暴露公网。这次把博客本身从"能看"升级到"好用"——补齐技术博客该有的几样东西：**数学公式、流程图、评论、首屏、移动端**。

> 这篇本身就是一个"活的演示"：你能看到的公式渲染、流程图、评论区，都是这次升级的产物。

## 一、整体架构

升级前后没有动主线，只是在 PaperMod 提供的扩展点上叠加功能：

{{< mermaid >}}
graph LR
    A[Markdown 正文] --> B[Hugo + Goldmark]
    B --> C{扩展点判断}
    C -->|front matter math:true| D[KaTeX auto-render]
    C -->|mermaid shortcode 调用| E[Mermaid.js 懒加载]
    C -->|single.html comments 参数| F[Giscus iframe]
    D --> G[渲染后 HTML]
    E --> G
    F --> G
    G --> H[Cloudflare Tunnel]
    H --> I[访客浏览器]
{{< /mermaid >}}

关键设计：**所有扩展都用"按需加载"**——只有用到数学公式的文章才加载 KaTeX（~280KB），只有含 Mermaid 图的文章才加载 Mermaid（~2MB），避免每篇文章都背一堆脚本。

## 二、KaTeX 数学公式

技术博客经常要写公式。方案选型对比：

| 方案 | 体积 | 渲染速度 | 备注 |
| --- | --- | --- | --- |
| KaTeX | ~280KB | 快（服务端渲染优先） | 本文采用 |
| MathJax | ~1MB | 慢 | 兼容性更好但偏重 |

实现方式：在 `layouts/_partials/extend_head.html` 里按需加载 KaTeX CSS + JS + auto-render：

```go-html-template
{{- $hasMath := or (.Page.HasShortcode "math") (.Param "math") -}}
{{- if $hasMath -}}
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"
    onload="renderMathInElement(document.body, {
        delimiters: [
            {left: '$$', right: '$$', display: true},
            {left: '\\[', right: '\\]', display: true},
            {left: '$', right: '$', display: false},
            {left: '\\(', right: '\\)', display: false}
        ],
        throwOnError: false,
        ignoredTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code']
    });"></script>
{{- end -}}
```

文章 front matter 标 `math: true` 即触发。下面是渲染效果。

行内公式：质能方程 $E = mc^2$，欧拉公式 $e^{i\pi} + 1 = 0$。

块级公式——贝叶斯定理：

$$
P(A \mid B) = \frac{P(B \mid A)\,P(A)}{P(B)}
$$

矩阵——旋转矩阵：

$$
R(\theta) = \begin{pmatrix} \cos\theta & -\sin\theta \\ \sin\theta & \cos\theta \end{pmatrix}
$$

积分——高斯分布的归一化：

$$
\int_{-\infty}^{\infty} e^{-x^2/2}\,dx = \sqrt{2\pi}
$$

> 小坑：`$` 符号在正文里很常见（比如"花了 $5"），所以**不能全局开 KaTeX**——必须用 `math: true` 按页开启，否则普通文章里所有 `$` 都会被误解析。

## 三、Mermaid 流程图

技术博客画架构图、时序图很常见。Mermaid 用纯文本描述图，比贴截图方便维护。

实现：写一个 `layouts/_shortcodes/mermaid.html`：

```go-html-template
<div class="mermaid">
{{ .Inner | safeHTML }}
</div>
```

然后在 `extend_footer.html` 里加懒加载逻辑——只有页面含 `.mermaid` 元素且接近视口时，才动态注入 mermaid.js：

```js
var mermaidEls = document.querySelectorAll('.mermaid');
if (mermaidEls.length === 0) return;  // 无图直接返回，不加载 2MB 脚本

var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (e) {
        if (e.isIntersecting) { loadMermaid(); io.disconnect(); }
    });
}, { rootMargin: '200px 0px' });
mermaidEls.forEach(function (el) { io.observe(el); });
```

用法：在 Markdown 里调用 mermaid shortcode，闭合标签之间写 Mermaid 语法（`graph TD`、`sequenceDiagram` 等）。shortcode 包裹的内容会原样传给 Mermaid 渲染成图。

效果：

{{< mermaid >}}
graph TD
    A[写文章] --> B{有公式?}
    B -->|是| C[front matter 标 math: true]
    B -->|否| D[不加载 KaTeX]
    C --> E[KaTeX 渲染]
    D --> F[零脚本开销]
{{< /mermaid >}}

时序图也支持——一次 Git SSH 推送的握手流程：

{{< mermaid >}}
sequenceDiagram
    participant U as 本机 git
    participant S as ssh.github.com:443
    participant G as GitHub
    U->>S: SSH 握手（443 端口，绕 22 封锁）
    S->>G: 转发
    G->>U: 验证 ed25519 公钥
    U->>G: git-receive-pack（推送对象）
    G->>U: 更新 refs/main 成功
{{< /mermaid >}}

> 选型说明：mermaid.js 体积 ~2MB，懒加载是必须的。`IntersectionObserver` 让图在接近视口时才加载，首屏零成本。

## 四、Giscus 评论

评论系统对比：

| 方案 | 后端 | App 安装 | 国内可用性 |
| --- | --- | --- | --- |
| Giscus | GitHub Discussions | 需要 | 中等（依赖 giscus.app） |
| utterances | GitHub Issues | 需要 | 中等 |
| Disqus | 自有 | 不需要 | 差（被墙） |
| Waline/Twikoo | 自托管/Workers | 不需要 | 好（可自托管） |

选 Giscus 的理由：基于 Discussions（比 Issues 干净）、GitHub 账号登录（读者无需再注册）、零本地后端、Cloudflare 边缘加速。

前置：仓库开启 Discussions（用 PAT 调 API 一行搞定）：

```bash
curl -X PATCH \
  -H "Authorization: token $PAT" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/wangzifan396-wzf/linux-projects \
  -d '{"has_discussions":true}'
```

然后拿 repoId 和 categoryId（GraphQL 查询）：

```bash
curl -X POST -H "Authorization: token $PAT" \
  -H "Content-Type: application/json" \
  https://api.github.com/graphql \
  -d '{"query":"{ repository(owner:\"...\",name:\"...\") { id discussionCategories(first:20){nodes{id name}} } }"}'
```

最后覆盖 `layouts/_partials/comments.html`（PaperMod 在 `single.html` 第 62 行已留好调用点）：

```html
<script src="https://giscus.app/client.js"
    data-repo="wangzifan396-wzf/linux-projects"
    data-repo-id="R_kgDOUC4WbQ"
    data-category="Announcements"
    data-category-id="DIC_kwDOUC4Wbc4DEGVM"
    data-mapping="pathname"
    data-theme="preferred_color_scheme"
    data-lang="zh-CN"
    data-loading="lazy"
    crossorigin="anonymous" async></script>
```

外加一段 JS 监听主题切换按钮（`#theme-toggle`），博客切暗色时同步把 Giscus 也切暗色，避免评论区"亮瞎眼"。

> 注意：Giscus 需要仓库 owner 在 [github.com/apps/giscus](https://github.com/apps/giscus) 安装 App 并授权给本仓库。这是 OAuth flow，无法用 PAT 自动化，是一次性网页操作。

## 五、首屏 Hero + 移动端

视觉层面在 `homeInfoParams.Content` 末尾加了一组 CTA 按钮：

```html
<div class="hero-cta">
<a class="button" href="/posts/">📚 浏览文章</a>
<a class="button" href="/about/">👋 关于我</a>
<a class="button" href="https://github.com/wangzifan396-wzf" target="_blank" rel="noopener">⭐ GitHub</a>
</div>
```

三个按钮用不同视觉权重：主按钮（实色填充）、次按钮（描边）、第三按钮（文字描边），形成层级。

首页大标题加了渐变文字色：

```css
.home-info .entry-header h1 {
    background: linear-gradient(135deg, var(--primary), var(--link-color));
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
}
```

移动端用 `@media (max-width: 768px)` 把字号、卡片内边距、按钮都收一档；`<420px` 时 CTA 按钮变全宽竖排。

## 六、成果清单

| 项 | 状态 |
| --- | --- |
| KaTeX 数学公式（按需加载） | ✅ |
| Mermaid 图表（懒加载 + 暗色适配） | ✅ |
| Giscus 评论（ Discussions + 主题同步） | ✅ 配置就绪，待装 App |
| 首屏 Hero CTA + 渐变标题 | ✅ |
| 移动端响应式（768/420 断点） | ✅ |
| 滚动条美化 + 回到顶部强化 | ✅ |
| Open Graph meta | ✅ |

## 七、设计取舍小结

1. **按需加载优先**：KaTeX / Mermaid 都不是全局加载，单篇文章 front matter 控制，零负担。
2. **扩展点不动主题**：所有改动都在 `layouts/_partials/` 和 `layouts/_shortcodes/`，主题本身零修改，升级主题不丢功能。
3. **CDN 用 jsdelivr**：国内相对稳；后续可换成本地资源或 Cloudflare Pages 托管，进一步可控。
4. **评论走 GitHub**：读者用 GitHub 账号登录评论，无需再搭后端，跟"零成本"主线一致。

下一篇会写 **SSH 规范工作流**（已经配好并测通），把 `git push` 从 PAT-in-URL 升级到 ed25519 + 443 端口的标准姿势。
