#!/bin/bash
# linux-projects 一键部署脚本
# 作用：把仓库里的 scripts/ + systemd/ 部署到当前用户家目录
#   - scripts/health-check.sh   →  ~/Files/scripts/health-check.sh
#   - systemd/*.service|timer   →  ~/.config/systemd/user/
#   - 替换 unit 文件里的 /home/wzf/ 为当前 $HOME（保证可移植）
#   - systemctl --user daemon-reload + enable + start
#
# 用法：
#   ./install.sh             # 全部部署
#   ./install.sh --dry-run   # 只打印要做什么，不实际执行
#
# 前置条件：
#   - 当前用户在 sudoers（需要 sudo loginctl enable-linger 一次，让用户服务开机自启）
#   - 已安装：wireproxy / gitea / cloudflared / hugo（各服务二进制路径在 systemd/*.service 里）
#   - 如果某个服务二进制不在，对应 unit 启动会失败，不影响其他服务

set -euo pipefail

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

# 仓库根目录（脚本所在目录的父目录 = 仓库根）
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_SRC="$REPO_ROOT/scripts"
SYSTEMD_SRC="$REPO_ROOT/systemd"

# 目标路径
USER_HOME="$HOME"
SCRIPTS_DST="$USER_HOME/Files/scripts"
SYSTEMD_DST="$USER_HOME/.config/systemd/user"

echo "[install] 仓库根目录: $REPO_ROOT"
echo "[install] 用户家目录: $USER_HOME"
[ "$DRY_RUN" = "true" ] && echo "[install] --dry-run 模式：只打印不执行"

# 1. 部署 scripts/
echo
echo "=== 1. 部署 scripts/ ==="
mkdir -p "$SCRIPTS_DST"
for f in "$SCRIPTS_SRC"/*.sh; do
    name=$(basename "$f")
    dst="$SCRIPTS_DST/$name"
    echo "  $f → $dst"
    if [ "$DRY_RUN" = "false" ]; then
        cp "$f" "$dst"
        chmod +x "$dst"
    fi
done

# 2. 部署 systemd/ unit 文件（替换 /home/wzf/ 为当前 $HOME）
echo
echo "=== 2. 部署 systemd/ ==="
mkdir -p "$SYSTEMD_DST"
for f in "$SYSTEMD_SRC"/*.service "$SYSTEMD_SRC"/*.timer; do
    [ -e "$f" ] || continue
    name=$(basename "$f")
    dst="$SYSTEMD_DST/$name"
    echo "  $f → $dst (替换 /home/wzf/ → $USER_HOME/)"
    if [ "$DRY_RUN" = "false" ]; then
        # 替换硬编码路径为当前用户家目录
        sed "s|/home/wzf/|$USER_HOME/|g" "$f" > "$dst"
    fi
done

# 3. systemd daemon-reload + enable + start
echo
echo "=== 3. systemctl --user daemon-reload + enable + start ==="
if [ "$DRY_RUN" = "false" ]; then
    systemctl --user daemon-reload
    echo "  daemon-reload 完成"
fi

# 服务列表（真跑时只 enable 已存在的 unit，不存在的跳过避免报错；dry-run 不检查目标文件）
SERVICES=(wireproxy-warp gitea cloudflared health-check.timer)
for svc in "${SERVICES[@]}"; do
    if [ "$DRY_RUN" = "false" ]; then
        unit="$SYSTEMD_DST/$svc"
        if [ ! -f "$unit" ] && [ "$svc" != "health-check.timer" ]; then
            echo "  [skip] $svc: unit 文件不存在（可能对应的二进制没装）"
            continue
        fi
    fi
    echo "  enable + start: $svc"
    if [ "$DRY_RUN" = "false" ]; then
        systemctl --user enable "$svc" 2>&1 | sed 's/^/    /' || true
        # health-check.timer 用 start，其他 .service 用 start（应该 enabled 即可，但显式 start 一次更直观）
        systemctl --user start "$svc" 2>&1 | sed 's/^/    /' || echo "    [warn] $svc start 失败（可能二进制路径不对，看 systemctl --user status $svc）"
    fi
done

# 4. 提示 enable-linger（只提示，不自动 sudo）
echo
echo "=== 4. enable-linger 检查 ==="
LINGER_STATUS=$(loginctl show-user "$USER" -p Linger 2>/dev/null | cut -d= -f2)
if [ "$LINGER_STATUS" = "yes" ]; then
    echo "  Linger=yes ✓ 用户服务开机自启已开启"
else
    echo "  Linger=no ✗ 用户不登录时 user 服务不会跑"
    echo "  解决：sudo loginctl enable-linger \$USER"
    echo "  （只跑一次，跑过后所有 enabled 的 user 服务开机自启）"
fi

echo
echo "=== 完成 ==="
echo "验证：systemctl --user list-units --type=service --state=running"
echo "日志：journalctl --user -u <服务名> -f"
echo "健康检查：tail -f ~/Files/monitor/health.log"
