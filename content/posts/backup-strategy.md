---
title: "家用 Linux 主机备份策略：rsync + systemd timer + 3-2-1 原则"
date: 2026-08-25T14:30:00+08:00
draft: false
tags: ["rsync", "备份", "systemd-timer", "Linux"]
categories: ["运维"]
summary: "家用 Linux 主机上一堆自托管服务都跑得好好的，但 ~/Files 里的代码、博客源码、Gitea 仓库、SSH 密钥全在那块单块硬盘上——盘一坏全没。这篇记一下用 rsync 增量备份 + systemd --user timer 定时 + 3-2-1 原则的实战方案，外加可恢复性验证。"
---

家用 Linux 主机上跑着 wireproxy、Gitea、cloudflared、Hugo 博客，所有 systemd --user 服务都配齐了崩溃重启和开机自启——看起来很稳。但有一个隐患一直没处理：**所有数据都在一块盘上**。`~/Files` 里是博客源码、push.sh、各种二进制；`~/Files/gitea/` 里是 Gitea 的 SQLite 仓库；`~/.ssh/` 里是 GitHub 的 ed25519 私钥；`~/.config/systemd/user/` 里是所有 unit 文件。盘一坏，这些全没。

这篇记下家用场景的备份方案：**rsync 增量 + systemd --user timer 定时 + 3-2-1 原则 + 可恢复性验证**。

## 一、为什么不是 tar / cp / 云盘客户端

| 方案 | 增量 | 保留历史 | 定时 | 异地 | 适合 |
| --- | --- | --- | --- | --- | --- |
| **rsync + hardlink** | ✅（按 mtime/size 跳过） | ✅（每次一份快照） | 配 systemd timer | 自己搬盘 | 家用、大量小文件 |
| tar + cron | ❌（全量打包） | 手动留旧包 | cron | 自己搬盘 | 一次性归档 |
| restic / borg | ✅（去重） | ✅（多快照） | systemd timer | 支持 SSH 后端 | 中量数据、需要去重 |
| 云盘客户端（Dropbox 等） | ✅ | 看版本数 | 守护进程 | ✅ | 文档类、不想自己管 |
| dd 整盘镜像 | ❌（全量） | ❌ | cron | 自己搬盘 | 系统盘镜像 |

家用场景下我选 rsync + hardlink，原因：

1. **零新依赖**：rsync 系统自带，不用装 borg/restic。
2. **可读性**：备份目录就是普通目录，`ls` 能看、`cp` 能拷回去，不用 `borg mount` 这种工具。
3. **真增量**：rsync `--link-dest` 对比 mtime+size，没变的文件用硬链接指向上一份快照，不重复占空间。
4. **和现有架构一致**：定时走 systemd --user timer，不用单独装 cron 工具，和 wireproxy/gitea/cloudflared 一套体系管。

> 数据量更大的场景（>50GB、需要去重）建议上 restic，去重比 hardlink 节省更多。家用几 GB 文本+二进制，rsync 足够。

## 二、3-2-1 原则

备份的黄金法则 **3-2-1**：

- **3** 份数据（1 份原始 + 2 份备份）
- **2** 种介质（不同硬盘/不同设备，避免同批次故障）
- **1** 份异地（避免火灾/失窃/误操作整屋一起没）

家用场景落地：

| 份数 | 位置 | 介质 | 用途 |
| --- | --- | --- | --- |
| 1（原始） | 主机内置 SSD | 内置盘 | 在线使用 |
| 2（本地） | 外接 USB 移动硬盘 | 不同物理盘 | 快速恢复 |
| 3（异地） | Gitea 私有仓库 + GitHub 仓库 | 远程服务器 | 本地全没时兜底 |

代码和博客源码天然走异地（push 到 GitHub），所以异地那一份自动有了。**真正要做的是本地增量备份**——把 `~/Files` 和关键配置定时同步到外接硬盘。

## 三、备份什么、不备份什么

### 3.1 必备份

```
~/Files/                    # 博客源码、二进制、脚本、Gitea 数据
├── blog/                   # Hugo 源码（虽然 push 到 GitHub 但本地也有备份更稳）
├── gitea/                  # Gitea 数据（SQLite 仓库 + 配置）
├── proxy/                  # wireproxy 二进制 + 配置
└── docs/                   # 技术文档

~/.config/systemd/user/    # 所有 systemd --user unit 文件（服务能恢复的关键）
~/.ssh/                     # SSH 密钥（GitHub push 用，丢了得重配）
~/.local/bin/               # hugo/cloudflared 等二进制
~/.bashrc ~/.zshrc ~/.gitconfig  # shell + git 配置
```

### 3.2 不必备份

- `~/.cache/` —— 可重建的缓存
- `~/Files/gitea/log/` —— 日志，不重要
- `~/Files/blog/public/` —— Hugo 构建产物，`hugo` 一条命令重建
- `~/Files/blog/themes/` —— 主题，能重新 clone

> 不要把整个 `~/` 无脑 rsync——`.cache` 几个 GB 全是可重建的垃圾，浪费时间也费盘。

## 四、rsync 增量备份脚本

核心思路：**每次备份生成一个带时间戳的目录，没变的文件用 hardlink 指向上次**。

```bash
#!/bin/bash
# ~/Files/scripts/backup-to-external.sh
# 用法：./backup-to-external.sh /media/wzf/backup
set -euo pipefail

DEST="${1:?用法: $0 <备份根目录>"
HOST=$(hostname)
TS=$(date '+%Y-%m-%d_%H-%M-%S')
BACKUP_ROOT="${DEST}/${HOST}"
TARGET="${BACKUP_ROOT}/${TS}"
LAST=$(find "${BACKUP_ROOT}" -maxdepth 1 -type d -name '20*-*-*_*-*-*' 2>/dev/null | sort | tail -1)

mkdir -p "${TARGET}"

RSYNC_OPTS=(
    -aHv                      # archive + hardlinks + verbose
    --delete                  # 删除源端已删的文件（仅作用于 --link-dest 对比的快照）
    --exclude='*.log'        # 不备份日志
    --exclude='.cache/'
    --exclude='node_modules/'
    --exclude='public/'      # Hugo 构建产物，可重建
)

if [[ -n "${LAST}" ]]; then
    echo "[backup] 增量基于上次快照: ${LAST}"
    rsync "${RSYNC_OPTS[@]}" --link-dest="${LAST}" \
        /home/wzf/Files/ \
        /home/wzf/.config/systemd/user/ \
        /home/wzf/.ssh/ \
        /home/wzf/.local/bin/ \
        /home/wzf/.bashrc \
        /home/wzf/.zshrc \
        /home/wzf/.gitconfig \
        "${TARGET}/"
else
    echo "[backup] 首次全量备份"
    rsync "${RSYNC_OPTS[@]}" \
        /home/wzf/Files/ \
        /home/wzf/.config/systemd/user/ \
        /home/wzf/.ssh/ \
        /home/wzf/.local/bin/ \
        /home/wzf/.bashrc \
        /home/wzf/.zshrc \
        /home/wzf/.gitconfig \
        "${TARGET}/"
fi

# 写入备份元信息
{
    echo "backup_time=${TS}"
    echo "source_host=${HOST}"
    echo "link_dest=${LAST:-<none>}"
    echo "du=$(du -sh "${TARGET}" | cut -f1)"
} > "${TARGET}/.backup-meta"

# 清理 14 天前的旧快照（保留最近 14 份）
find "${BACKUP_ROOT}" -maxdepth 1 -type d -name '20*-*-*_*-*-*' -mtime +14 -exec rm -rf {} +

echo "[backup] 完成: ${TARGET}"
```

关键点：

- `-a` 保留权限/属主/时间戳；`-H` 保留硬链接；`-v` verbose
- `--link-dest="${LAST}"` 指向上次快照，没变的文件用 hardlink 复用，**第一次全量，之后每次只占变化量**
- `--delete` 让快照和源端一致（不残留源端已删的文件）
- 保留最近 14 份，超过 14 天的自动清理
- 每份快照目录是**完整目录树**，可独立用 `cp` / `rsync` 整个恢复，不依赖工具

> 注意 `--link-dest` 的路径必须是**绝对路径**，且必须指向**已经存在的目录**。`--link-dest` 不会跨文件系统，源和目标必须在同一文件系统（外接盘自己有自己一份）。

## 五、systemd --user timer 定时

cron 是经典选择，但既然主机上 wireproxy/gitea/cloudflared 都走 systemd --user，**timer 也用同一套体系更统一**——日志走 `journalctl --user`，状态走 `systemctl --user status`，不用单独装 cron 客户端。

`~/.config/systemd/user/backup-to-external.service`：

```ini
[Unit]
Description=Incremental rsync backup to external USB drive
After=network-online.target

[Service]
Type=oneshot
ExecStart=/home/wzf/Files/scripts/backup-to-external.sh /media/wzf/backup
# 备份盘没挂载时不要 fail，安静退出
ExecCondition=/bin/bash -c '[ -d /media/wzf/backup ]'
StandardOutput=journal
StandardError=journal
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
```

`~/.config/systemd/user/backup-to-external.timer`：

```ini
[Unit]
Description=Daily incremental backup to external drive

[Timer]
# 每天凌晨 3 点跑一次
OnCalendar=*-*-* 03:00:00
# 错过的开机后再跑（比如半夜关机、白天开机时补跑）
Persistent=true
# 防止同时触发多次
AccuracySec=10s

[Install]
WantedBy=default.target
```

启用：

```bash
systemctl --user daemon-reload
systemctl --user enable --now backup-to-external.timer

# 看下次触发时间
systemctl --user list-timers backup-to-external.timer

# 手动立即跑一次
systemctl --user start backup-to-external.service

# 看日志
journalctl --user -u backup-to-external.service -n 50 --no-pager
```

几个要点：

- `Type=oneshot` + `ExecCondition` 检查外接盘是否挂载，没挂就安静跳过（不进 failed 状态）
- `Nice=10` + `IOSchedulingPriority=7` 让备份任务低优先级跑，不影响白天用机器
- `Persistent=true` 错过的窗口在下次开机时补跑——半夜关机了白天开机会补一次
- `OnCalendar=*-*-* 03:00:00` 每天凌晨 3 点，比 `daily` 更精确

## 六、恢复演练

备份没验证 = 没备份。**定期 restore 测试**是 3-2-1 原则里最容易被忽略、却最关键的一步。

### 6.1 单文件恢复

```bash
# 从某份快照恢复一个博客源码文件
rsync -av /media/wzf/backup/wzf/2026-08-25_03-00-00/blog/content/posts/systemd-user-workflow.md \
    ~/Files/blog/content/posts/
```

### 6.2 整目录恢复（模拟全盘失败）

```bash
# 假设新盘装好系统后，恢复用户数据
sudo rsync -avH --numeric-ids \
    /media/wzf/backup/wzf/2026-08-25_03-00-00/Files/ \
    /home/wzf/Files/

# 恢复 systemd unit 文件
sudo rsync -avH --numeric-ids \
    /media/wzf/backup/wzf/2026-08-25_03-00-00/.config/systemd/user/ \
    /home/wzf/.config/systemd/user/

systemctl --user daemon-reload
systemctl --user enable --now wireproxy-warp.service gitea.service cloudflared.service

# 恢复 SSH 密钥（注意权限）
sudo rsync -avH --numeric-ids \
    /media/wzf/backup/wzf/2026-08-25_03-00-00/.ssh/ \
    /home/wzf/.ssh/
chmod 700 /home/wzf/.ssh
chmod 600 /home/wzf/.ssh/id_ed25519
chmod 644 /home/wzf/.ssh/id_ed25519.pub
```

### 6.3 验证清单

每次恢复演练后检查：

- [ ] `~/Files/blog/` 下的 Markdown 数量和源端一致（`find . -name '*.md' | wc -l`）
- [ ] Gitea 能启动（`systemctl --user status gitea`，Web 能打开 127.0.0.1:3000）
- [ ] wireproxy SOCKS5 可用（`curl --socks5 127.0.0.1:1080 https://github.com -I`）
- [ ] SSH push 可用（`ssh -T git@github.com` 返回 Hi <user>!）
- [ ] blog `hugo server` 能正常构建（`hugo --minify` 不报错）

**建议每季度（3 个月）做一次全盘恢复演练**——专门拿一个虚拟机或临时分区，把整套数据从备份恢复出来，把所有服务跑通。**只有跑通过的备份才算真备份**。

## 七、整体流程

{{< mermaid >}}
graph TD
    A[源数据: ~/Files + 配置 + SSH + unit] --> B{rsync 增量备份}
    B -->|每日 03:00 systemd timer| C[外接 USB 硬盘]
    B -->|手动: git push| D[Gitea 私有仓库 本机]
    B -->|手动: git push| E[GitHub 仓库异地]
    C --> F[14 份快照 14天滚动]
    D --> G[Gitea SQLite]
    E --> H[GitHub Actions 自动构建]
    H --> I[GitHub Pages 固定 URL]
    J[恢复演练 每季度] --> K[从外接盘 restore]
    K --> L[验证: 服务能跑 + SSH + 博客能构建]
    L --> M{验证通过?}
    M -->|是| N[备份策略可信]
    M -->|否| O[修备份脚本 重跑]
    O --> B
{{< /mermaid >}}

## 八、外接盘挂载的坑

systemd --user timer 跑的时候**用户 session 的挂载点必须存在**。外接 USB 硬盘有几个坑：

1. **UUID 挂载**：不要用 `/dev/sdb1`，盘符会变。用 `blkid` 查 UUID，写进 `/etc/fstab`：
   ```fstab
   UUID=xxxx-xxxx  /media/wzf/backup  ext4  defaults,nofail,x-systemd.automount  0  2
   ```
   `nofail` 让没插盘时开机不卡住；`x-systemd.automount` 第一次访问才挂载。

2. **文件系统**：**ext4**，不要 exFAT/NTFS——exFAT 不支持 hardlink（`--link-dest` 失效变全量）；NTFS 在 Linux 下权限映射乱。

3. **权限**：外接盘格式化后 chown 给用户：
   ```bash
   sudo mkfs.ext4 -L backup /dev/sdX1
   sudo mkdir -p /media/wzf/backup
   sudo mount /dev/sdX1 /media/wzf/backup
   sudo chown -R wzf:wzf /media/wzf/backup
   ```

## 九、成本和现状

| 项目 | 选型 | 成本 |
| --- | --- | --- |
| 备份软件 | rsync + systemd timer | 0（系统自带） |
| 本地备份盘 | 1TB USB 移动硬盘 | 一次性 ~¥200 |
| 异地备份 | Gitea 私有仓库 + GitHub | 0（已 push） |
| 恢复演练 | 季度手动 | 时间 ~30 分钟 |

**零订阅费、零云依赖**。家用场景这套够了。如果异地要更稳，可以考虑加一个 restic 仓库放亲友家或 VPS，但**异地那一份代码已经有了，本地的核心是应对盘坏**，rsync + 外接盘足够。

## 十、设计取舍

1. **rsync 而非 restic/borg**：家用几 GB 数据，rsync + hardlink 已经够用，备份目录可直接 `ls`/`cp` 恢复，零工具依赖。数据量大或需要去重时再上 restic。
2. **systemd --user timer 而非 cron**：和现有 wireproxy/gitea/cloudflared 一套体系，日志走 `journalctl --user`，状态走 `systemctl --user status`，统一管理。
3. **ExecCondition 检查盘**：外接盘可能没插，用 `ExecCondition` 检查挂载点存在时安静跳过，避免每次 timer 触发都失败告警。
4. **14 天滚动而非永久保留**：家用场景发现误删一般几天内就察觉，14 天足够；想要更长保留把 `-mtime +14` 改大。
5. **每季度恢复演练**：备份没验证等于没备份——专门花时间把数据 restore 到另一台机器跑通服务，才算真备份。

> 这篇博文本身就在 `~/Files/blog/` 下——写完 push 到 GitHub 后，**异地那份自动有了**。剩下要做的就是插上外接盘，让 systemd timer 接管每天的增量快照。
