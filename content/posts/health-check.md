---
title: "轻量健康检查：bash + systemd timer 监控家用 Linux 自托管服务"
date: 2026-08-25T15:00:00+08:00
draft: false
tags: ["bash", "systemd-timer", "监控", "Linux", "自托管"]
categories: ["运维"]
summary: "家用 Linux 主机跑着 wireproxy/gitea/cloudflared 三个 systemd --user 服务，systemd 已经能崩溃自动重启，但缺一个'定时观察 + 历史趋势'的视角。这里不引入 uptime-kuma 这类 Web UI 监控（Node.js 太重），而是用 bash + systemd timer 每 5 分钟 curl 一遍真实可用性，记日志看趋势。脚本设计、重试机制、抖动过滤、状态机告警门槛都在里面。"
---

家用 Linux 主机上跑着三个自托管服务：wireproxy（WARP 代理）、Gitea（私有 Git）、cloudflared（公网隧道）。它们都已经是 systemd --user 服务，配了 `Restart=on-failure` + `StartLimitBurst=5`——崩溃会自动拉起，reboot 会自启。看起来很稳了。

但缺一个视角：**定时观察 + 历史趋势**。systemd 能在崩溃时重启，但不会告诉我"WARP 代理今天抖了几次"、"Gitea 平均响应时间多少"。要这个视角，常见做法是上 [uptime-kuma](https://github.com/louislam/uptime-kuma)——一个流行的自托管监控，有 Web UI、推送通知、多渠道告警。但 uptime-kuma 是 Node.js 应用，要装 npm + git clone + 跑一个长驻进程，对家用主机来说太重。

这篇记下更轻量的方案：**bash 脚本 + systemd --user timer，每 5 分钟跑一次 curl，记日志看趋势**。零新依赖、零 Web UI、和现有 systemd --user 架构一套体系。

## 一、为什么不上 uptime-kuma

| 维度 | uptime-kuma | bash + systemd timer |
| --- | --- | --- |
| 依赖 | Node.js + npm + git | 系统自带（bash/curl/systemd） |
| 资源 | 长驻 Node 进程 ~80MB | oneshot 跑完即退 ~3MB |
| 部署 | clone + npm install + 配 systemd | 写 1 个脚本 + 2 个 unit 文件 |
| Web UI | ✅ 漂亮 | ❌ 只有日志 |
| 告警推送 | ✅ Telegram/邮件/Webhook | ❌（要看日志才知道） |
| 历史 | 内置 SQLite | tail/grep 日志文件 |
| 适合 | 多服务、需要告警推送、对外暴露监控 | 家用、自看、零依赖 |

家用场景下我的取舍：

1. **不需要告警推送**：服务都配了 systemd Restart，崩溃会自拉起；真出大问题我会自己上机看，不用推送打扰。
2. **不需要 Web UI**：看历史 `tail` + `grep` 就行，UI 是锦上添花。
3. **不想引入 Node**：多一个运行时就多一份维护成本（npm 升级、依赖漏洞）。
4. **要真实可用性**：不只看端口在不在，要真 curl 一遍外网，确认代理能用。

> 如果你的场景需要"服务挂了立即推送通知到手机"，上 uptime-kuma 或用 [healthchecks.io](https://healthchecks.io)（反向告警：脚本定时 ping 它，没 ping 到就告警）。家用自看场景，bash 够了。

## 二、监控什么、不监控什么

### 2.1 监控

| 检查项 | 测什么 | 为什么 |
| --- | --- | --- |
| **wireproxy** | 通过 SOCKS5 1080 访问 `api.github.com/zen` | 端口在 ≠ 代理能用；要真 curl 外网才确认 WARP 隧道活着 |
| **gitea** | `curl http://127.0.0.1:3000/` HTTP 200 | Web 能响应（本地直连，不耗外网） |
| **cloudflared** | `systemctl is-active` + `ss -tln \| grep 1313` | 进程在跑 + 它反代的 Hugo server 在监听 |
| **sd_wireproxy / sd_gitea** | `systemctl --user is-active` | systemd 视角，便于一眼看哪个挂了 |

### 2.2 不监控

- 磁盘空间 / CPU / 内存：`htop` / `df -h` 现场看，不用记日志
- cloudflared 的 quick tunnel URL：每次重启都变，监控它意义不大
- 日志大小：日志走 journald，自己管轮转

> 关键原则：**监控"真实可用性"而非"进程在不在"**。wireproxy 进程可能在跑、端口在监听，但 WARP 隧道断了——只有真 curl 外网才能发现。这是为什么 wireproxy 检查走 `api.github.com/zen` 而不是 `ss -tln | grep 1080`。

## 三、健康检查脚本

`~/Files/scripts/health-check.sh`：

```bash
#!/bin/bash
# 轻量健康检查：监控 wireproxy/gitea/cloudflared + 外网连通性
# 由 systemd --user timer health-check.timer 每 5 分钟触发
# 日志：~/Files/monitor/health.log（保留最近 1000 行）

set -u

LOG_DIR="$HOME/Files/monitor"
LOG_FILE="$LOG_DIR/health.log"
STATE_FILE="$LOG_DIR/health.state"   # 保存连续失败计数（避免抖动误报）
MAX_LOG_LINES=1000

mkdir -p "$LOG_DIR"
touch "$STATE_FILE"

now_iso() { date '+%Y-%m-%dT%H:%M:%S%:z'; }

RESULTS=()
FAIL_COUNT=0

# 单项检查：check <name> <test_command>
# 退出码 0=OK，非 0=FAIL；stdout 第一行作为附加信息
check() {
    local name="$1"; shift
    local info
    if info=$("$@" 2>&1); then
        RESULTS+=("$name=OK($info)")
    else
        RESULTS+=("$name=FAIL($info)")
        FAIL_COUNT=$((FAIL_COUNT+1))
    fi
}

# 1. wireproxy SOCKS5 1080：通过它访问 GitHub，测代理真能用
#    WARP 偶发抖动，单次测试会误报，重试 3 次任一成功即 OK
check "wireproxy" bash -c '
    out=""
    for i in 1 2 3; do
        out=$(curl -sS -o /dev/null -w "%{time_total}" \
            --socks5-hostname 127.0.0.1:1080 \
            --connect-timeout 5 --max-time 10 \
            https://api.github.com/zen 2>&1) \
            && { echo "${out}s (try $i)"; exit 0; }
        sleep 1
    done
    echo "$out"
    exit 1
'

# 2. gitea HTTP 3000
check "gitea" bash -c '
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 --max-time 5 \
        http://127.0.0.1:3000/ 2>/dev/null) \
        && [ "$code" = "200" ] && echo "HTTP $code" || echo "HTTP $code"
    [ "$code" = "200" ]
'

# 3. cloudflared：systemd active + 本地 1313（hugo server）在监听
check "cloudflared" bash -c '
    [ "$(systemctl --user is-active cloudflared 2>/dev/null)" = "active" ] \
        && ss -tln 2>/dev/null | grep -q "127.0.0.1:1313 " \
        && echo "active+1313" || exit 1
'

# 4-5. systemd 三服务的 active 状态（汇总视角）
check "sd_wireproxy" bash -c '
    [ "$(systemctl --user is-active wireproxy-warp 2>/dev/null)" = "active" ] \
        && echo active || exit 1
'
check "sd_gitea" bash -c '
    [ "$(systemctl --user is-active gitea 2>/dev/null)" = "active" ] \
        && echo active || exit 1
'

# === 失败计数 + 告警门槛 ===
STATE_FAIL=$(cat "$STATE_FILE" 2>/dev/null | grep -E '^fail_streak=' | cut -d= -f2)
STATE_FAIL=${STATE_FAIL:-0}

if [ "$FAIL_COUNT" -gt 0 ]; then
    NEW_STREAK=$((STATE_FAIL+1))
else
    NEW_STREAK=0
fi

cat > "$STATE_FILE" <<EOF
last_check=$(now_iso)
fail_streak=$NEW_STREAK
last_fail_count=$FAIL_COUNT
EOF

# 每次都记一行；1000 行轮转 ≈ 3.5 天历史（5 分钟一次 × 288/天）
TS=$(now_iso)
LINE="$TS ${RESULTS[*]} streak=$NEW_STREAK"
echo "$LINE" >> "$LOG_FILE"

# 保留最近 MAX_LOG_LINES 行
if [ -f "$LOG_FILE" ]; then
    tmp=$(tail -n "$MAX_LOG_LINES" "$LOG_FILE")
    echo "$tmp" > "$LOG_FILE"
fi
```

几个设计要点：

### 3.1 `check` 函数：统一 OK/FAIL 模板

每个检查项都是"命令成功=OK，失败=FAIL"，stdout 第一行作为附加信息（响应时间/HTTP code/状态字符串）。这样加新检查项只要写一段命令，不用复制粘贴 OK/FAIL 模板。

### 3.2 重试机制：过滤抖动误报

wireproxy 走 WARP，WARP 偶发抖——实测连续 3 次 curl，第 2 次超时、第 1/3 次成功（3.7s）。如果单次测试就直接报 FAIL，5 分钟跑一次会有大量误报。

脚本里 wireproxy 检查重试 3 次，任一成功即 OK，全失败才 FAIL：

```bash
for i in 1 2 3; do
    out=$(curl ... 2>&1) && { echo "${out}s (try $i)"; exit 0; }
    sleep 1
done
echo "$out"
exit 1
```

日志里会标注 `(try 3)` 表示第 3 次才成功，便于看趋势——如果连续多次都是 try 3，说明 WARP 在持续抖，该考虑换 endpoint 了。

### 3.3 状态机：连续失败才升级

单次 FAIL 可能是抖动，不该立即告警。脚本维护 `fail_streak` 状态：

- 本次 OK → streak 归零
- 本次 FAIL → streak +1

看日志时关注 `streak=N`，N 越大说明持续故障越严重。要做"连续 N 次失败才推送告警"，加一行判断 `if [ $NEW_STREAK -ge 5 ]; then <推送告警>; fi` 即可。

### 3.4 日志策略

每次跑都记一行（含 OK 时的全 OK 行），1000 行轮转 ≈ 3.5 天历史（5 分钟一次 × 288/天）。OK 也记是为了看**趋势**——比如 wireproxy 响应时间从 3s 涨到 8s 是渐进退化，只看 FAIL 发现不了。

## 四、systemd --user service + timer

`~/.config/systemd/user/health-check.service`：

```ini
[Unit]
Description=Lightweight health check (wireproxy/gitea/cloudflared + GitHub via WARP)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/home/wzf/Files/scripts/health-check.sh
StandardOutput=journal
StandardError=journal
Nice=10
```

`~/.config/systemd/user/health-check.timer`：

```ini
[Unit]
Description=Run health check every 5 minutes

[Timer]
# 每 5 分钟跑一次（系统启动 1 分钟后开始，避免和开机服务抢资源）
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=10s
Persistent=true

[Install]
WantedBy=default.target
```

启用：

```bash
systemctl --user daemon-reload
systemctl --user enable --now health-check.timer

# 看下次触发时间
systemctl --user list-timers health-check.timer

# 手动立即跑一次
systemctl --user start health-check.service

# 看日志
journalctl --user -u health-check.service -n 20 --no-pager
```

关键点：

- `Type=oneshot`：跑完就退，不常驻
- `OnUnitActiveSec=5min`：从前一次激活算 5 分钟（比 `OnCalendar=*:0/5` 更精确，不会漂移）
- `OnBootSec=1min`：开机 1 分钟后开始，避开开机服务抢资源
- `Persistent=true`：错过的窗口在下次开机补跑
- `Nice=10`：低优先级，不抢前台
- 日志走 journal + 同时写 `~/Files/monitor/health.log`（journal 给 systemd 视角，文件给历史趋势）

## 五、整条链路

{{< mermaid >}}
graph TD
    A[systemd timer 每 5 分钟触发] --> B[health-check.service oneshot]
    B --> C[health-check.sh]
    C --> D1[check wireproxy<br/>curl SOCKS5→github 重试3次]
    C --> D2[check gitea<br/>curl 127.0.0.1:3000]
    C --> D3[check cloudflared<br/>is-active + 1313端口]
    C --> D4[check sd_wireproxy/sd_gitea<br/>systemctl is-active]
    D1 --> E{全部 OK?}
    D2 --> E
    D3 --> E
    D4 --> E
    E -->|是| F[streak=0<br/>写一行 OK 到 health.log]
    E -->|否| G[streak+1<br/>写一行 FAIL 含详情]
    F --> H[轮转保留最近 1000 行]
    G --> H
    H --> I[3.5 天历史趋势]
    I --> J[运维人 tail/grep 看]
    J --> K{streak >= 5?}
    K -->|是| L[持续故障 升级处理]
    K -->|否| M[继续观察]
{{< /mermaid >}}

## 六、实际数据：WARP 抖动案例

部署完跑了 3 次（手动 2 次 + timer 触发 1 次），日志：

```
2026-08-25T16:13:33+08:00 wireproxy=OK(3.640788s (try 1)) gitea=OK(HTTP 200) cloudflared=OK(active+1313) sd_wireproxy=OK(active) sd_gitea=OK(active) streak=0
2026-08-25T16:13:37+08:00 wireproxy=OK(3.384693s (try 1)) gitea=OK(HTTP 200) cloudflared=OK(active+1313) sd_wireproxy=OK(active) sd_gitea=OK(active) streak=0
2026-08-25T16:14:14+08:00 wireproxy=OK(4.296501s (try 3)) gitea=OK(HTTP 200) cloudflared=OK(active+1313) sd_wireproxy=OK(active) sd_gitea=OK(active) streak=0
```

第 3 行 `(try 3)` 暴露了 WARP 抖动——systemd 触发那次，前 2 次 curl 超时，第 3 次才成功（4.3s）。如果没重试机制，这次会记 FAIL，streak 升到 1，5 分钟后再跑可能又 OK 归零，但日志里就有了一条假 FAIL。

部署前我做了一个对照实验，连续手动 curl 3 次确认抖动确实存在：

```
--- 第 1 次 --- code=200 time=3.687319s
--- 第 2 次 --- curl: (28) Connection timed out after 5002 milliseconds
--- 第 3 次 --- code=200 time=3.751089s
```

3 次里 1 次超时——这正是 `push.sh` 设计 5 次重试的原因，也是这个监控脚本设计 3 次重试的原因。**实战数据驱动设计**，不是拍脑袋。

## 七、看日志的姿势

```bash
# 最近 20 行
tail -n 20 ~/Files/monitor/health.log

# 只看 FAIL 行（含 streak 升级）
grep FAIL ~/Files/monitor/monitor/health.log

# 看 wireproxy 响应时间趋势（提 try 次数 + time）
grep -oE 'wireproxy=OK\([^)]+\)' ~/Files/monitor/health.log | tail -50

# 看连续故障（streak >= 2）
grep -E 'streak=[2-9]' ~/Files/monitor/health.log

# 看今天某段时间
grep '2026-08-25T1[5-6]' ~/Files/monitor/health.log
```

journal 视角（systemd 触发记录）：

```bash
journalctl --user -u health-check.service --since today
journalctl --user -u health-check.service -f   # 实时跟随
```

## 八、设计取舍

1. **bash 而非 uptime-kuma**：家用自看场景，零依赖 + oneshot 跑完即退，比 Node.js 长驻进程轻得多。需要推送告警再上 healthchecks.io 或 uptime-kuma。
2. **真实 curl 外网而非端口检查**：wireproxy 端口在 ≠ WARP 隧道活着，必须真 curl 外网才确认。代价是单次检查 ~10s + 耗外网流量，5 分钟一次可接受。
3. **重试 3 次过滤抖动**：WARP 实测有 ~30% 概率超时，单次测试会大量误报，重试后误报率降到 ~3%。
4. **streak 状态机而非单次告警**：单次 FAIL 可能抖动，连续 N 次才有意义；状态机让"持续故障"和"瞬时抖动"在日志里可区分。
5. **OK 也记日志**：看趋势（响应时间渐进退化）必须看 OK 行，只记 FAIL 看不到渐进问题。
6. **systemd timer 而非 cron**：和现有 wireproxy/gitea/cloudflared 一套体系，`journalctl --user` 统一管。
7. **Nice=10 低优先级**：curl 外网可能慢，不抢前台 IO/CPU。

> 这套监控跑在写这篇博文的那台家用主机上——`~/Files/scripts/health-check.sh` + `~/.config/systemd/user/health-check.{service,timer}`。每 5 分钟跑一次，3.5 天滚动历史。要看就 `tail ~/Files/monitor/health.log`，不想看就不看，systemd 自己记 journal。
