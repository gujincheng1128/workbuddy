#!/bin/bash
# 龙儿剪辑 LongCut —— 一键连接 GitHub 并推送本地 main。
# 仅依赖「仓库地址」；作者邮箱可选（不给则用当前占位邮箱）。
#
# 用法:
#   bash tools/connect-github.sh https://github.com/<you>/<repo>.git
#   bash tools/connect-github.sh git@github.com:<you>/<repo>.git
#   bash tools/connect-github.sh <url> -e you@github.email      # 同时改写作者邮箱
#
# 流程: 校验仓库 -> 加/改 origin remote -> (可选) 改写上次提交作者邮箱
#       -> push -u origin main。仅在尚未推送时执行 amend，安全。
set -euo pipefail

PRJ="${LONGCUT_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)}"
URL=""
EMAIL=""

# ---- 参数解析 ----
while [ $# -gt 0 ]; do
  case "$1" in
    -e|--email) EMAIL="${2:-}"; shift 2 ;;
    -h|--help)  sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)          URL="$1"; shift ;;
  esac
done

if [ -z "$URL" ]; then
  echo "用法: bash tools/connect-github.sh <github-repo-url> [-e you@github.email]" >&2
  exit 1
fi

cd "$PRJ"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "FATAL: $PRJ 不是 git 仓库" >&2; exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
REMOTE="origin"

# ---- remote 加/改 ----
if git remote get-url "$REMOTE" >/dev/null 2>&1; then
  echo "[connect] origin 已存在 -> 改为 $URL"
  git remote set-url "$REMOTE" "$URL"
else
  echo "[connect] 新增 remote origin -> $URL"
  git remote add "$REMOTE" "$URL"
fi

# ---- 可选: 改写作者邮箱(未推送前安全) ----
if [ -n "$EMAIL" ]; then
  NAME="$(git log -1 --pretty=%an)"
  git config user.email "$EMAIL"
  git config user.name "$NAME"
  echo "[connect] 改写最近提交作者为 $NAME <$EMAIL>"
  git commit --amend --no-edit --reset-author
fi

# ---- 推送 ----
echo "[connect] 推送 $BRANCH -> $REMOTE ..."
if git push -u "$REMOTE" "$BRANCH" 2>&1; then
  echo "[connect] OK: 已推送。GitHub 上 Actions 将自动跑 windows-gnu CI。"
  echo "[connect] 查看: ${URL%.git}/actions"
else
  RC=$?
  echo "[connect] FAILED (exit $RC)" >&2
  echo "[connect] 常见原因: 仓库非空(含 README/LICENSE 初始提交)-> 先 pull --rebase 或建空仓库;" >&2
  echo "[connect]            权限/SSH key 未配置 -> 改用 HTTPS 或配置 deploy key。" >&2
  exit "$RC"
fi
