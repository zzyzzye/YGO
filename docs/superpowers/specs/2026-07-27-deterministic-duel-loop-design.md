# 确定性最小对局闭环设计

## 目标

在现有卡片数据库、Lua 规则加载器和 OCGCore 生命周期封装之上，完成一个可自动验证的最小单机对局闭环：

1. 使用固定双方主卡组和固定随机种子创建决斗。
2. 启动后确认双方各有 5 张手牌、主卡组各剩 35 张。
3. 读取并解析 OCGCore 输出消息，明确识别玩家 1 的空闲阶段决策。
4. 通过语义接口提交“结束回合”，不允许 Godot 层自行拼装协议字节。
5. 继续推进至玩家 2 的空闲阶段决策，并确认当前决策玩家已经切换。

本阶段不实现召唤、盖放、发动效果、战斗、牌组编辑、AI 或完整棋盘。

## 架构边界

### `DuelSession`

`DuelSession` 是唯一允许直接调用 OCGCore 二进制消息与响应 API 的项目自有层。它负责：

- 向 OCGCore 下发主卡组并启动决斗。
- 调用 `OCG_DuelProcess` 推进规则处理。
- 在每次推进后调用 `OCG_DuelGetMessage`，复制消息缓冲区并在缓冲区失效前完成解析。
- 从消息流中提取最后一个需要玩家响应的消息。
- 仅当当前消息明确为 `MSG_SELECT_IDLECMD` 且协议字段表明允许进入结束阶段时，构造并提交 `type=7` 的响应。
- 对未知消息、截断消息和不匹配的动作返回中文诊断，不猜测协议。

Godot、GDScript 和界面代码不得直接持有 OCGCore 指针，也不得构造原始响应字节。

### 待决策模型

新增一个 Godot 无关的 C++ 值类型 `PendingAction`，至少包含：

- 决策类型：无决策、空闲阶段、暂不支持。
- 当前决策玩家：`0` 或 `1`；无有效玩家时使用明确的无效值。
- 是否允许结束回合。
- 原始 OCGCore 消息类型，用于诊断。
- 中文诊断信息。

本里程碑只完整解析 `MSG_SELECT_IDLECMD`。解析器必须按上游
`playerop.cpp` 的字段顺序逐项跳过六组可选卡片列表，再读取
`to_bp`、`to_ep` 和 `can_shuffle`。所有长度读取均需检查剩余字节。

一轮 `OCG_DuelProcess` 可能同时产生多个通知消息和一个决策消息。
解析器应顺序消费完整消息缓冲区，记录 `MSG_NEW_TURN` 等状态通知，
并以最后一个需要响应的消息作为当前待决策。不能把缓冲区首字节
直接假设为当前决策。

### `YgoCoreBridge`

Godot 桥接层只暴露语义接口：

- `get_pending_action() -> Dictionary`
- `submit_end_turn() -> Dictionary`
- 现有 `setup_duel()` 返回值中保留处理状态，并补充待决策摘要。

`get_pending_action()` 返回稳定字段：

```text
{
  "kind": "none" | "idle" | "unsupported",
  "player": int,
  "can_end_turn": bool,
  "message_type": int,
  "message": String
}
```

`submit_end_turn()` 在动作不合法时返回 `ok=false` 和中文原因，且不得
向 OCGCore 写入任何响应；成功时提交动作、继续推进，并返回新的处理
状态和待决策摘要。

现有 `send_duel_response(PackedByteArray)` 不再供 GDScript 使用。为避免
一次性扩大重构范围，本阶段可以保留其绑定兼容性，但界面与新测试不得
依赖它；后续所有动作应通过语义接口逐步替代。

## 数据流

```text
固定牌组与种子
    ↓
YgoCoreBridge::setup_duel
    ↓
DuelSession 装牌、启动、推进、复制并解析消息
    ↓
PendingAction(kind=idle, player=0, can_end_turn=true)
    ↓
Godot 启用“结束回合”
    ↓
YgoCoreBridge::submit_end_turn
    ↓
DuelSession 校验待决策并提交 type=7
    ↓
继续推进并解析消息
    ↓
PendingAction(kind=idle, player=1, can_end_turn=true)
```

## 错误处理

- 未创建决斗：返回“决斗尚未创建”。
- 消息为空但状态为等待输入：返回不支持状态并报告该矛盾。
- 消息长度不足：返回包含消息类型和读取位置的中文错误，不越界读取。
- 当前不是空闲阶段：拒绝“结束回合”，不得写入响应。
- `to_ep` 为假：拒绝“结束回合”，不得依靠 OCGCore 的 `MSG_RETRY` 兜底。
- OCGCore 返回 `MSG_RETRY`：报告上一响应被规则层拒绝，并保留可诊断状态。
- 未识别的交互消息：标记为 `unsupported`，停止自动推进，等待后续显式实现。

项目自有日志、测试断言说明和 Godot 可见诊断均使用简体中文。

## 测试策略

### 原生单元测试

为消息解析器构造最小合法与非法字节流，按测试驱动顺序覆盖：

- 正确解析空闲阶段玩家和 `to_ep`。
- 拒绝截断的列表字段。
- 不把通知消息误识别为待决策。
- 不允许在非空闲阶段提交结束回合。

### 真实素材集成测试

使用仓库内真实 `cards.json`、卡图交集和 `CardScripts`：

- 固定选出 40 张可加载脚本的主卡组，双方使用确定顺序。
- 固定种子启动后断言双方状态为主卡组 35、手牌 5。
- 推进至玩家 1 `MSG_SELECT_IDLECMD`，断言允许结束回合。
- 调用语义接口提交结束回合。
- 继续推进至玩家 2 `MSG_SELECT_IDLECMD`，断言决策玩家为 1。
- 相同牌组和种子重复运行时，比较关键消息类型与决策玩家序列，确保结果一致。

真实素材测试必须作为常规 `ctest` 项目运行，不能依赖手工设置环境变量后才生效。

### Godot MCP 验收

完成原生测试后，通过 Godot MCP：

1. 打开 `/Volumes/WD/YGO`。
2. 运行主场景并读取调试输出。
3. 检查双方显示为“卡组 35、手牌 5”。
4. 检查只有在玩家 1 空闲阶段时“结束回合”可用。
5. 点击“结束回合”。
6. 检查界面进入玩家 2 决策状态，且无 GDScript、GDExtension 或 OCGCore 错误。
7. 捕获最终画面作为可视化验收依据。

## 完成标准

- 所有原生测试通过，包含新增消息解析和真实素材闭环测试。
- Godot 层不再构造 `SelectIdleCmd` 原始字节。
- 无法识别的 OCGCore 交互不会被自动响应。
- 固定种子闭环能够从玩家 1 主阶段推进到玩家 2 主阶段。
- Godot MCP 运行、交互、画面和调试输出检验均通过。
- `git diff --check` 无错误；第三方子模块的既有本地改动不进入本功能提交。
