---
title: "cron vs systemd timer：家用 Linux 定时任务选哪个？（附迁移实战 diff）"
date: 2026-08-26T02:00:00+08:00
draft: false
tags: ["cron", "systemd-timer", "Linux", "运维", "对比"]
categories: ["运维"]
summary: "crontab -e 一行就能跑定时任务，是 Linux 的老熟人；systemd timer 则是新贵——日志、失败重试、开机补发、资源限制、依赖管理一个没落下。家用主机上现在实际跑着两个 systemd timer：backup 每日 03:00 + health-check 每 5 分钟。用真实迁移过的脚本 diff，对比 9 个核心维度，附决策图和 cheat sheet。"
---

如果你接触 Linux 超过半年，肯定写过 `crontab -e`：

```cron
0 3 * * * /home/wzf/Files/scripts/backup.sh
```

一行搞定"每天凌晨 3 点跑备份"。简单、直接、几十年不变。

但如果你用过几次 systemd timer，会发现它解决了 cron 几乎所有"多年来大家默默忍着"的痛点：**日志去哪了、失败了能不能自动重试、关机错过还能不能补跑、能不能限制不要占满 CPU、A 任务跑之前必须先等网络连上**。

这台家用主机上现在实际跑着两个 systemd timer：

| 任务 | 用的啥 | 频率 |
| --- | --- | --- |
| 备份脚本 rsync 增量到外接盘 | systemd timer | 每日 03:00 |
| health-check 监控脚本 curl 各服务 | systemd timer | 每 5 分钟 |

加上最早把 cloudflared 从 `nohup` 改成 .service 的经历（反面教材记在 [systemd --user 工作流](/posts/systemd-user-workflow/)），我对 cron 和 timer 的差别有一手感受。

这篇不是"谁好谁坏"的站队文——cron 在很多场景仍然最简。这篇讲：**9 个核心维度对比 + 两个真实迁移实战 diff + 决策图**，你自己判断。

## 一、总览对比表（9 个维度）

| 维度 | cron (Vixie cron / cronie) | systemd timer |
| --- | --- | --- |
| **配置方式** | `crontab -e` 一行语法（`分 时 日 月 周 cmd`） | 两个文件：`xxx.timer` + `xxx.service` |
| **日志去哪了** | 默认**无**，只能让脚本自己 `>> file 2>&1`，或者 cron 走 `sendmail`（现在 99% 的机器没装 MTA，日志直接丢黑洞） | **journald 自动收录**（stdout/stderr 全进 journal），`journalctl --user -u xxx.service -f` 实时看 |
| **失败自动重试** | ❌ 没这概念，脚本自己写 `|| retry-loop` | ✅ `Restart=on-failure` + `RestartSec=5`，崩溃后 5 秒自动拉起，`StartLimitBurst` 防死循环 |
| **关机/休眠错过补跑** | ❌ 03:00 跑的任务，02:55 关机 04:00 开机，**就漏掉了**，cron 不关心 | ✅ `Persistent=true`：下次开机立刻补上错过的那次（前提是 OnCalendar 类 timer，OnUnitActiveSec 不适用但逻辑等价） |
| **资源限制** | ❌ 完全没有。备份脚本把 IO 打满 = 整个主机卡顿 | ✅ `Nice=10` CPU 权重调低 / `IOSchedulingClass=idle` IO 空闲时才跑 / `MemoryHigh=256M` 内存上限，一个都不会影响前台桌面 |
| **依赖管理** | ❌ 没有。网络还没起来就 curl = 随机失败 | ✅ `After=network-online.target nss-lookup.target` + `Wants=network-online.target`，网络就绪才启动 |
| **随机延迟防共振** | ❌ 全部机器 03:00 准点跑 backup = NAS 被打满（如果是多机环境） | ✅ `RandomizedDelaySec=15min`：03:00~03:15 之间随机一个时间点启动 |
| **精度** | 分钟级（最小 1 分钟） | 微秒级（默认 AccuracySec=1min 可改到 1us） |
| **调试便利** | `*/1 * * * * cmd` 改每分钟试一次，完了再改回去（容易忘改回去→占满磁盘） | `systemctl --user start xxx.service` **立即手动触发一次**，不用等下次触发；`systemd-analyze calendar 'daily'` 看下次执行时间 |

光看表格太干，下面每个维度展开讲，附真实脚本 diff。

## 二、cron 的坑和它的解决方案

### 坑 1：日志丢了

默认 cron 执行脚本的 stdout/stderr 是通过 `sendmail` 发送给本地用户的。但：

```bash
which sendmail     # 99% 的家用 Ubuntu = 空
which postfix      # 同样空
```

没 MTA = 邮件永远发不出去 = **日志直接丢了**。你根本不知道备份脚本昨天跑成功没。

cron 派的解决方案：**脚本里自己重定向**：

```cron
# cron 写法：把所有输出手动重定向到文件，还要自己做日志轮转
0 3 * * * /home/wzf/Files/scripts/backup.sh >> /var/log/backup.log 2>&1
```

多了两步：`>> xxx 2>&1` + 自己写 `logrotate` 规则或者脚本里 `tail -1000` 轮转。

而 systemd timer 里你**一个字不用写**：

```bash
journalctl --user -u backup.service --since yesterday
# 直接看昨天备份的所有 stdout/stderr，带时间戳、带退出码，journald 自动按日期按大小轮转
```

### 坑 2：关机错过就漏了

备份任务是"每日 03:00"，但你把主机 02:00 关了第二天 08:00 开，cron 就当作 03:00 那一刻"不需要执行"——当天备份直接漏掉了。

cron 派的经典解决方案：**换 `anacron`**——anacron 就是专为"不是 24h 开机的机器"设计的 cron 补跑器。但你得额外装 anacron + 配 `/etc/anacrontab` + 它是全局 root 级的（家用没 sudo），这一路下去就不是一行 crontab 了。

systemd timer 一个参数搞定：

```ini
# backup.timer 的 [Timer] 段
OnCalendar=*-*-* 03:00:00
Persistent=true
```

`Persistent=true`：timer 会记录"上次成功跑是什么时候"，下次开机时如果发现"理论上昨天 03:00 该跑但没跑"，**开机立刻补一次**，补完了今天的 03:00 照样再跑。零额外软件。

### 坑 3：备份打满 IO 桌面卡死

cron 没有任何资源控制概念，crond 以 root 身份 fork 你的脚本进程就完事。backup.sh 里 `rsync -aHAX` 大文件读写字节数是以 GB 计的，IO 调度器一忙，桌面鼠标键盘都卡。

systemd timer 通过 systemd .service 启动，资源限制直接写在 .service 里：

```ini
# backup.service
[Service]
Type=oneshot
Nice=10                    # CPU 调度权重调低（默认 0，越大越靠后）
IOSchedulingClass=idle     # IO 调度类=idle：只有磁盘没其他 IO 时才跑
MemoryHigh=256M            # 内存超 256M 开始回收
ExecStart=/home/wzf/Files/scripts/backup.sh
```

写了之后再跑备份，桌面体感和没跑一样——backup 只在 CPU/IO 真有空的时候占用。cron 要做到同级别效果得 `nice -n 10 ionice -c 3` 包一层命令，命令变长还容易忘。

## 三、从 cron 迁移到 systemd timer：实战 diff

拿我真实用的"每日 03:00 备份"举例。**原来的 cron 写法**：

```cron
# crontab -e（wzf 用户）
# 每天 03:00 跑 backup.sh，输出重定向到文件，logrotate 配在 /etc/logrotate.d/backup
0 3 * * * nice -n 10 ionice -c 3 /home/wzf/Files/scripts/backup.sh >> /home/wzf/Files/monitor/backup.log 2>&1
```

这一行表面简洁，藏了 **6 个分散依赖**：
1. `nice -n 10 ionice -c 3` 得自己记住写（忘写就卡死桌面）
2. `>> backup.log 2>&1` 得自己记住写（忘写就日志黑洞）
3. 得在 `/etc/logrotate.d/backup` 单独写一份轮转规则
4. 关机错过补跑？没装 anacron 就漏了
5. 依赖网络？脚本开头自己 `ping -c1 gw || exit 0`（不然 rsync 远程备份会挂）
6. backup.sh 失败了要不要重试？脚本里自己 `for i in 1 2 3; do backup.sh && break; sleep 60; done`

**迁移到 systemd timer 后**：分成 `backup.timer` + `backup.service` 两个文件。

`backup.timer`（什么时候跑）：
```ini
[Unit]
Description=Daily incremental backup (rsync --link-dest)

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true                  # 关机错过自动补
RandomizedDelaySec=15min         # 03:00~03:15 随机，多机不撞 NAS
AccuracySec=1min

[Install]
WantedBy=timers.target
```

`backup.service`（跑什么 + 什么环境跑）：
```ini
[Unit]
Description=rsync backup script
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
Restart=on-failure
RestartSec=60
StartLimitIntervalSec=3600
StartLimitBurst=3
ExecStart=/home/wzf/Files/scripts/backup.sh
```

**1 行 cron → 2 个 ini 文件共 23 行**，看起来变长了，但换来的是：

| 原来分散的 6 个依赖 | 现在怎么处理 |
| --- | --- |
| nice + ionice | service 里 `Nice=10 IOSchedulingClass=idle` 固定 |
| 输出重定向 | journald 自动收，不用写 |
| 日志轮转 | journald 自带，不用装 logrotate 写配置 |
| 关机补跑 | `Persistent=true` |
| 等网络起 | `After=network-online.target` |
| 失败重试 | `Restart=on-failure RestartSec=60 StartLimitBurst=3`，自动重试 3 次，每次间隔 60s，1 小时内不超过 3 次 |

6 个分散在各处的约定 → 2 个文件集中声明。**一次写对，下次看 `systemctl --user status backup.timer` 一眼就明明白白，不用翻 crontab + /etc/logrotate.d/* + 脚本内部 retry-loop。**

## 四、迁移第 2 个例子：每 5 分钟健康检查

再看另一台在用的：[轻量健康检查](/posts/health-check/)脚本每 5 分钟跑 curl。

**cron 写法**：
```cron
*/5 * * * * /home/wzf/Files/scripts/health-check.sh
```

简单。但：
- 每次启动和 systemd 服务状态相关（systemctl is-active），**cron 作为 user 级时用户注销就不跑**——家用场景下 GNOME 登出就是停止 user cron
- health-check 里对 wireproxy 重试 3 次，但脚本本身 cron 不会再给它一层重试
- 想看"今天 08:30 那次跑没跑、输出什么"？得打开脚本写进去的 `health.log`

**systemd timer 写法**（实际在用的）：

`health-check.timer`：
```ini
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=10s
Persistent=true
```

`health-check.service`：
```ini
[Service]
Type=oneshot
Nice=10
ExecStart=/home/wzf/Files/scripts/health-check.sh
StandardOutput=journal
StandardError=journal
```

关键区别：
1. **`OnBootSec=1min OnUnitActiveSec=5min` = 相对式调度**：开机 1 分钟后第一次跑，以后每次 health-check.service **成功结束的时刻 + 5min** 再跑下一次。这种模式比 cron `*/5 * * * *` 更适合"每隔 N 分钟"的健康检查——不会因为上次脚本刚好跑了 58 秒就 2 秒后立刻重跑。
2. **systemd `--user` timer 配合 `enable-linger=yes`**：用户注销/不登录时照跑（之前 cron user 模式做不到的事），这在 [systemd --user 工作流](/posts/systemd-user-workflow/) 里详细写过。
3. **两种日志同时看**：`journalctl --user -u health-check.service` 看 stdout + stderr（脚本 echo 的详细输出），`~/Files/monitor/health.log` 看趋势 summary，互补。

## 五、什么时候还是选 cron

写了这么多 timer 的好处，cron 还真不是一无是处。下面这些场景 cron 更合适：

1. **一次性临时任务，跑完就删**：`* * * * * /tmp/test.sh`，crontab -e 写一行 5 秒搞定，建两个 .service/.timer 文件要 30 秒。
2. **服务器全局 root 级定时任务**：`/etc/cron.d/`、`/etc/cron.hourly/`/`daily/` 目录把脚本往里一丢就生效，运维老规矩，团队没人会问"这任务哪来的"。
3. **任务太简单，日志/重试/补跑全无所谓**：比如每小时往一个文件追加 `date`，cron 一行解决，timer 的声明式优势完全用不上。
4. **容器里（没有 systemd PID 1）**：Alpine/Debian slim 镜像通常没装 systemd，直接 cron 或者自己在 entrypoint.sh 里 `while true; sleep 300; cmd; done`。

## 六、选型决策图

一张图快速判读：

{{< mermaid >}}
flowchart TD
    A[有定时任务要跑] --> B{"在家用 Linux 主机？<br/>（非 root 长期服务）"}
    B -->|否 - 临时/一次性| C[cron 一行<br/>crontab -e]
    B -->|否 - 容器 Alpine| D[crond 或 entrypoint while-sleep]
    B -->|否 - 服务器全局 root| E[/etc/cron.d/<br/>或 /etc/cron.hourly/<br/>团队约定]
    B -->|是 - 家用 user 长期| F{"需要这些能力之一？<br/>日志/重试/补跑/资源限制/依赖"}
    F -->|否 - 全不需要| C
    F -->|是 - 至少一条| G["systemd timer<br/>.timer + .service 两文件"]
    G --> H{"频率 = 固定时间？<br/>(例：每天 03:00)"}
    H -->|是| I["OnCalendar=<br/>*-*-* 03:00:00<br/>+ Persistent=true"]
    H -->|否 - 每隔 N 分钟/秒| J["OnBootSec=1min<br/>OnUnitActiveSec=5min<br/>相对式"]

    style C fill:#fff3e0,stroke:#e65100
    style D fill:#fff3e0,stroke:#e65100
    style E fill:#fff3e0,stroke:#e65100
    style G fill:#e8f5e9,stroke:#2e7d32
    style I fill:#e3f2fd,stroke:#1565c0
    style J fill:#e3f2fd,stroke:#1565c0
{{< /mermaid >}}

**一句话决策**：家用 Linux 主机长期跑的 user 级定时任务——**只要你有任何"失败了怎么办 / 关机了怎么办 / 卡桌面怎么办"的疑问，选 systemd timer**。没有这些疑问、任务超短平快 → cron。

## 七、日常命令 Cheat Sheet

### cron

```bash
crontab -e              # 编辑当前用户 crontab
crontab -l              # 列出当前用户 crontab
crontab -r              # 清空当前用户 crontab（⚠️ 易误操作！）
tail -f /var/log/syslog | grep -i cron   # Debian/Ubuntu cron 日志位置（不是你的脚本 stdout，是 crond 自身）
grep CRON /var/log/syslog
# 你的脚本 stdout？默认丢掉，除非 >> file 重定向
```

### systemd timer

```bash
# 查看已有的所有 user timer（最常用）
systemctl --user list-timers --all
# NEXT / LEFT / LAST / PASSED / UNIT / ACTIVATES 六列，一眼看所有定时

# 立即手动触发一次（不用等下次调度，调试神器）
systemctl --user start backup.service
# 看完 journalctl 再调，直到满意

# 实时看日志
journalctl --user -u backup.service -f

# 看 timer 某一个 OnCalendar 下次什么时候响
systemd-analyze calendar '*-*-* 03:00:00'
systemd-analyze calendar 'Mon *-*-* 09:00:00'

# 安装 timer（写了两个文件后）
systemctl --user daemon-reload
systemctl --user enable --now backup.timer
# enable = 开机自启，now = 立刻激活 timer（不是立刻执行服务）

# 关闭 / 暂停
systemctl --user disable --now backup.timer
systemctl --user stop backup.service

# timer 的日历写法速查：
# OnCalendar=*-*-* 03:00:00          每天 03:00
# OnCalendar=Mon..Fri *-*-* 09:00:00  工作日 09:00
# OnCalendar=*-*-1..7 03:00:00         每月 1 号到 7 号 03:00
# OnCalendar=hourly                     每小时整点
# OnCalendar=*-*-* *:00/15:00           每 15 分钟（:00 :15 :30 :45）
```

## 八、踩坑沉淀

1. **cron 的 `$PATH` 短到离谱**：cron 启动脚本时的 PATH 通常是 `/usr/bin:/bin`，你在 bash 里能跑的 `hugo`、`wireproxy`（在 `~/.local/bin/` 或 `~/Files/proxy/`），cron 里大概率找不到。要么 crontab 最上面写 `PATH=/home/wzf/.local/bin:/usr/local/sbin:...`，要么脚本里全用绝对路径。**systemd timer 也同样有这个问题**，所以 `ExecStart=` 一律写完整绝对路径，不要依赖 PATH。
2. **OnCalendar 和 OnUnitActiveSec 不要混写在一个 timer 里**：结果是两个调度规则同时生效（会执行两次）。选一种：固定时间点用 OnCalendar + Persistent；间隔式用 OnBootSec + OnUnitActiveSec。
3. **timer 触发的是 .service，不是脚本**：健康检查里 `systemctl --user start health-check.timer` 没用；要手动跑一次得 `start health-check.service`。`.timer` 只负责"什么时候唤醒"，真正干活的是同名（或 `Unit=` 指定的）.service。
4. **Persistent=true 只对 OnCalendar 有效**：OnUnitActiveSec 是相对调度，"上次结束 + 5min"没有"日历上该跑的时刻"，Persistent 对它没有影响——不过这种任务通常不需要补跑，漏了就漏了下次 5 分钟后还会来。
5. **RandomizedDelaySec 别加在 health-check 上**：每 5 分钟检查 + 随机延迟 1 分钟，意味着检查间隔从 5 分钟漂移到 5~6 分钟，`streak=2` 连续失败阈值会对不齐。RD 更适合备份/同步类的多机防撞，对监控类不友好。

## 九、尾巴：为什么我最终全换成了 timer

写着写着发现我这台主机上已经**没有一条 user 级 crontab 了**：备份和健康检查都是 timer，wireproxy/gitea/cloudflared 是 long-running .service，SSH 推送失败重试在 `push.sh` 脚本内部（shell 层循环），没有任何剩余场景非 cron 不可。

不是 cron 不好——cron 当年一行的轻快感仍在，我在公网 VPS 上跑全局 root 级任务照样 `crontab -e`。但**家用 user 级、长期跑、不想给 sudo、对稳定性有一点点要求**的场景下，timer 用 2 个文件 20 行把 cron 派需要分散在 6 个地方才能凑齐的能力一次性声明清楚，长期看维护成本明显更低。

最关键的那一条不是资源限制也不是日志（虽然这俩已经很值钱），是 `Persistent=true` + 补跑。备份任务一天就跑一次，**一次漏了可能意味着要恢复时发现备份是 3 天前的**——这种场景下 cron 的"到点执行，没在就拉倒"我接受不了。timer 的"在就行"是真的让人放心。

如果你还在用 cron 跑家用主机的定时任务，拿一个最看重的任务（通常是备份）迁到 timer 试试，体验过就回不去了。
