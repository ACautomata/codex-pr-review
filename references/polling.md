# wait 脚本:参数、退出码与状态机

> 何时读这份:第 5 环要自定义轮询参数、或拿到非 0 退出码需要决定下一步时。
> 主干工作流(SKILL.md)已给出最常用的直接调用方式;这里是完整参考。

## 调用

```bash
bash <SKILL_DIR>/scripts/wait.sh <N>
# 可选: --since <ISO>  --interval 15  --repo <owner/repo>
```

`<SKILL_DIR>` = skill 根目录(本 references/ 的上一级,如 `~/.claude/skills/codex-pr-review`)。

| 参数 | 默认 | 说明 |
|------|------|------|
| `--since <ISO8601>` | PR 最新 commit 的 committedDate | 锚点(最后一次 push)。据此区分新/旧评论 |
| `--s0-timeout <sec>` | 120 | S0 超时秒数。push 新代码后 Codex 判断无需再审时不会贴 eyes/👍/评论,超时后视为通过。设为 0 禁用在 S0 无限等待 |
| `--interval <sec>` | 15 | 轮询间隔。ETag 下没变化是 304(不计 rate limit),间隔仅做 rate limiting |
| `--repo <owner>/<repo>` | 当前 git remote 推断 | 仓库 |

锚点回退链:`commits[-1].committedDate` → `pr.updatedAt` → 当前时刻。

## 4 状态机

状态转移**全部由 API 查询结果驱动**——sleep 仅做 rate limiting,不参与状态判定。

```
               +─ API: eyes 出现 ──→ S1 (WAITING, Codex 审查中)
               |                        │
S0 (IDLE) ─────+                        │ API: eyes 还在 → 留在 S1
               |                        │ API: 👍 出现 → S2
               +─ API: 👍 直接出现 → S2 │ API: eyes 消失 + 无新评论 → S2
               |                        │ API: eyes 消失 + 有新评论 → S3
               +─ API: 新评论出现 → S3  │
               |
               +─ 超时(s0-timeout) → S2 │(Codex 判断无需再审)
```

- **S0 (IDLE)**: PR 刚开/刚 push,Codex 还没开始。轮询观察。
  - eyes 出现 → 进入 S1
  - 👍 直接出现 → exit 0 (Codex 有时跳过 eyes 直接贴 👍)
  - 新评论出现(created_at >= since) → exit 10 (Codex 可能跳过 eyes 直接评论)
  - 超时(默认 120s) → exit 0 (Codex 认为无需重审,不会贴任何标记)
- **S1 (WAITING)**: 已确认 eyes 存在过,Codex 正在审查。S1 状态本身编码了"之前见过 eyes"的记忆,无需跨轮 bash `prev_eyes` 变量。
  - eyes 还在 → 留在 S1,继续轮询
  - 👍 出现 → exit 0
  - eyes 消失 + 无新评论 → exit 0 (审完且无意见)
  - eyes 消失 + 有新评论 → exit 10 (审完且有修改意见)
- **S2 (PASS)**: 终态,exit 0——收尾审计。
- **S3 (NEW_COMMENTS)**: 终态,exit 10——回 triage(第 3 环)。

### 关键设计

处于 **S1** 状态本身就编码了"之前见过 eyes"的记忆——无需跨轮 bash `prev_eyes` 变量。当 API 返回 eyes=no 时,直接触发消失判断:无新评论 → 通过;有新评论 → 新意见。

## 退出码

| 码 | 含义 | 下一步 |
|----|------|--------|
| `0` | S2 通过(👍 或 eyes 消失无新评论 或 S0 超时) | 收尾(SKILL.md 第 6 环"收尾审计") |
| `10` | S3 有新评论 | 回第 3 环 triage,继续走闭环 |
| `30` | 参数/前置错误 | 检查 PR 编号、`gh` 是否可用 |
| `31` | `gh` 连续 5 次失败(弱网) | 按 troubleshooting.md 网络排查重试 |

## 通过信号(满足任一即 exit 0)

1. **👍** —— issue reactions 端点出现 `+1` 反应(不限定发送者),且 `created_at` 晚于锚点。
2. **eyes 消失且无新意见** —— 处于 S1 时 API 返回 eyes=no 且没有晚于锚点的新行内评论。
3. **S0 超时** —— 距锚点超过 `--s0-timeout` 秒(默认 120s)仍无 eyes/👍/新评论,说明 Codex 认为本轮改动无需再审。

## 实现备忘(改脚本前看)

- 脚本主成分是 **bash**,内嵌 Python heredoc 做 API fetcher(ETag 条件请求 + 文件缓存)。bash 负责状态机循环、sleep、超时、日志;Python 只负责每轮拉两端点并输出 `key=value` 行。
- ETag 条件请求:每轮带缓存的上次 `ETag` 发 `If-None-Match`,资源没变时 GitHub 返回 `304`(不计 rate limit、无 body),此时复用上次缓存的 body。这正是间隔可以从传统 60s 压到 15s 的依据:绝大多数轮次 Codex 还在审,两端点全是 304。
- **传输层是 `curl`,不是 `gh api`**:`gh api` 实测不透传 `If-None-Match`(对 conditional header 直接返回 200 + 完整 body),拿不到 304。
- 缓存落在 `$TMPDIR/codex-pr-review/<owner>-<repo>-<pr>.json`(含两端点 etag + body),跨轮复用。
- 👍 用 `created_at >= since` 过滤,避免把上一轮早已贴的旧 👍 误当本轮通过。
- 既有晚于锚点的 👍 又有晚于锚点的新评论时,新评论优先(S0→S3 或 S1→S3),旧 👍 可能是上一轮的残留,新意见才是本轮该关注的。
- **脚本不会自动触发 `@codex review`**——避免重复触发。需要手动触发时由人/agent 判断。
