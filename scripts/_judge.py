#!/usr/bin/env python3
"""单次判定 Codex 对 PR 本轮审查的状态。供 wait 调用。

传输层用 curl + gh token,不用 gh api —— gh api 不透传 If-None-Match,拿不到 304
(实测它对 conditional header 返回 200 + 完整 body)。改用 curl 后:
  - 带 If-None-Match 条件请求;资源没变 GitHub 返回 304(不计 rate limit、无 body)
  - 304 时复用上次缓存的 body 判定 —— 结果与上次该端点的判定完全等价,但零传输/零解析
  - 200 时更新缓存的 etag + body
这就是把轮询变"廉价"的关键:绝大多数轮次 Codex 还在审,两个端点都没变,全是 304。

argv: owner repo pr since(ISO8601,锚点=最后一次 push)
env:  CODX_GH_TOKEN  必填(外层从 `gh auth token` 预取一次)
stdout: 一行 "STATE=thumbsup|new_comments|waiting ..." 且恒带 eyes=yes|no
exit: 0 正常判定(看 STATE); 3 网络/HTTP 异常(外层 sleep 后重试,不直接判败)
"""
import datetime
import json
import os
import subprocess
import sys
import tempfile

owner, repo, pr, since = sys.argv[1:5]
token = os.environ.get("CODX_GH_TOKEN")
if not token:
    print("STATE=error 缺少 CODX_GH_TOKEN(外层需 export `gh auth token` 的输出)")
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
        pass  # 缓存写失败不影响判定,顶多下次多一次 200


def dt(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))


def fetch(key, path, cache):
    """带 ETag 条件请求一个端点。返回 (data_or_None, err)。
    304 → 复用缓存 body(与上次该端点判定等价); 200 → 更新缓存; 网络/HTTP 异常 → err。
    """
    url = f"{API}{path}"
    etag = cache.get(key, {}).get("etag")
    cmd = ["curl", "-sS",
           "-D", os.path.join(CACHE_DIR, f".{key}.hdr"),
           "-o", os.path.join(CACHE_DIR, f".{key}.body"),
           "-w", "%{http_code}",
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
        with open(os.path.join(CACHE_DIR, f".{key}.hdr")) as f:
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
            with open(os.path.join(CACHE_DIR, f".{key}.body")) as f:
                body = json.load(f)
        except Exception as e:  # 空 body / 半截 JSON(弱网)
            return None, f"parse {e}"
        cache[key] = {"etag": new_etag, "body": body}
        return body, None
    return None, f"http {code}"  # 429 限流 / 5xx → 交外层重试


cache = load_cache()

reactions, err = fetch("reactions", f"/repos/{owner}/{repo}/issues/{pr}/reactions", cache)
if reactions is None:
    save_cache(cache)
    print(f"STATE=error reactions: {err}")
    sys.exit(3)

comments, err = fetch("comments", f"/repos/{owner}/{repo}/pulls/{pr}/comments", cache)
if comments is None:
    save_cache(cache)
    print(f"STATE=error comments: {err}")
    sys.exit(3)

save_cache(cache)

# ---- 判定(纯逻辑,与 ETag 无关;关键:用 created_at 与锚点比,而非 commit_id) ----
# GitHub 会把旧 inline comment 的 commit_id 静默 re-anchor 到最新 commit,见
# references/endpoints.md 的"commit_id 陷阱"。created_at >= since 才是本轮新评论。
since_dt = dt(since)
new_comments = [c for c in comments if dt(c["created_at"]) >= since_dt]

# 通过信号 1:👍 反应(不限定发送者;只看晚于锚点的 👍,避免把上一轮旧 👍 误当本轮通过)。
plus1 = [r for r in reactions
         if r.get("content") == "+1" and dt(r["created_at"]) >= since_dt]

# eyes = review 者正在审查中的标记。本轮是否仍在(供外层跨轮比对 yes→no 的消失)。
eyes_now = any(r.get("content") == "eyes" for r in reactions)
eyes_str = "yes" if eyes_now else "no"

# 顺序敏感:既有 👍 又有新评论时,说明 👍 是旧的、新意见是新的 → 优先交回 triage。
if new_comments:
    print(f"STATE=new_comments count={len(new_comments)} "
          f"latest={new_comments[-1]['created_at']} eyes={eyes_str}")
elif plus1:
    who = (plus1[-1].get("user") or {}).get("login") or "?"
    print(f"STATE=thumbsup at={plus1[-1]['created_at']} by={who} eyes={eyes_str}")
else:
    # 交由外层处理的情形:eyes 从 yes→no 且无新评论 = review 者审完且无意见 = 通过。
    # 单次调用看不到"消失",只报告当前 eyes;跳变由 poll 脚本跨轮判定。
    print(f"STATE=waiting eyes={eyes_str} "
          f"reactions={len(reactions)} comments={len(comments)}")
