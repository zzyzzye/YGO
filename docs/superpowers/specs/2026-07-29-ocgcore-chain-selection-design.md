# OCGCore 连锁候选情境交互设计

## 目标与范围

实现带候选的 `MSG_SELECT_CHAIN`，让玩家能够在真实 OCGCore 响应窗口中：

- 查看哪些手牌或场上卡可以发动；
- 点击候选卡，再选择该卡具体效果；
- 在非强制窗口选择“不连锁”；
- 在强制窗口只能选择合法候选；
- 在核心拒绝响应后保留同一连锁入口重试。

本阶段不实现连锁动画、连锁历史面板或卡片描述编号的自然语言翻译。它们不影响
基础规则流程，候选效果暂以稳定序号与描述编号区分。

## 方案选择

采用“候选卡高亮 → 点击卡 → 情境按钮”的方案。

- 全局候选列表虽然实现简单，但脱离场上卡牌，和既有情境式交互不一致。
- 点击卡立即发动无法区分同一卡片的多个效果，也容易因误触提交。
- 两步情境交互既能支持同卡多效果，又能沿用现有卡牌详情与动作栏。

## C++ 语义边界

新增 `PendingActionKind::SelectChain` 和 `ChainOption`：

- `index`：OCGCore 候选表中的稳定索引；
- `card_id`、`controller`、`location`、`sequence`、`position`：处理卡位置；
- `description`、`client_mode`：区分同卡不同效果；
- `forced`：位于 PendingAction，决定是否允许跳过。

严格解析正文：

```text
message_type:u8
player:u8
special_count:u8
forced:u8
hint_timing_player:u32
hint_timing_opponent:u32
candidate_count:u32
candidate[candidate_count]:
  card_id:u32
  controller:u8
  location:u8
  sequence:u32
  position:u32
  description:u64
  client_mode:u8
```

每项固定 23 字节。玩家与 forced 必须合法，声明数量必须与剩余长度精确匹配，
不得暴露半解析候选。`forced=0,count=0` 继续自动跳过；`forced=1,count=0`
视为矛盾畸形帧；任何有候选的帧都成为 SelectChain。

响应只由 C++ 构建：

- 发动：候选 `index` 的小端 `int32`；
- 不连锁：仅 `forced=false` 时允许小端 `int32(-1)`；
- 非候选、强制窗口跳过、过期决策均在写入核心前拒绝。

## Godot 交互

Bridge 只公开已经过 C++ 校验的 `chain_options` 与 `chain_forced`，提供
`submit_chain(index)` 和 `pass_chain()`。

DuelBoard 对本地候选进行位置映射：

- 手牌、己方怪兽区、己方魔陷区和公开可定位的对手场区均可作为候选来源；
- 可发动卡使用独立高亮，不复用攻击目标含义；
- 点击候选卡后，在 `ContextActionBar` 为该位置的每个候选创建“发动效果”
  按钮；多效果按“发动效果 1/2…”区分，并显示描述编号；
- 非强制窗口始终保留“不连锁”按钮；
- 强制窗口显示“必须选择一个连锁效果”，没有跳过按钮。

任何背景点击、阶段按钮、重开/退出确认都不得覆盖核心等待入口。每份快照使用
决策代次，旧卡节点、旧按钮、双击和同步重入不能提交下一份同形连锁决策。

隐藏卡只公开位置，不公开 `card_id`；Bridge 继续执行秘密信息门禁。若候选无法
完整映射到当前真实卡节点，保留 pending 并显示中文诊断，不创建部分可提交 UI。

## 状态与错误

- Bridge 本地失败：保留当前 pending、高亮和按钮，显示中文错误。
- `MSG_RETRY`：使用 `response_rejected` 恢复同一 SelectChain 和决策代次。
- 成功：清除旧高亮/按钮，刷新 OCGCore 场面和下一份决策。
- 对手决策：沿用确定性对手策略；可选连锁跳过，强制连锁选择第一个核心候选。
- 终局或重开：清除所有连锁表现和过期输入。

## 验收

- 原生测试覆盖严格帧、同卡多效果、强制/可选、发动/跳过、非法输入和 Retry。
- Godot 测试覆盖手牌与场区高亮、同卡多按钮、不连锁、强制门禁、失败/Retry、
  旧节点重入、不可完整映射和终局清理。
- 真实 OCGCore 固定卡组触发至少一个有候选的本地连锁窗口，完成发动或跳过后
  场面继续推进。
- 1920×1080、3840×2160、1920×1200 下候选按钮位于安全区且不遮挡手牌。
- Godot MCP 使用真实节点点击候选卡与按钮，并验证场景树、状态回传和清理。
