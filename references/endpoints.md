# 端点详解与 commit_id 陷阱

> 何时读这份:第 2 环拉取意见时、或对"为什么不能用 commit_id 判断新旧评论"有疑问时。
> 主干工作流(SKILL.md)只给端点一句话;这里讲透数据形态与解析范式。

## 三个端点(务必分清)

拉取 PR N 的审查信息有**三个不同端点**,别混用:

| 想看什么 | 端点 | 含义 |
|---------|------|------|
| 有哪些 review(每次审查一条) | `gh pr view N --json reviews` | 每条含 `state`/`submittedAt`/`commit.oid`/`reactionGroups` |
| **行内代码评论**(真正的建议) | `gh api repos/<owner>/<repo>/pulls/N/comments` | 每条含 `body`/`commit_id`/`path`/`line`/`reactions`/`created_at`/`updated_at` |
| PR issue 反应(**👍 / eyes 在这里**) | `gh api repos/<owner>/<repo>/issues/N/reactions` | Codex 的 👍(通过)和 eyes(审查中)都贴在这个端点,**不在 reviews 里** |

`<owner>/<repo>` 从 `gh repo view --json nameWithOwner` 取。

## commit_id 陷阱(为什么不能用它判断新旧)

review 由 push 触发(每次推新 commit 就重新审查最新 commit)。**GitHub 会把旧 inline comment 的 `commit_id` 静默更新为 PR 最新 commit**(inline comments 会"re-anchor"到最新 commit 的对应行)。

后果:**`commit_id` 不能用来区分新/旧评论**——可能多条评论指向同一个 `commit_id`,其中既有本轮新增也有前几轮的。

**正确做法:用 `created_at` 与锚点(最后一次 push 的 committedDate)比较**。`created_at >= since` 才是本轮新评论。轮询脚本 `_judge.py` 就是这么判的。

## 解析范式

大 JSON 在管道里被 `head`/`tail` 截断后必解析失败,推荐用 python 过滤:

```bash
gh api repos/<owner>/<repo>/pulls/N/comments | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('total inline comments:', len(d))
for c in sorted(d, key=lambda x: x['created_at']):
    print('---', c['created_at'][:19], '|', c['path'], ':', c.get('line'), '| id:', c['id'])
    print(c['body'][:600])
"
```
