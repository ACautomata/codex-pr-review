---
name: codex-pr-review
description: 响应 GitHub PR 上 Codex(chatgpt-codex-connector[bot])的自动 review,把"triage 意见→修复→推送→轮询再审"跑成收敛闭环,直到出现通过信号(👍 反应,或 eyes 消失且无新意见)才退出。触发:用户提到 codex、自动代码审查 bot 的 PR 意见或反应、或要让 codex review 收敛到通过。
context: fork
---

# codex-pr-review

把 Codex(chatgpt-codex-connector[bot])对 GitHub PR 的自动 review 跑成一个**闭环**:拉取意见 → triage → 修复 → 推送 → 轮询再审,若又提意见则回到 triage 再走一圈,直到出现**通过信号**才退出闭环。

## Codex 行为契约

- **有建议** → 发 review(状态 `COMMENTED`)+ 行内评论,带 `P1`/`P2`/`P3` 严重度徽章。
- **审查中** → 给 PR issue 贴 **eyes** 反应;审完撤掉。
- **无建议** → 给 PR issue 贴 👍(`+1`),或撤掉 eyes 后不再提意见。

**commit_id 陷阱**:区分新/旧评论用 `created_at` 与最后一次 push 比较;`commit_id` 会被 GitHub 静默 re-anchor 到最新 commit,会骗你。原理与三端点细节见 [references/endpoints.md](references/endpoints.md)。通过信号怎么判见第 5 环。

## 闭环工作流

每环末尾的 **闭环到** 是这一环的验收标准——达标才进下一环,未达标就留在本环继续做。

### 1. 定位目标 PR 和分支

```bash
gh pr list --state open          # 拿到编号 N
gh pr view N --json number,title,headRefName,baseRefName,state
```

切到 PR 分支:`git checkout <headRefName>`。

**闭环到**:已知 N 与 headRefName,且当前在该分支上。

### 2. 拉取当前所有意见

三个端点一起拉:

```bash
gh pr view N --json reviews
gh api repos/<owner>/<repo>/pulls/N/comments
gh api repos/<owner>/<repo>/issues/N/reactions
```

三端点各自含义、大 JSON 的 python 解析范式见 [references/endpoints.md](references/endpoints.md)。

**闭环到**:三个端点数据已拉到且能解析(非空 body)。

### 3. triage:每条意见是真 bug 还是误报

逐条核定行内评论,按严重度分诊:

- **P1(红)**:几乎肯定要改(崩溃、数据损坏、安全)。
- **P2(黄)**:大概率要改(逻辑错误、契约不一致、会让用户踩坑)——先复现或验证 Codex 描述成立再动手。
- **P3(绿)**:风格/nit,可选。
- **误报**:验证后描述不成立(如它假设的代码路径不存在),在 PR 上回复说明 + 点 👎。

**复现先于修复**:按 `body` 里的 `path`/`line` 定位,能复现的先写一行复现脚本跑出 **red**,再修到 **green**。

**全局视角(批判性约束)**:逐条核实后,先把本轮所有意见放在一起做总体规划——它们是否指向同一个根因?是否有共同的薄弱抽象、缺失不变式或不一致契约?用一个连贯的修复覆盖同根因的意见组,并回答"为什么这一组问题会一起出现"。逐点孤立打补丁容易引入新不一致,常在下一轮被 Codex 以"新意见"再提。

**闭环到**:每条 P1/P2 已复现为真 bug 或已判误报(已回复 + 👎);P3 已决定改/不改;真 bug 已按根因归组,修复有全局规划。

### 4. 修复 + 验证 + 推送

- 按全局规划实施修复(一个连贯改动覆盖同根因的意见组)。
- 跑仓库约定的 lint、类型检查、测试(常见 `ruff`/`mypy`/`pytest`)。
- 每个根因配一个回归测试(用 dummy/stub/fixture 隔离重资源与外部依赖)。
- commit message:`fix(<scope>): <一句话> (codex #N)`,正文写清修了什么、根因、加了哪些测试。
- `git push origin <headRefName>`。
- stage 只放本 PR 相关文件;若 `git add -A` 带进了嵌套 git repo、别的分支残留或构建产物,先 `git rm --cached <path>` 取消暂存。

**闭环到**:每个根因有修复 + 回归测试,lint/类型/测试全绿,已 push(远端 commit 与本地一致才算交付)。

### 5. 轮询等待 Codex 对新 commit 的再审

推送后 Codex 自动重新审查,**单次 review 通常 4-6 分钟**。用本 skill 自带的轮询脚本守着——它以最后一次 push 为锚,每轮拉 issue reactions + 行内评论两端点,直到出现通过信号或新意见才返回。

脚本在 skill 根目录下的 `scripts/` 子目录,**相对本 SKILL.md 所在目录**引用;调用时把它解析成绝对路径(将 skill 的 base directory 拼上 `scripts/poll-until-thumbsup.sh`):

```bash
bash <SKILL_DIR>/scripts/poll-until-thumbsup.sh <N>
# 可选: --since <ISO>  --first-wait 240  --interval 60  --max-wait 3600  --repo <owner/repo>
```

`<SKILL_DIR>` = 本 SKILL.md 所在目录(skill 根目录)。脚本从任何 CWD 调用都能定位到 `_judge.py`(自定位机制见 polling.md 实现备忘)。

**通过信号(满足任一即 exit 0)**:① issue reactions 出现 `+1`(👍,不限发送者,`created_at` 晚于锚点);② `eyes` 从"存在"变"消失"且该轮无新评论。

退出码:`0`=通过(进第 6 环);`10`=有新意见(回第 3 环继续闭环);`20`=超时(人工核查);`30`/`31`=参数错/弱网。参数细节、eyes 判读口径、实现备忘见 [references/polling.md](references/polling.md)。

**闭环到**:脚本以 `0` 返回(命中通过信号),或以 `10` 返回并带着新意见回第 3 环。

### 6. 收尾审计

退出闭环前逐项核对:

- [ ] 通过信号到位:issue reactions 有晚于最后一次 push 的 `+1`(不限发送者),**或**轮询中观察到 `eyes` 从"存在"变"消失"。
- [ ] 最新 commit 上每条行内评论的 `created_at` 都早于最后一次 push(全部为本轮已处理过的旧意见)。
- [ ] lint + 类型检查 + 测试全绿。
- [ ] 改动已 push 到 PR 分支(远端 commit 与本地一致)。
- [ ] eyes 仍在而仅"没新评论"时,视为仍在审,继续守闭环——等 eyes 消失或 👍 出现再收尾。

## 排错与示例

`gh` 弱网报错/空 body 的排查、完整多意见迭代示例见 [references/troubleshooting.md](references/troubleshooting.md)。
