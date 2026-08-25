#!/bin/bash
# ~/Files/scripts/health-check.sh
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

# 当前时间（ISO 8601 + 时区）
now_iso() { date '+%Y-%m-%dT%H:%M:%S%:z'; }

# 结果聚合
RESULTS=()
FAIL_COUNT=0

# 单项检查：check <name> <test_command>
# test_command 退出码 0=OK，非 0=FAIL；stdout 第一行作为附加信息
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

# === 检查项 ===

# 1. wireproxy SOCKS5 1080：通过它访问 GitHub，测代理真能用（不只测端口在不在）
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

# 2. gitea HTTP 3000：测 Web 能响应（本地直连，不耗外网）
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

# 4. systemd --user 三服务的 active 状态（汇总，便于一眼看）
check "sd_wireproxy" bash -c '
    [ "$(systemctl --user is-active wireproxy-warp 2>/dev/null)" = "active" ] \
        && echo active || exit 1
'
check "sd_gitea" bash -c '
    [ "$(systemctl --user is-active gitea 2>/dev/null)" = "active" ] \
        && echo active || exit 1
'

# === 失败计数 + 告警门槛 ===

# 简单状态机：当前 FAIL 累计到 state 文件，连续 N 次才升级为 WARN
STATE_FAIL=$(cat "$STATE_FILE" 2>/dev/null | grep -E '^fail_streak=' | cut -d= -f2)
STATE_FAIL=${STATE_FAIL:-0}

if [ "$FAIL_COUNT" -gt 0 ]; then
    NEW_STREAK=$((STATE_FAIL+1))
else
    NEW_STREAK=0
fi

# 写状态
cat > "$STATE_FILE" <<EOF
last_check=$(now_iso)
fail_streak=$NEW_STREAK
last_fail_count=$FAIL_COUNT
EOF

# === 日志策略 ===
# 每次都记一行；FAIL 立即记（含详情），OK 也记（看趋势）
# 1000 行轮转 ≈ 3.5 天历史（5 分钟一次 × 288/天）
TS=$(now_iso)
LINE="$TS ${RESULTS[*]} streak=$NEW_STREAK"
echo "$LINE" >> "$LOG_FILE"

# 保留最近 MAX_LOG_LINES 行
if [ -f "$LOG_FILE" ]; then
    tmp=$(tail -n "$MAX_LOG_LINES" "$LOG_FILE")
    echo "$tmp" > "$LOG_FILE"
fi
