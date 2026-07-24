# 网络故障排查 + 完整示例

> 何时读这份:`gh` 调用报网络错 / 返回空 body,或想看一轮多意见迭代的完整样子时。

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

轮询脚本已内置此容错:`gh` 连续失败计数,满 5 次才以退出码 `31` 放弃;偶发抖动只告警继续等。

## 示例:一轮多意见迭代(示意)

Codex 对某 PR 连提 3 条 P2,逐条修复后拿到通过信号:

1. `commit A`:某函数返回类型与调用方契约不符 → 加适配层。(`fixB`)
2. `fixB`:适配层在边界条件下越界 → 加 clamp。(`fixC`)
3. `fixC`:CLI 默认值与新逻辑冲突 → 调整默认。(`fixD`)
4. 推 `fixD` 后 ~10 分钟,issue reactions 出现 `+1`(或 eyes 消失),该 commit 上 0 条新评论 → 通过。

每条 fix 配一个回归测试,确保同一 bug 下一轮不再被提。
