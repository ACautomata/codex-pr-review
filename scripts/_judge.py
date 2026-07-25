#!/usr/bin/env python3
"""单次判定 Codex 对 PR 本轮审查的状态。供 poll-until-thumbsup.sh 调用。

argv: owner repo pr since(ISO8601,锚点=最后一次 push)
stdout: 一行 "STATE=thumbsup ..." | "STATE=new_comments ..." | "STATE=waiting ..."
        每行都带 eyes=yes|no,供外层跨轮比对"eyes 是否从 yes→no 消失"。
exit 0: 正常判定(看 STATE);  exit 3: gh 调用失败(让外层 sleep 后重试,不直接判败)。
"""
import json
import subprocess
import sys
import datetime

owner, repo, pr, since = sys.argv[1:5]


def gh(path):
    r = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if r.returncode != 0:
        return None, (r.stderr or "").strip().replace("\n", " ")[:160]
    try:
        return json.loads(r.stdout), None
    except Exception as e:  # 空body/半截JSON(弱网)
        return None, f"parse {e}: {r.stdout[:160]!r}"


def dt(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))


since_dt = dt(since)

reactions, err = gh(f"repos/{owner}/{repo}/issues/{pr}/reactions")
if reactions is None:
    print("gh reactions:", err)
    sys.exit(3)

comments, err = gh(f"repos/{owner}/{repo}/pulls/{pr}/comments")
if comments is None:
    print("gh comments:", err)
    sys.exit(3)


# 关键:用 created_at 与锚点比,而非 commit_id(GitHub 会静默把旧 inline comment 的
# commit_id 更新为最新 commit,见 references/endpoints.md 的"commit_id 陷阱")。
new_comments = [c for c in comments if dt(c["created_at"]) >= since_dt]

# 通过信号:👍 反应。不限定发送者(机器人/真人均可)——任何 reviewer 点的 👍 都算通过。
# 只看晚于锚点的 👍,避免把上一轮早已贴的旧 👍 误当本轮通过。
plus1 = [r for r in reactions if r.get("content") == "+1" and dt(r["created_at"]) >= since_dt]

# eyes = review 者正在审查中的标记。本轮是否仍在(供外层跨轮比对 yes→no 的消失)。
eyes_now = any(r.get("content") == "eyes" for r in reactions)
eyes_str = "yes" if eyes_now else "no"

# 顺序敏感:既有 👍 又有新评论时,说明 👍 是旧的、新意见是新的 → 优先交回 triage。
if new_comments:
    print(f"STATE=new_comments count={len(new_comments)} latest={new_comments[-1]['created_at']} eyes={eyes_str}")
elif plus1:
    who = (plus1[-1].get("user") or {}).get("login") or "?"
    print(f"STATE=thumbsup at={plus1[-1]['created_at']} by={who} eyes={eyes_str}")
else:
    # 交由外层处理的情形:eyes 从 yes→no 且无新评论 = review 者审完且无意见 = 通过。
    # 单次调用看不到"消失",只能报告当前 eyes 状态;跳变由 poll 脚本跨轮判定。
    print(f"STATE=waiting eyes={eyes_str} reactions={len(reactions)} comments={len(comments)}")
