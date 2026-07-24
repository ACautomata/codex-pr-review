---
name: codex-pr-review
description: 响应 GitHub PR 上 Codex(chatgpt-codex-connector[bot])的自动 review:triage 每条 P1/P2/P3 意见并甄别误报,修复推送后轮询,直到 issue reactions 出现 👍 通过信号。触发:用户提到 codex、自动代码审查 bot 的 PR 意见或反应、或要让 codex review 收敛到通过。
context: fork
---

# codex-pr-review

把 Codex(chatgpt-codex-connector[bot])对 GitHub PR 的自动 review,从"拉取 → 解读 → 修复 → 推送 → 等下一轮"打通成可重复执行的闭环;闭环以 issue reactions 上的 **👍** 为终止信号。

## Codex 行为契约(背景)

- **有建议** → 在 PR 上发 review(状态 `COMMENTED`)+ 一条或多条**行内评论**(inline review comments),带 `P1`/`P2`/`P3` 严重度徽章。
- **无建议** → 不发评论,而是给 **PR issue(issue-level reaction)** 贴一个 👍(`+1`)反应。
- review 由 push 触发(每次推新 commit 就重新审查最新 commit)。**GitHub 会把旧 inline comment 的 `commit_id` 静默更新为 PR 最新 commit**（inline comments 会"re-anchor"到最新 commit 的对应行），因此 **`commit_id` 不能用来区分新/旧评论**——可能多条评论指向同一个 `commit_id`，其中既有本轮新增也有前几轮的。

## 三个端点(务必分清)

拉取 PR N 的审查信息有**三个不同端点**,别混用:

| 想看什么 | 端点 | 含义 |
|---------|------|------|
| 有哪些 review(每次审查一条) | `gh pr view N --json reviews` | 每条含 `state`/`submittedAt`/`commit.oid`/`reactionGroups` |
| **行内代码评论**(真正的建议) | `gh api repos/<owner>/<repo>/pulls/N/comments` | 每条含 `body`/`commit_id`/`path`/`line`/`reactions`/`created_at`/`updated_at`。**注意 `commit_id` 会被 GitHub 静默更新为最新 commit，不可用于判断新旧**——用 `created_at` 替代 |
| PR issue 反应(**👍 在这里**) | `gh api repos/<owner>/<repo>/issues/N/reactions` | Codex 的 👍 贴在这个端点,**不在 reviews 里** |

> **关键易错点**:通过信号是 issue reactions 上的 `+1`,**不是** review 上没有新评论。只看 reviews/review-comments 会误判"还没结论"。
>
> `<owner>/<repo>` 从 `gh repo view --json nameWithOwner` 取。

## 工作流

### 1. 定位目标 PR 和分支

```bash
gh pr list --state open          # 列出所有 open PR,拿到编号 N
gh pr view N --json number,title,headRefName,baseRefName,state
```

不在 PR 分支上就先 `git checkout <headRefName>`,否则读到的代码和 review 指的 commit 对不上。

**完成**:已知 N 与 headRefName,且当前在该分支上。

### 2. 拉取当前所有意见(三个端点一起拉)

```bash
gh pr view N --json reviews
gh api repos/<owner>/<repo>/pulls/N/comments
gh api repos/<owner>/<repo>/issues/N/reactions
```

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

**完成**:三个端点的数据都已拉到且能解析(非空 body)。

### 3. triage:每条意见是真 bug 还是误报

每条行内评论带严重度徽章和"有用?React 👍/👎"。**不要无脑全改——Codex 会错,验证不成立就逐条反驳**:

- **P1(红)**:几乎肯定要改(崩溃、数据损坏、安全)。
- **P2(黄)**:大概率要改(逻辑错误、契约不一致、会让用户踩坑)——但**先在代码里复现或验证 Codex 的描述成立**再动手。P2 也常是真 bug,别因"中等严重度"跳过核实。
- **P3(绿)**:风格/nit,可选。
- **误报**:Codex 有时基于过时信息或理解偏差。验证后描述不成立(比如它假设的代码路径实际不存在),在 PR 上回复说明 + 点 👎,不改代码。

**复现先于修复**:读 `body` 里的 `path`/`line`,打开对应文件确认现象真实存在;能复现的先写一行复现脚本/测试跑一下,先看到复现测试的 **red**(失败),再修到 **green**(通过)。

**完成**:每条 P1/P2 已复现为真 bug,或已判定误报(已回复 + 👎);P3 已决定改/不改。

### 4. 修复 + 验证 + 推送

- 跑仓库的 lint、类型检查、测试(按该仓库约定——常见为 `ruff`/`mypy`/`pytest` 或等价命令,先确认命令再跑)。
- **每条意见配一个回归测试**(用 dummy/stub/fixture 避免触发重资源或外部依赖,如下载大文件、起真实服务、联网调用),证明 bug 已修且不会再回归。
- commit message 用 `fix(<scope>): <一句话> (codex #N)` 格式,正文说清修了什么、为什么、加了哪些测试。
- `git push origin <headRefName>`。
- 提交前 review 已暂存文件:只 stage 本 PR 相关文件;若有嵌套 git repo、别的分支残留或构建产物被 `git add -A` 带进来,先 `git rm --cached <path>` 取消暂存。

**完成**:每条真 bug 有修复 + 回归测试,lint/类型/测试全绿,已 push 到 PR 分支(本地 commit ≠ 已交付)。

### 5. 轮询等待 Codex 对新 commit 的再审

推送后 Codex 自动重新审查,**单次 review 通常 4-6 分钟**。与其手动 `sleep` + 反复拉取,直接用本 skill 自带的轮询脚本——它以"最后一次 push(PRD 最新 commit 的 committedDate)"为锚,每轮拉 issue reactions + 行内评论两端点,**一直轮询到出现 👍 才返回**;期间若 Codex 又提新意见则立即交回 triage:

```bash
bash ~/.claude/skills/codex-pr-review/poll-until-thumbsup.sh <N>
# 可选: --since <ISO>  --first-wait 240  --interval 60  --max-wait 3600  --repo <owner/repo>
```

退出码即结论,按此决定下一步:

- `0` —— issue reactions 上出现 `chatgpt-codex-connector[bot]` 的 `+1`(👍 通过),且无晚于锚点的新评论。→ 收尾(第 6 步)。
- `10` —— 检测到晚于锚点的新行内评论(Codex 又提意见了)。→ 回第 3 步 triage,别干等。
- `20` —— 超过 `--max-wait`(默认 3600s)仍未收到 👍。→ 用三个端点命令人工核查 Codex 是否在跑(eyes 是否还在),再决定继续等或手动触发。
- `30`/`31` —— 参数错误 / `gh` 连续失败(弱网)。后者按"网络故障排查"重试。

**判读口径**(脚本内部已实现,了解即可):issue reactions 出现 bot 的 `+1` 且无新于锚点的评论 = 通过;`eyes` 仍在 = Codex 还在审查;eyes 消失且无新评论且无 👍 = Codex 本轮空跑(未真正运行/服务异常),此时才评论 `@codex review` 手动触发——**脚本不会自动触发,避免重复**。

**完成**:脚本以退出码 `0` 返回(👍 通过),或以 `10` 返回并带着新意见回第 3 步。

### 6. 成功判据(完成审计)

宣布"完成"前逐项核对:

- [ ] issue reactions 端点有 `chatgpt-codex-connector[bot]` 的 `+1`(其 `created_at` 应晚于最后一次 push)。
- [ ] 最新 commit 上**没有任何** `created_at` 晚于最后一次 push 的行内评论。**禁止用 `commit_id` 判断**——GitHub 会把所有旧 inline comment 的 `commit_id` 更新为最新 commit。
- [ ] 改动通过仓库的 lint + 类型检查 + 测试。
- [ ] 改动已 push 到 PR 分支(本地 commit ≠ 已交付)。
- [ ] 没把"无新意见"误当"通过"——只有 👍 反应才是 Codex 的明确通过信号。

## 网络故障排查

`gh` 在弱网下会抛 `Post ... EOF` / `TLS handshake timeout` / 返回空 body(致 python `json.loads` 报 `Expecting value`)。**是网络抖动,不是数据问题**:不改命令,`sleep 30` 后原样重试;解析用 `try/except` 包住,出错时打印 `repr(raw[:200])` 区分"空 body"与"真异常"。

```bash
gh pr view N --json reviews 2>&1 | python3 -c "
import json, sys
raw = sys.stdin.read()
try:
    print(json.loads(raw))
except Exception:
    print('parse error, raw was:', repr(raw[:200]))
"
```

## 示例:一轮多意见迭代(示意)

Codex 对某 PR 连提 3 条 P2,逐条修复后拿到 👍:

1. `commit A`:某函数返回类型与调用方契约不符 → 加适配层。(`fixB`)
2. `fixB`:适配层在边界条件下越界 → 加 clamp。(`fixC`)
3. `fixC`:CLI 默认值与新逻辑冲突 → 调整默认。(`fixD`)
4. 推 `fixD` 后 ~10 分钟,issue reactions 出现 `chatgpt-codex-connector[bot]` 的 `+1`,该 commit 上 0 条新评论 → 👍 通过。

每条 fix 配一个回归测试,确保同一 bug 下一轮不再被提。
