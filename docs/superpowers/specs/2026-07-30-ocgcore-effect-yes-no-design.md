# OCGCore 情境式效果确认设计

## 目标与边界

把 `MSG_SELECT_EFFECTYN` 从 `Unsupported` 升级为独立的语义决策。玩家看到效果
来源卡和“是否发动该效果”的中文确认，通过 C++ 语义接口提交发动或不发动；
Godot 不解析原始 loc_info、描述编号或响应字节。

本轮不实现 `MSG_SELECT_OPTION` 及其后的祭品、计数器、求和、多选切换，也不承诺
一次效果结算能跨过所有尚未支持的后续决策。若核心随后返回其他 Unsupported，
界面必须保留明确诊断和重开/退出能力。

## 协议与原生模型

仓库锁定的 `third_party/ygopro-core/playerop.cpp` 写出以下正文：

```text
message_type: u8 = MSG_SELECT_EFFECTYN
player: u8
card_code: u32 little-endian
controller: u8
location: u8
sequence: u32 little-endian
position: u32 little-endian
description: u64 little-endian
```

解析器要求正文恰好 24 字节、玩家与控制者均为 0 或 1、location 为单一非零
区域标志。成功时发布新的 `PendingActionKind::EffectYesNo`，并在
`PendingAction` 保存：

- `effect_card_id`
- `effect_controller`
- `effect_location`
- `effect_sequence`
- `effect_position`
- `description`

这些字段是 OCGCore 来源位置的不可变快照。响应构造器只接受
`EffectYesNo`，按小端 `int32(1/0)` 编码发动或不发动；普通 `YesNo` 与
`EffectYesNo` 保持不同 kind，避免攻击路线等现有 YesNo 上下文误消费效果确认。

`DuelSession::submit_effect_yes_no(bool)` 保存完整提交前快照供 Retry 恢复。
自动对手只在 `player == 1` 的合法 EffectYesNo 上确定性返回“不发动”，通过
Session 语义接口提交；本地玩家和异常快照停止。

## Bridge 与 Godot 数据流

Bridge 发布稳定字典：

```text
kind = "effect_yes_no"
player
description
effect_card_id
effect_controller
effect_location
effect_sequence
effect_position
```

新增 `submit_effect_yes_no(accepted)`，沿用活动会话、终局和本地玩家门禁。
Godot Main 只接受当前本地 `effect_yes_no` 快照的提交信号，使用现有提交锁和
Retry 同代重建规则；不会调用普通 `submit_yes_no`。

`DuelBoard` 使用已有确认浮层显示：

```text
是否发动「卡名」的效果？
```

若快照无法从当前场面或手牌稳定匹配来源卡，则退化显示：

```text
是否发动该卡的效果？
```

显示名只来自 C++ 已发布的可见卡片快照或卡库查询结果，不得泄露对手里侧卡身份。
按钮文字为“发动”和“不发动”。重开、退出继续作为本地系统脱困入口；阶段确认
不能覆盖规则确认。

首次等待显示“请选择是否发动卡片效果”。OCGCore Retry 显示
“OCGCore 拒绝了响应，请重新选择是否发动效果”。本地调用失败保留失败原因，
不得伪装成 Retry。

## 测试与验收

- 原生解析：合法双方位置、完整 64 位描述，以及截断、尾随、非法玩家、非法
  控制者、零/组合 location。
- 响应与 Session：精确四字节、错误 kind、真实候选提交、重复提交、Retry
  快照转换契约。
- 自动对手：纯策略分支，并用真实 OCGCore 效果触发路径证明推进器调用语义接口；
  若固定素材无法稳定产生玩家 2 EffectYesNo，必须保留纯策略证据并明确记录真实
  集成缺口，不得用错位 Processor 伪造。
- Bridge：完整字典、独立绑定、非本地/终局/无会话门禁和自动推进。
- Godot：效果确认显示、双击锁、普通 YesNo 隔离、Retry、失败、重开、退出、
  旧代次和终局清理。
- 响应式：1920×1080、3840×2160、1920×1200 下确认层位于 SafeArea。
- Godot MCP：真实项目加载场景树，操作发动/不发动或受控场景主路径、取消/非法
  路径和状态回传；停止实例并清除 MCP 注入文件。
