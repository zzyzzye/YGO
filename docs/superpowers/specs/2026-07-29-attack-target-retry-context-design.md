# 攻击目标重试上下文恢复设计

## 问题

OCGCore 用 `MSG_RETRY` 拒绝上一条响应时，`DuelSession` 会恢复提交前的
`PendingAction`，但当前 `ProcessResult.ok` 仍为 `true`。Godot 主界面因此把
提交误判为完成并清除攻击路线或目标上下文，恢复后的决策没有可操作入口。

## 设计

- 在 `ProcessResult` 增加 `response_rejected` 布尔字段，仅当本轮解析到
  `MSG_RETRY` 且成功恢复提交前快照时为 `true`。
- GDExtension Bridge 原样暴露该字段。Godot 不解析消息文本，也不推断
  OCGCore 协议。
- Main 在是非、目标选择和取消提交返回 `response_rejected=true` 时：
  保留提交前的攻击上下文和预选，刷新恢复后的 pending，并显示简体中文
  重试诊断；正常成功路径保持现有状态转换。
- Bridge 自动推进不得跨过这个拒绝结果，否则会吞掉本地玩家的恢复决策。

## 验收

- 原生测试证明真实 `MSG_RETRY` 返回结构化拒绝标记并恢复完整候选。
- Godot 流程测试覆盖攻击路线“是/否”、目标提交和取消四种拒绝重试。
- Godot MCP 在真实场景节点上触发至少一条拒绝重试路径，确认入口仍可操作。
