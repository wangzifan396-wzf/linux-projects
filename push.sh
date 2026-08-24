#!/bin/bash
# 一键 commit + push 到 GitHub linux-projects
# 用法：
#   ./push.sh                          # 默认 commit 信息
#   ./push.sh "改了某功能"               # 自定义 commit 信息
cd "$(dirname "$0")" || exit 1

MSG="${1:-update: $(date '+%Y-%m-%d %H:%M:%S')}"

git add .
git commit -m "$MSG" || true

# 国内访问 GitHub 抽风，最多重试 5 次
for i in 1 2 3 4 5; do
    echo "[push] 第 $i 次尝试..."
    if git push origin main 2>&1; then
        echo "[push] 成功！"
        exit 0
    fi
    echo "[push] 第 $i 次失败，2 秒后重试..."
    sleep 2
done

echo "[push] 5 次都失败，可能网络不行，稍后再试。"
exit 1
