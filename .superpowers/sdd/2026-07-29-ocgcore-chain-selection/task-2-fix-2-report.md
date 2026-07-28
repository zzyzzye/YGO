# Task 2 Fix Round 2：强制首候选策略报告

## 修复内容

- 新增纯生产策略 `decide_automatic_chain_action(const PendingAction&)`。
  - 本地 OCGCore 玩家编号 0 返回 `Stop`。
  - 自动对手编号 1 的非强制连锁返回 `Pass`。
  - 自动对手编号 1 的强制连锁返回 `Submit`，并携带
    `chain_options.front().index`。
  - 函数只读取已验证的语义快照，不生成或暴露 OCGCore 原始响应字节。
- `advance_to_local_decision` 现在实际消费该策略结果，并仅通过既有
  `pass_chain()` 与 `submit_chain()` 写入 OCGCore。
- 保留既有真实 OCGCore Retry 集成测试，并新增纯策略测试：首候选索引为 17，
  第二候选为 42。测试直接断言强制结果提交 17，因此能捕获硬编码 0 或误选第二项。

## TDD 记录

先写策略测试，构建按预期红灯：

```text
error: no type named 'AutomaticChainDecision' in namespace 'ygo'
error: no member named 'decide_automatic_chain_action' in namespace 'ygo'
```

随后添加最小纯策略值对象和函数，并接入生产推进 helper，测试转绿。

## 验证

```text
cmake --build build/native --target test_duel_session ygo_core -j 4
./build/native/test_duel_session
ctest --test-dir build/native --output-on-failure
```

完整 CTest：12/12 通过，0 失败。

Godot MCP 启动真实项目后，已覆盖阶段确认取消和结束回合回传；自动对手处理完成后
阶段按钮恢复为“玩家1 / 主阶段”。MCP 临时 Autoload 已在停止实例后清理。
