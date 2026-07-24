#!/usr/bin/env bash
# poll-until-thumbsup.sh —— 轮询 Codex 对 PR 的再审,直到 issue reactions 出现 👍 才返回。
# 配合 codex-pr-review skill 第 5 步。锚点 = PR 最新 commit 的 committedDate(最后一次 push)。
#
# 退出码(即结论,agent 按此决定下一步):
#   0  通过 —— Codex(chatgpt-codex-connector[bot])的 +1(👍)且无晚于锚点的新行内评论
#   10 有新意见 —— 存在晚于锚点的行内评论,交回 agent triage(回 skill 第 3 步)
#   20 超时 —— 超过 --max-wait 仍未收到 👍
#   30 参数/前置错误
#   31 gh 连续失败(弱网)
set -uo pipefail

usage() {
  cat <<'EOF'
用法: poll-until-thumbsup.sh <PR> [选项]
  <PR>                    PR 编号(位置参数,或 --pr)
  --since <ISO8601>       锚点时间(默认: PR 最新 commit 的 committedDate)
  --first-wait <sec>      首次等待(默认 240;Codex 单次 review 4-6 分钟,不会更快)
  --interval <sec>        后续轮询间隔(默认 60)
  --max-wait <sec>        最大总等待(默认 3600)
  --repo <owner>/<repo>   仓库(默认: 当前 git remote 推断)
EOF
}

PR=""
SINCE=""
FIRST_WAIT=240
INTERVAL=60
MAX_WAIT=3600
REPO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --pr)         PR="$2"; shift 2;;
    --since)      SINCE="$2"; shift 2;;
    --first-wait) FIRST_WAIT="$2"; shift 2;;
    --interval)   INTERVAL="$2"; shift 2;;
    --max-wait)   MAX_WAIT="$2"; shift 2;;
    --repo)       REPO="$2"; shift 2;;
    -h|--help)    usage; exit 0;;
    *) if [ -z "$PR" ] && [[ "$1" =~ ^[0-9]+$ ]]; then PR="$1"; shift
       else echo "未知参数: $1" >&2; usage >&2; exit 30; fi;;
  esac
done

[ -n "$PR" ] || { echo "ERROR: 缺少 PR 编号" >&2; usage >&2; exit 30; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JUDGE="$DIR/_judge.py"
[ -f "$JUDGE" ] || { echo "ERROR: 找不到 $JUDGE" >&2; exit 30; }

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) \
    || { echo "ERROR: 无法解析当前仓库(gh repo view 失败)" >&2; exit 30; }
fi
owner=${REPO%%/*}
repo=${REPO#*/}

# 锚点:最后一次 push。优先用最新 commit 的 committedDate;拿不到再退到 updatedAt;再退到当前时刻。
if [ -z "$SINCE" ]; then
  SINCE=$(gh pr view "$PR" --json commits --jq '.commits[-1].committedDate' 2>/dev/null || true)
fi
if [ -z "$SINCE" ]; then
  SINCE=$(gh pr view "$PR" --json updatedAt --jq '.updatedAt' 2>/dev/null || true)
fi
if [ -z "$SINCE" ]; then
  SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi

printf '▶ 轮询 %s/%s #%s\n  锚点 since=%s\n  首等=%ss  间隔=%ss  上限=%ss\n' \
  "$owner" "$repo" "$PR" "$SINCE" "$FIRST_WAIT" "$INTERVAL" "$MAX_WAIT"

deadline=$(( $(date +%s) + MAX_WAIT ))
fail_streak=0
first=1

while :; do
  if [ "$first" = "1" ]; then sleep "$FIRST_WAIT"; first=0
  else sleep "$INTERVAL"; fi

  out=$(python3 "$JUDGE" "$owner" "$repo" "$PR" "$SINCE" 2>&1)
  rc=$?

  if [ "$rc" -eq 3 ]; then
    fail_streak=$((fail_streak + 1))
    echo "  ⚠ 网络抖动($fail_streak): $out"
    if [ "$fail_streak" -ge 5 ]; then
      echo "✗ 连续 5 次 gh 调用失败,放弃(弱网?)" >&2
      exit 31
    fi
    continue
  fi
  fail_streak=0

  if [ "$rc" -ne 0 ]; then
    echo "✗ 判定脚本异常 rc=$rc: $out" >&2
    exit 30
  fi

  ts=$(date +%H:%M:%S)
  case "$out" in
    STATE=thumbsup*)     echo "[$ts] ✅ $out"; exit 0 ;;
    STATE=new_comments*) echo "[$ts] 📌 $out —— 有新意见,回 triage"; exit 10 ;;
    STATE=waiting*)      echo "[$ts] $out" ;;
    *)                   echo "[$ts] ? 未识别: $out" >&2 ;;
  esac

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "✗ 超过 ${MAX_WAIT}s 未收到 👍,超时。用三端点命令人工核查 Codex 是否在跑(eyes 是否还在)。" >&2
    exit 20
  fi
done
