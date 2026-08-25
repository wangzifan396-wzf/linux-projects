---
title: "GitHub SSH 规范工作流：ed25519 key + 443 端口绕封锁 + push.sh 自动重试"
date: 2026-08-25T14:00:00+08:00
draft: false
tags: ["SSH", "GitHub", "ed25519", "git", "运维"]
categories: ["运维"]
summary: "国内 Linux 主机访问 GitHub 抽风——22 端口常被封、HTTPS 时好时坏。这篇记下用 ed25519 SSH key + ssh.github.com:443 端口绕过封锁，建立一条稳定、安全、可复用的推送通道，配套 push.sh 自动重试应对抖动，PAT 与 SSH 认证面解耦。"
---

国内访问 GitHub 抽风是老问题：22 端口常被封、HTTPS 时好时坏、`git push` 经常 `Connection closed`。最不规范的处理是把 PAT（Personal Access Token）拼进 remote URL——这样 PAT 会泄露到 `.git/config`、`ps aux`、shell history，谁拿到这台机器谁就能 push。

这篇记下一条更稳、更规范的工作流：**ed25519 SSH key + ssh.github.com:443 端口绕封锁 + push.sh 自动重试 + PAT 仅用于 API**。一次配置、长期可用、认证面解耦。配套文档在 [docs/ssh-workflow.md](https://github.com/wangzifan396-wzf/linux-projects/blob/main/docs/ssh-workflow.md)，博文是它的可读版本。

## 一、设计决策

| 维度 | 选择 | 理由 |
| --- | --- | --- |
| 密钥类型 | **ed25519** | 比 RSA 更短更快更安全，GitHub 官方推荐 |
| 密钥用途 | **专用 GitHub**，单独文件 | 不复用通用 key，泄露面更小，便于轮换 |
| 密钥密码 | 空密码 | 个人家用主机，权衡自动化便利；多人共用主机请加密码并配合 `ssh-agent` |
| 传输端口 | **ssh.github.com:443** | 国内 22 端口常被封，443 与 HTTPS 共用几乎不会被封 |
| 认证方式 | **SSH key**，弃用 PAT-in-URL | PAT 写进 remote URL 会泄露到 `.git/config`、`ps`、shell history |
| PAT 保留 | 仍保留 `repo+workflow` scope | 仅用于 API 自动化（建仓、加 secret、查 Actions 状态等），不再用于 `git push` |

> 为什么不用 `https://` + credential helper？credential helper（store/cache）虽然不把 PAT 写进 remote URL，但仍依赖 PAT，且 PAT 有过期和 scope 风险。SSH key 是独立认证面，与 HTTPS 通道解耦，更稳。

## 二、整条链路

{{< mermaid >}}
graph LR
    A[git push origin main] --> B[git remote URL<br/>git@github.com:user/repo.git]
    B --> C[~/.ssh/config<br/>Host github.com → ssh.github.com:443]
    C --> D[SSH over 443<br/>国内 22 被封时仍通]
    D --> E[GitHub SSH 服务器]
    E --> F{公钥匹配?}
    F -->|是| G[认证成功 推送成功]
    F -->|否| H[Permission denied publickey]
    G --> I{网络抖动?}
    I -->|是| J[push.sh 自动重试 5 次]
    I -->|否| K[完成]
    J --> K
    H --> L[检查公钥是否添加 + 私钥路径]
{{< /mermaid >}}

关键三段：

1. **认证面**：SSH key（ed25519 私钥 + 公钥添加到 GitHub 账号）
2. **传输面**：`ssh.github.com:443`（绕开 22 端口封锁）
3. **韧性面**：`push.sh` 自动重试 5 次（应对 443 偶发抖动）

## 三、生成 ed25519 密钥

```bash
# 用 GitHub noreply 邮箱作为 comment，避免泄露真实邮箱
ssh-keygen -t ed25519 \
  -C "296115900+wangzifan396-wzf@users.noreply.github.com" \
  -f ~/.ssh/id_ed25519_github \
  -N ""
```

参数说明：

- `-t ed25519`：算法
- `-C "..."`：comment，仅用于人眼区分，用 `<user_id>+<username>@users.noreply.github.com` 格式
- `-f ~/.ssh/id_ed25519_github`：**专用文件名**，不覆盖默认 `id_ed25519`，便于多账号隔离
- `-N ""`：空密码（个人主机自动化；多人主机请改成交互输入密码）

生成后产物：

```
~/.ssh/id_ed25519_github       # 私钥，权限必须 600，绝不外传
~/.ssh/id_ed25519_github.pub   # 公钥，可公开
```

## 四、把公钥添加到 GitHub 账号

### 方式 A：网页手动添加（推荐，一次性）

1. 打开 <https://github.com/settings/ssh/new>
2. **Title**：填一个能识别来源的名字，例如 `wzf-ubuntu-home`
3. **Key type**：`Authentication Key`
4. **Key**：粘贴 `~/.ssh/id_ed25519_github.pub` 整行内容
5. 点 **Add SSH key**

### 方式 B：API 自动添加（需要 `admin:public_key` scope 的 PAT）

```bash
PUBKEY=$(cat ~/.ssh/id_ed25519_github.pub)
curl -X POST \
  -H "Authorization: token <PAT_WITH_ADMIN_PUBLIC_KEY>" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/user/keys \
  -d "{\"title\":\"wzf-ubuntu-home\",\"key\":\"$PUBKEY\"}"
```

> 注意：`repo` scope **不包含** `admin:public_key`，调用会返回 `404`。想用 API 自动加，生成 PAT 时必须单独勾选 `admin:public_key`。

### 方式 C：`gh` CLI（如果已 `gh auth login`）

```bash
gh ssh-key add ~/.ssh/id_ed25519_github --title wzf-ubuntu-home --type authentication
```

## 五、写 `~/.ssh/config`（443 端口绕封锁）

```ssh-config
# === GitHub SSH 规范配置 ===
# 走 ssh.github.com:443 端口，绕开国内 22 端口封锁，更稳定
Host github.com
    HostName ssh.github.com
    Port 443
    User git
    IdentityFile ~/.ssh/id_ed25519_github
    IdentitiesOnly yes
    AddKeysToAgent yes

# 兼容性别名：直接用 github-ssh 也能连（备用）
Host github-ssh
    HostName ssh.github.com
    Port 443
    User git
    IdentityFile ~/.ssh/id_ed25519_github
    IdentitiesOnly yes
```

关键点：

- `HostName ssh.github.com` + `Port 443`：GitHub 官方提供的"SSH over 443"通道，国内几乎不会被封
- `IdentitiesOnly yes`：只用指定 key 尝试，避免把其他 key 也发给服务器（既泄露又触发 rate limit）
- `AddKeysToAgent yes`：首次用自动加入 agent

权限：

```bash
chmod 600 ~/.ssh/config ~/.ssh/id_ed25519_github ~/.ssh/id_ed25519_github.pub
chmod 700 ~/.ssh
```

## 六、切换 git remote 为 SSH URL

```bash
cd /path/to/repo
git remote set-url origin git@github.com:<user>/<repo>.git

# 验证
git remote -v
# 期望输出：
# origin  git@github.com:wangzifan396-wzf/linux-projects.git (fetch)
# origin  git@github.com:wangzifan396-wzf/linux-projects.git (push)
```

仓库级身份配置（推荐用 noreply 邮箱，不泄露真实邮箱）：

```bash
git config user.name  "wangzifan396-wzf"
git config user.email "296115900+wangzifan396-wzf@users.noreply.github.com"
```

## 七、测试与验证

```bash
# 1. 连通性测试
ssh -T git@github.com
# 首次连接会提示是否信任 host fingerprint，输入 yes
# 成功输出：Hi wangzifan396-wzf! You've successfully authenticated...

# 2. 拉取测试
git ls-remote origin
# 能列出 refs 即认证 + 传输全通

# 3. 推送测试（一次空 commit）
git commit --allow-empty -m "test: ssh push pipeline"
git push origin main
# 能推上去即整条链路 OK
```

如果 `ssh -T` 卡住或超时，说明 443 通道也不通，参考第 9 节排障。

## 八、push.sh 自动重试（应对网络抖动）

国内 443 通道偶尔也会抖。写个自动重试脚本，让 `git push` 默认带 5 次重试：

```bash
#!/bin/bash
# push.sh
cd "$(dirname "$0")" || exit 1
MSG="${1:-update: $(date '+%Y-%m-%d %H:%M:%S')}"

git add .
git commit -m "$MSG" || true

for i in 1 2 3 4 5; do
    echo "[push] 第 $i 次尝试..."
    if git push origin main 2>&1; then
        echo "[push] 成功！"
        exit 0
    fi
    sleep 2
done
echo "[push] 5 次都失败，稍后再试。"
exit 1
```

用法：

```bash
./push.sh                    # 默认 commit 信息
./push.sh "改了某功能"        # 自定义 commit 信息
```

> 本仓库 `~/Files/blog/push.sh` 就是这个脚本，每次博文改完直接 `./push.sh "msg"`，5 次内能成功就 push 上去。比每次手动敲 `git add . && git commit && git push` 然后撞到失败再重试省事得多。

如果给私钥设了密码，开机后用一次 `ssh-add`，之后免输密码：

```bash
ssh-add ~/.ssh/id_ed25519_github
```

GNOME 用户可在 `~/.config/autostart/` 加一个 `.desktop` 让 `ssh-agent` 开机自启。

## 九、故障排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `ssh -T` 超时 | 443 也被临时抖掉 | 等 1-2 分钟重试；或 `ssh -T -o ConnectTimeout=10 git@github.com` |
| `Permission denied (publickey)` | 公钥没加到 GitHub / 私钥路径错 | `ssh -vT git@github.com` 详细日志，确认 `Offering public key: ~/.ssh/id_ed25519_github` |
| `fatal: remote origin already exists` | remote 重复设置 | `git remote remove origin` 后再 `set-url` |
| `kex_exchange_identification` | 中途有代理/防火墙干扰 | 关闭其他代理软件（如 steam302 残留 hosts 条目） |
| 推送时 `Connection closed` | 443 偶发抖动 | 用 `push.sh` 自动重试 |
| GitHub 要求输密码但 SSH 不该有密码 | 把 HTTPS 误当 SSH | 确认 `git remote -v` 是 `git@github.com:...` 不是 `https://...` |

详细日志：

```bash
ssh -vT git@github.com           # 调试连接
GIT_SSH_COMMAND="ssh -vvv" git push origin main   # 调试 git 用 ssh
```

首次连接 GitHub 会把它的指纹写入 `~/.ssh/known_hosts`。若 GitHub 轮换了 host key 报 `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED`，先核对官方指纹再 `ssh-keygen -R ssh.github.com` 清掉旧条目。GitHub 官方 Ed25519 指纹见 <https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints>。

## 十、安全注意事项

1. **私钥绝不外传**：`~/.ssh/id_ed25519_github` 权限保持 `600`，不进 git，不上云盘公开分享
2. **noreply 邮箱**：git commit 用 `<user_id>+<username>@users.noreply.github.com`，不泄露真实邮箱
3. **PAT 与 SSH 分离**：PAT 只用于 API 自动化（且 scope 最小化），`git push` 走 SSH，两条认证面解耦
4. **定期轮换**：建议每 6-12 个月轮换一次 SSH key（生成新 key、删旧 key、改 `IdentityFile`）
5. **多账号隔离**：不同 GitHub 账号用不同 `-f` 文件名，`~/.ssh/config` 里用 `Host` 别名区分
6. **借用主机前**：`ssh -T git@github.com` 确认当前身份是自己的账号，再 push

## 十一、设计取舍

1. **ed25519 而非 RSA**：更短（私钥只 ~400 字节）、更快、安全等价更高，GitHub 官方推荐。
2. **443 端口而非 22**：国内 22 端口常被运营商封锁，443 与 HTTPS 共用，几乎不会被封。
3. **PAT 不进 remote URL**：避免 PAT 泄露到 `.git/config`、`ps`、shell history，认证面与传输面解耦。
4. **push.sh 重试 5 次**：443 偶发抖动靠自动重试化解，不用每次手动重敲。
5. **专用 key 文件而非默认 id_ed25519**：方便多账号隔离、轮换、撤权。

> 本机当前就用这套——`git push` 走 `ssh.github.com:443` + `~/.ssh/id_ed25519_github`，PAT 只用来查 GitHub Actions 状态、查部署结果，从不进 `git remote`。博文推送（包括这篇本身）都是 `./push.sh "msg"` 搞定。
