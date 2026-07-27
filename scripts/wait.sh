#!/usr/bin/env bash
# wait —— 等待 Codex 对 PR 的再审。以最后一次 push 为锚,按 4 状态机轮询到通过信号或新意见。
#
# 四状态机(转移全部由 API 查询结果驱动,sleep 仅做 rate limiting):
#   S0(IDLE) ── eyes 出现 ──→ S1(WAITING)
#   S0 ── 👍 ──→ S2(PASS)
#   S0 ── 新评论 ──→ S3(NEW_COMMENTS)
#   S0 ── 超时(默认 120s) ──→ S2(PASS: Codex 无需再审)
#   S1 ── eyes 还在 ──→ S1
#   S1 ── 👍 ──→ S2
#   S1 ── eyes 消失 + 无新评论 ──→ S2
#   S1 ── eyes 消失 + 有新评论 ──→ S3
#
# 退出码:
#   0  通过(S2)
#   10 有新意见(S3),交回 agent triage
#   30 参数/前置错误
#   31 gh 连续 5 次失败(弱网)
set -uo pipefail

usage() {
  cat <<'EOF'
用法: wait <PR> [选项]
  <PR>                    PR 编号(位置参数,或 --pr)
  --since <ISO8601>       锚点时间(默认: PR 最新 commit 的 committedDate)
  --s0-timeout <sec>      S0 超时退出(默认 120;Codex 不贴 eyes/👍/评论=认为无需再审)
  --interval <sec>        轮询间隔(默认 15;ETag 下没变化是 304,几乎免费)
  --repo <owner>/<repo>   仓库(默认: 当前 git remote 推断)
EOF
}

PR=""
SINCE=""
S0_TIMEOUT=120
INTERVAL=15
REPO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --pr)         PR="$2"; shift 2;;
    --since)      SINCE="$2"; shift 2;;
    --s0-timeout) S0_TIMEOUT="$2"; shift 2;;
    --interval)   INTERVAL="$2"; shift 2;;
    --repo)       REPO="$2"; shift 2;;
    -h|--help)    usage; exit 0;;
    *) if [ -z "$PR" ] && [[ "$1" =~ ^[0-9]+$ ]]; then PR="$1"; shift
       else echo "未知参数: $1" >&2; usage >&2; exit 30; fi;;
  esac
done

[ -n "$PR" ] || { echo "ERROR: 缺少 PR 编号" >&2; usage >&2; exit 30; }

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) \
    || { echo "ERROR: 无法解析当前仓库(gh repo view 失败)" >&2; exit 30; }
fi
owner=${REPO%%/*}
repo=${REPO#*/}

# 锚点回退链: commits[-1].committedDate → updatedAt → 当前时刻
if [ -z "$SINCE" ]; then
  SINCE=$(gh pr view "$PR" --json commits --jq '.commits[-1].committedDate' 2>/dev/null || true)
fi
if [ -z "$SINCE" ]; then
  SINCE=$(gh pr view "$PR" --json updatedAt --jq '.updatedAt' 2>/dev/null || true)
fi
if [ -z "$SINCE" ]; then
  SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi

printf '▶ 轮询 %s/%s #%s\n  锚点 since=%s\n  interval=%ss\n' \
  "$owner" "$repo" "$PR" "$SINCE" "$INTERVAL"
printf '▶ 状态机: S0(IDLE) → S1(WAITING) → S2(PASS) | S3(NEW_COMMENTS)\n'

# 预取 GitHub token 一次,供内嵌 Python fetcher 的 curl 复用
CODX_GH_TOKEN=$(gh auth token 2>/dev/null) \
  || { echo "ERROR: gh auth token 失败(gh 未认证?)" >&2; exit 30; }
export CODX_GH_TOKEN

# ── 内嵌 Python fetcher ──────────────────────────────────────────────
# 每轮被 bash 调用;输出 key=value 行供 bash 解析。
# 负责: ETag 条件请求 + 文件缓存 + 单次判定(eyes/plus1/new_comments)。
# 不负责: sleep、状态机转移——这些归外层 bash。
run_fetcher() {
  python3 - "$@" <<'PYEOF'
import datetime, json, os, subprocess, sys, tempfile

owner, repo, pr, since = sys.argv[1:5]
token = os.environ.get("CODX_GH_TOKEN")
if not token:
    print("ERROR=缺少 CODX_GH_TOKEN")
    sys.exit(3)

API = "https://api.github.com"
CACHE_DIR = os.path.join(tempfile.gettempdir(), "codex-pr-review")
os.makedirs(CACHE_DIR, exist_ok=True)
CACHE_FILE = os.path.join(CACHE_DIR, f"{owner}-{repo}-{pr}.json")

def load_cache():
    try:
        with open(CACHE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}

def save_cache(c):
    try:
        with open(CACHE_FILE, "w") as f:
            json.dump(c, f)
    except Exception:
        pass

def dt(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))

def fetch(key, path, cache):
    url = f"{API}{path}"
    etag = cache.get(key, {}).get("etag")
    hdr_file = os.path.join(CACHE_DIR, f".{key}.hdr")
    body_file = os.path.join(CACHE_DIR, f".{key}.body")
    cmd = ["curl", "-sS",
           "-D", hdr_file, "-o", body_file, "-w", "%{http_code}",
           "-H", f"Authorization: Bearer {token}",
           "-H", "Accept: application/vnd.github+json",
           "-H", "X-GitHub-Api-Version: 2022-11-28"]
    if etag:
        cmd += ["-H", f"If-None-Match: {etag}"]
    cmd.append(url)
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        return None, f"curl rc={r.returncode}: {(r.stderr or '').strip()[:120]}"
    code = (r.stdout or "").strip()
    new_etag = etag
    try:
        with open(hdr_file) as f:
            for line in f:
                if line.lower().startswith("etag:"):
                    new_etag = line.split(":", 1)[1].strip()
                    break
    except Exception:
        pass
    if code == "304":
        body = cache.get(key, {}).get("body")
        return (body if body is not None else []), None
    if code == "200":
        try:
            with open(body_file) as f:
                body = json.load(f)
        except Exception as e:
            return None, f"parse {e}"
        cache[key] = {"etag": new_etag, "body": body}
        return body, None
    return None, f"http {code}"

cache = load_cache()
reactions, err = fetch("reactions", f"/repos/{owner}/{repo}/issues/{pr}/reactions", cache)
if reactions is None:
    save_cache(cache)
    print(f"ERROR={err}")
    sys.exit(3)

comments, err = fetch("comments", f"/repos/{owner}/{repo}/pulls/{pr}/comments", cache)
if comments is None:
    save_cache(cache)
    print(f"ERROR={err}")
    sys.exit(3)

save_cache(cache)

since_dt = dt(since)
eyes_now = "yes" if any(r.get("content") == "eyes" for r in reactions) else "no"
plus1_list = [r for r in reactions if r.get("content") == "+1" and dt(r["created_at"]) >= since_dt]
new_comments = [c for c in comments if dt(c["created_at"]) >= since_dt]
plus1_who = (plus1_list[-1].get("user", {}).get("login", "?") if plus1_list else "")

print(f"EYES={eyes_now}")
print(f"PLUS1={plus1_who}")
print(f"NEW_COUNT={len(new_comments)}")
print(f"REACTIONS_TOTAL={len(reactions)}")
print(f"ELAPSED={int((datetime.datetime.now(datetime.timezone.utc) - since_dt).total_seconds())}")
PYEOF
}

# ── 状态机主循环(bash) ──────────────────────────────────────────────

state="S0"        # S0=IDLE  S1=WAITING  S2=PASS  S3=NEW_COMMENTS
fail_streak=0
first=1

while :; do
  # ── sleep: 仅 rate limiting,不参与状态转移 ──
  if [ "$first" = "1" ]; then first=0; else sleep "$INTERVAL"; fi

  # 调用内嵌 Python fetcher,输出 key=value 行
  fetcher_out=$(run_fetcher "$owner" "$repo" "$PR" "$SINCE" 2>&1)
  frc=$?

  if [ "$frc" -ne 0 ]; then
    fail_streak=$((fail_streak + 1))
    err_msg=$(printf '%s' "$fetcher_out" | grep '^ERROR=' | cut -d= -f2-)
    ts=$(date +%H:%M:%S)
    echo "  [$ts] [$state] ⚠ network($fail_streak): ${err_msg:-rc=$frc}"
    if [ "$fail_streak" -ge 5 ]; then
      echo "✗ 连续 5 次失败,放弃(弱网?)" >&2
      exit 31
    fi
    continue
  fi
  fail_streak=0

  # 解析 fetcher 输出
  eyes=$(printf '%s' "$fetcher_out"    | grep '^EYES='       | cut -d= -f2)
  plus1=$(printf '%s' "$fetcher_out"   | grep '^PLUS1='      | cut -d= -f2)
  new_count=$(printf '%s' "$fetcher_out" | grep '^NEW_COUNT='  | cut -d= -f2)
  elapsed=$(printf '%s' "$fetcher_out"  | grep '^ELAPSED='    | cut -d= -f2)

  [ -n "$eyes" ]      || eyes=no
  [ -n "$new_count" ] || new_count=0
  [ -n "$elapsed" ]   || elapsed=0
  ts=$(date +%H:%M:%S)

  # ── 状态转移(不依赖时间,全由 API 查询结果驱动) ──

  if [ "$state" = "S0" ]; then
    # S0: 等待 Codex 开始
    if [ "$eyes" = "yes" ]; then
      echo "  [$ts] [S0→S1] eyes 出现,Codex 开始审查"
      state="S1"
    elif [ -n "$plus1" ]; then
      echo "  [$ts] [S0→S2] ✅ 👍 by $plus1 —— 通过"
      exit 0
    elif [ "$new_count" -gt 0 ]; then
      echo "  [$ts] [S0→S3] 📌 ${new_count} 条新评论 —— 回 triage"
      exit 10
    elif [ "$elapsed" -ge "$S0_TIMEOUT" ]; then
      echo "  [$ts] [S0→S2] ✅ S0 超时 ${elapsed}s(limit=${S0_TIMEOUT}s),Codex 认为无需再审 —— 通过"
      exit 0
    else
      echo "  [$ts] [S0] eyes=no  elapsed=${elapsed}s  等待 Codex 开始…"
    fi

  elif [ "$state" = "S1" ]; then
    # S1: Codex 审查中(已确认 eyes 存在过)
    if [ "$eyes" = "yes" ]; then
      echo "  [$ts] [S1] eyes=yes  Codex 审查中…"
    elif [ -n "$plus1" ]; then
      echo "  [$ts] [S1→S2] ✅ 👍 by $plus1 —— 通过"
      exit 0
    elif [ "$new_count" -eq 0 ]; then
      # eyes 消失 + 无新评论 = 审完且无意见
      echo "  [$ts] [S1→S2] ✅ eyes 消失且无新评论 —— 通过"
      exit 0
    else
      # eyes 消失 + 有新评论 = 审完且有意见
      echo "  [$ts] [S1→S3] 📌 eyes 消失,${new_count} 条新评论 —— 回 triage"
      exit 10
    fi
  fi
done
