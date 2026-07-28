# Task 1 报告：连锁帧与响应语义

状态：DONE

## 红灯证据

在新增连锁解析和响应测试后，执行：

```sh
cmake --build build/native --target test_duel_message_parser test_duel_response -j4
```

编译失败，错误明确指出 `PendingActionKind::SelectChain`、
`PendingAction::chain_forced`、`PendingAction::chain_options`、
`ygo::ChainOption` 及两个连锁响应构造器尚不存在。这证明测试针对的是待实现
的协议语义，而不是已有行为。

## 改动

- 增加 `PendingActionKind::SelectChain`、保留 OCGCore 原始候选索引的
  `ChainOption`，以及 `chain_forced` / `chain_options` 快照字段。
- 按上游 `MSG_SELECT_CHAIN` 的固定布局严格解析 23 字节候选记录，拒绝非法
  玩家/强制标记、截断、尾随和非法候选控制者；无候选的非强制窗口继续返回
  `AutoPassChain`。
- 增加纯值 `build_chain_response` 与 `build_chain_pass_response`：只能发动当前
  快照中的候选，且仅非强制窗口可编码 `int32(-1)` 跳过。
- 补充同卡多效果、截断、尾随、非法字段、未知索引和强制跳过拒绝测试。

## 测试

```sh
cmake --build build/native --target test_duel_message_parser test_duel_response -j4
ctest --test-dir build/native -R '^(duel_message_parser|duel_response)$' --output-on-failure
git diff --check
```

结果：2/2 目标测试通过，`git diff --check` 无输出。

## 提交

`feat(规则): 解析并编码连锁候选`

## 关注点

本任务仅交付解析器和纯响应构造器；Godot 展示、用户交互入口和会话层提交连锁
响应由后续任务接入。该范围不涉及场景、布局或运行时界面，因此未执行 Godot MCP。
