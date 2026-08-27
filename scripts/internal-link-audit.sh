#!/usr/bin/env bash
# 博文内链审计脚本
# 作用：
#   1) 死链检测 —— 任何 /posts/<slug>/ 引用必须指向真实存在的博文文件，否则 CI 失败
#   2) 孤立检测 —— 每篇博文应至少有 1 条来自其它博文的入站链接（仅警告，不阻断）
# 用法：
#   bash scripts/internal-link-audit.sh                # 默认扫 content/posts
#   bash scripts/internal-link-audit.sh content/posts  # 显式指定目录
# 退出码：发现死链 -> 1；仅孤立/全正常 -> 0
set -uo pipefail

POSTS_DIR="${1:-content/posts}"
if [ ! -d "$POSTS_DIR" ]; then
  echo "目录不存在: $POSTS_DIR" >&2
  exit 2
fi

# 收集所有有效 slug（文件名去 .md）
mapfile -t FILES < <(find "$POSTS_DIR" -maxdepth 1 -name '*.md' | sort)
declare -A slug_file
for f in "${FILES[@]}"; do
  slug=$(basename "$f" .md)
  slug_file[$slug]="$f"
done

errors=0
warnings=0
declare -A inbound

# 1) 死链检测 + 2) 入站计数
for f in "${FILES[@]}"; do
  slug=$(basename "$f" .md)
  while IFS=: read -r line ref; do
    [ -z "$ref" ] && continue
    target=${ref#/posts/}
    target=${target%/}                     # 去掉前缀 /posts/ 与结尾 /
    [ -z "$target" ] && continue
    if [ -z "${slug_file[$target]:-}" ]; then
      echo "  [死链] $f:$line -> $ref (目标博文不存在)"
      errors=$((errors + 1))
    elif [ "$target" != "$slug" ]; then
      inbound[$target]=$(( ${inbound[$target]:-0} + 1 ))
    fi
  done < <(grep -nonE "/posts/[a-zA-Z0-9_-]+/" "$f" 2>/dev/null)
done

# 3) 孤立检测（入站为 0）
for s in "${!slug_file[@]}"; do
  cnt=${inbound[$s]:-0}
  if [ "$cnt" -eq 0 ]; then
    echo "  [孤立] $s 没有任何其它博文链接到它"
    warnings=$((warnings + 1))
  fi
done

echo "------------------------------------------------"
echo "有效博文: ${#slug_file[@]}  死链: $errors  孤立: $warnings"
if [ "$errors" -gt 0 ]; then
  echo "❌ 存在死链，请修复后再合并"
  exit 1
fi
if [ "$warnings" -gt 0 ]; then
  echo "⚠️  存在孤立博文（仅警告，不阻断构建）"
fi
echo "✅ 内链审计通过"
exit 0
