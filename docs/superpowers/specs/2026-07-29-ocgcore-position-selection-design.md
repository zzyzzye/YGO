# OCGCore 表示形式选择交互设计

## 目标

让玩家从手牌或场上发起真实 OCGCore 动作后，能够通过原生 Godot 情境按钮
完成 `MSG_SELECT_POSITION`，使通常召唤、盖放和改变表示形式不再停在
Unsupported 状态。

## 原生规则契约

- 新增 `PendingActionKind::SelectPosition`。
- 解析严格长度为 7 字节的正文：
  `message_type:u8, player:u8, card_id:u32, positions:u8`。
- `player` 只能为 0 或 1；位置掩码只能包含 OCGCore 四个合法单值：
  `0x1/0x2/0x4/0x8`，且至少包含一个候选；尾随字节视为畸形。
- C++ 将掩码拆成离散 `position_options`，Godot 不读取或解释原始位掩码。
- `submit_position(position)` 只接受当前快照中真实存在的单值候选，并按
  小端 `int32` 组包。非法、过期或组合值不得写入 OCGCore。
- `MSG_RETRY` 沿用现有完整快照恢复和 `response_rejected` 契约。

## Godot 交互

- Bridge 暴露 `selection_card_id` 与 `position_options`，提供语义提交方法。
- Main 将 SelectPosition 作为本地规则决策传给 DuelBoard；提交成功后刷新
  真实场面，失败或 Retry 时保留原按钮。
- DuelBoard 使用现有原生确认面板展示合法选项：
  “表侧攻击”“里侧攻击”“表侧守备”“里侧守备”。只创建核心实际允许的
  按钮，不自行补全。
- 决策存在时，背景、阶段和普通卡牌动作不能覆盖该入口。

## 验收

- 解析器覆盖四个候选、单候选、非法掩码、截断和尾随字节。
- 响应与 Session 覆盖合法提交、非法候选、过期提交和 Retry。
- Godot 场景测试覆盖按钮集合、单次提交、失败/Retry 保留和新快照清理。
- Godot MCP 从真实手牌点击“通常召唤”，选择表示形式，并确认卡牌由手牌
  移入怪兽区；同时复验 1080p、4K 逻辑分辨率和 16:10 布局契约。
