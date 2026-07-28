# Task 2 Fix Round 1：对手连锁策略可测试性报告

## 修复内容

- 将原先仅存在于 `ygo_core_bridge.cpp` 匿名命名空间的
  `advance_to_local_decision` 迁移为 `ygo` 命名空间生产 helper。
  - Bridge 继续调用同一函数，没有变更 Godot Dictionary 绑定范围。
  - helper 明确固定 OCGCore 玩家编号 0 为本地玩家、编号 1 为自动对手。
  - 自动对手在非强制 `SelectChain` 调用 `pass_chain()`；在强制窗口调用
    `submit_chain(chain_options.front().index)`。
- 扩展 `test_duel_session`，直接执行该生产 helper 并验证：
  - 玩家 0 的 `SelectChain` 原样停止，既不会写入响应也不会触发 Retry。
  - 玩家 1 的可选 `SelectChain` 自动跳过，真实 Idle Processor 返回 Retry 并恢复快照。
  - 玩家 1 的强制 `SelectChain` 自动选择首候选，真实 Idle Processor 返回 Retry 并恢复强制快照。

这些断言会分别捕获本地/对手编号反转、可选/强制策略分支反转，以及本地窗口被错误自动消费。

## TDD 记录

先在测试中调用尚未暴露的 `ygo::advance_to_local_decision`，构建按预期红灯：

```text
error: no member named 'advance_to_local_decision' in namespace 'ygo'
```

随后迁移同一生产循环、让 Bridge 与原生测试共享实现，测试转绿。

## 验证

```text
cmake --build build/native --target test_duel_session ygo_core -j 4
./build/native/test_duel_session
ctest --test-dir build/native --output-on-failure
```

完整 CTest 结果：12/12 通过，0 失败。

## Godot MCP 验收

- 启动真实项目，打开阶段确认浮层后执行取消，确认非法/取消路径不会推进决斗。
- 再次打开确认并结束回合，自动对手处理后阶段按钮回到“玩家1 / 主阶段”。
- 运行期间未发现项目功能错误；仅有 MCP 临时交互服务器自身的既有 GDScript 警告。
- 已停止实例并移除 MCP 自动注入的 `project.godot` 临时 Autoload 段落。
