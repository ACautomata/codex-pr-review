# 轮询脚本:参数、退出码与判读口径

> 何时读这份:第 5 环要自定义轮询参数、或拿到非 `0` 退出码需要决定下一步时。
> 主干工作流(SKILL.md)已给出最常用的直接调用方式;这里是完整参考。

## 调用

```bash
bash <SKILL_DIR>/scripts/poll-until-thumbsup.sh <N>
# 可选: --since <ISO>  --first-wait 240  --interval 60  --max-wait 3600  --repo <owner/repo>
```

`<SKILL_DIR>` = skill 根目录(本 references/ 的上一级,如 `~/.claude/skills/codex-pr-review`)。脚本靠 `BASH_SOURCE` 自定位同目录的 `_judge.py`。

| 参数 | 默认 | 说明 |
|------|------|------|
| `--since <ISO8601>` | PR 最新 commit 的 committedDate | 锚点(最后一次 push)。脚本据此区分新/旧评论 |
| `--first-wait <sec>` | 240 | 首次等待。Codex 单次 review 4-6 分钟,不会更快 |
| `--interval <sec>` | 60 | 后续轮询间隔 |
| `--max-wait <sec>` | 3600 | 最大总等待,超时退出码 20 |
| `--repo <owner>/<repo>` | 当前 git remote 推断 | 仓库 |

锚点回退链:`commits[-1].committedDate` → `pr.updatedAt` → 当前时刻。

## 通过信号(满足任一即 exit 0)

1. **👍** —— issue reactions 端点出现 `+1` 反应(不限定发送者),且 `created_at` 晚于锚点。
2. **eyes 消失且无新意见** —— 轮询中观察到 `eyes` 从"存在"变"消失"(脚本跨轮记忆 prev_eyes),且该轮没有晚于锚点的新行内评论。

## 退出码

| 码 | 含义 | 下一步 |
|----|------|--------|
| `0` | 命中任一通过信号 | 收尾(SKILL.md 第 6 环"收尾审计") |
| `10` | 检测到晚于锚点的新行内评论 | 回第 3 环 triage,继续走闭环 |
| `20` | 超过 `--max-wait` 仍无通过信号 | 用三端点人工核查 Codex 是否在跑(eyes 是否还在),再决定继续等或手动触发 |
| `30` | 参数/前置错误 | 检查 PR 编号、`gh` 是否可用、`scripts/_judge.py` 是否在场 |
| `31` | `gh` 连续 5 次失败(弱网) | 按 troubleshooting.md 网络排查重试 |

## 判读口径(脚本内部已实现)

- `eyes` 仍在 = Codex 还在审查,继续等。
- `eyes` 从 yes→no 且无新评论 = 审完无意见 = 通过。
- `eyes` 一直没出现过(从首轮就是 no)且无 👍 无新评论 = **无法区分"还没来"还是"已结束"**,脚本保守地继续等,直到超时人工核查。
- **脚本不会自动触发 `@codex review`**——避免重复触发。需要手动触发时由人/agent 判断。

## 实现备忘(改脚本前看)

- `_judge.py` 是**无状态**单次判定器:拉两端点 → 输出一行 `STATE=...` 且恒带 `eyes=yes|no`。
- 跨轮的"eyes 从 yes→no 消失"跳变由 `poll-until-thumbsup.sh` 用 shell 变量 `prev_eyes` 记忆——reactions API 只返回当前存在的反应,没有"曾存在后撤销"的历史,所以只能跨轮比对。
- 👍 用 `created_at >= since` 过滤,避免把上一轮早已贴的旧 👍 误当本轮通过。
- 既有晚于锚点的 👍 又有晚于锚点的新评论时,`_judge.py` 优先报 `new_comments`(旧 👍 + 新意见 → 交回 triage)。
