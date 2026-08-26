#!/bin/bash
# SSH 加固一键部署脚本（默认 dry-run）
# 用法:
#   ./apply.sh --dry-run   # 只看会做什么，不改任何配置
#   ./apply.sh            # 真正部署配置 + reload ssh + 启用 fail2ban + ufw allow
#
# ⚠️ 注意:
#   1. 需要 sudo 权限
#   2. 改 sshd Port 前会自动 ufw allow 新端口，但不会主动 ufw enable（避免锁死）
#   3. 部署前请保留一个 SSH 会话别退出，避免配置错误锁死自己
#   4. 端口由 hardening.conf 里的 Port 决定，本脚本读该值

set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSHD_SRC="$SCRIPT_DIR/sshd_config.d/hardening.conf"
SSHD_DST="/etc/ssh/sshd_config.d/hardening.conf"
FAIL2BAN_SRC="$SCRIPT_DIR/fail2ban/jail.local"
FAIL2BAN_DST="/etc/fail2ban/jail.local"

# 从 hardening.conf 提取 Port
NEW_PORT=$(grep -E '^Port\s+' "$SSHD_SRC" | awk '{print $2}')
if [[ -z "$NEW_PORT" ]]; then
    NEW_PORT=22
    echo "[WARN] hardening.conf 未设 Port，默认 22"
fi

echo "============================================"
echo " SSH 加固部署 (DRY_RUN=$DRY_RUN)"
echo " 目标端口: $NEW_PORT"
echo "============================================"

# ---------- 1. 检查 openssh-server ----------
echo "[1/5] 检查 openssh-server"
if ! dpkg -l openssh-server 2>/dev/null | grep -q '^ii'; then
    echo "ERROR: openssh-server 未安装，请先 sudo apt install openssh-server"
    exit 1
fi
echo "  ✓ openssh-server 已装"

# ---------- 2. 部署 sshd_config.d/hardening.conf ----------
echo "[2/5] 部署 sshd_config.d/hardening.conf"
if $DRY_RUN; then
    if [[ -f "$SSHD_DST" ]]; then
        echo "  --- 当前 vs 新配置 diff ---"
        diff -u "$SSHD_DST" "$SSHD_SRC" || true
    else
        echo "  (目标 $SSHD_DST 不存在，将新建)"
    fi
    echo "  (dry-run) 会复制到 $SSHD_DST"
else
    sudo install -m 644 "$SSHD_SRC" "$SSHD_DST"
    echo "  ✓ 已复制到 $SSHD_DST"
    echo "  -> sshd -t 语法检查"
    if ! sudo sshd -t; then
        echo "ERROR: sshd -t 失败，请检查配置，原配置可能仍是旧的"
        sudo rm -f "$SSHD_DST"
        exit 1
    fi
    echo "  ✓ 语法 OK"
    sudo systemctl reload ssh
    echo "  ✓ reload ssh 完成"
fi

# ---------- 3. 部署 fail2ban ----------
echo "[3/5] 部署 fail2ban jail.local"
if $DRY_RUN; then
    if ! dpkg -l fail2ban 2>/dev/null | grep -q '^ii'; then
        echo "  (fail2ban 未装，dry-run 会执行: apt install -y fail2ban)"
    else
        echo "  --- 当前 vs 新配置 diff ---"
        diff -u "$FAIL2BAN_DST" "$FAIL2BAN_SRC" 2>/dev/null || true
    fi
    echo "  (dry-run) 会复制到 $FAIL2BAN_DST"
else
    if ! dpkg -l fail2ban 2>/dev/null | grep -q '^ii'; then
        sudo apt update
        sudo apt install -y fail2ban
    fi
    sudo install -m 644 "$FAIL2BAN_SRC" "$FAIL2BAN_DST"
    sudo systemctl enable --now fail2ban
    sudo systemctl restart fail2ban
    echo "  ✓ fail2ban 启用并重启"
fi

# ---------- 4. ufw 放行新端口 ----------
echo "[4/5] ufw 放行端口 $NEW_PORT"
if $DRY_RUN; then
    echo "  (dry-run) 会执行: ufw allow $NEW_PORT/tcp"
else
    sudo ufw allow "$NEW_PORT/tcp"
    echo "  ✓ ufw allow $NEW_PORT/tcp"
    echo "  注意：不会主动 ufw enable（避免锁死），如需启用请手动确认已 allow 所有需要的端口"
fi

# ---------- 5. 提示下一步 ----------
echo "[5/5] 下一步手动操作"
cat <<EOF

完成。建议下一步：

1. 在【另一个新终端】测试新端口登录：
   ssh -p $NEW_PORT \$(whoami)@localhost

2. 确认能登录后，关闭 22 端口（如果 hardening.conf 改了端口）：
   sudo ufw delete allow 22/tcp

3. 验证 sshd 配置生效：
   sudo sshd -T | grep -E 'permitrootlogin|passwordauthentication|maxauthtries'
   sudo fail2ban-client status sshd
   sudo ufw status verbose

4. 看最近 SSH 失败日志（fail2ban 工作 1 小时后查）：
   journalctl -u ssh --since '1 hour ago' | grep -cE 'Failed|Invalid'
   sudo fail2ban-client status sshd
EOF

if $DRY_RUN; then
    echo ""
    echo "（dry-run 模式，未执行任何修改）"
fi
