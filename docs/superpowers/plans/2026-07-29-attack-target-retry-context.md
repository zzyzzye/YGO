# 攻击目标重试上下文恢复实施计划

1. 先扩展原生测试，要求 `MSG_RETRY` 返回 `response_rejected=true`，普通成功
   与本地校验失败均为 `false`。
2. 在 `DuelSession::process_once()` 捕获 Retry 恢复事实，通过
   `ProcessResult` 和 GDExtension 字典传递，不依赖诊断文本。
3. 扩展 FakeBridge 与 Godot 流程测试，覆盖 YesNo true、YesNo false、
   SelectCard 提交和取消的 Retry。
4. 修改 Main：拒绝时恢复提交前上下文与预选，刷新 pending；正常成功保持
   既有行为。
5. 运行原生 CTest、Godot 四组自动化、headless 启动和 Godot MCP 节点输入
   验收；复审差异后提交并推送 main。
