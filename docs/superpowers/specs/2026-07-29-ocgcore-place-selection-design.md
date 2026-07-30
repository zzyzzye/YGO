# OCGCore 情境式区域选择设计

## 目标

把 `MSG_SELECT_PLACE` 从“召唤/盖放后静默选择第一个区域，其他来源直接
Unsupported”升级为真实的本地玩家决策。玩家在原生决斗场上直接点击
OCGCore 给出的合法空卡位，C++ 校验并提交准确的
`controller/location/sequence` 三元组。

完成后，通常召唤、特殊召唤、怪兽盖放、魔陷盖放以及效果产生的基础五区
选位都遵循同一条语义链路，不再由客户端替玩家暗选。

## 现状与问题

当前解析器已能读取 `count=1` 的 `MSG_SELECT_PLACE`，但将其标为
`AutoSelectPlace`。`DuelSession` 仅允许召唤或盖放紧随其后的选区，并自动提交
第一项；其他来源被改写为 Unsupported。

这存在三个问题：

1. 相同动作在不同空位上可能影响后续规则，自动选择改变玩家决策。
2. Godot 场地卡位没有真正参与规则输入，违背情境式交互目标。
3. 效果要求选择区域时会阻断真实 OCGCore 流程。

## 方案比较

### 方案 A：继续自动选择，仅增加状态提示

实现最少，但仍替玩家决策，也不能处理效果选区，不符合目标。

### 方案 B：Godot 直接解释 forbidden 位掩码

界面实现快，但把 OCGCore 协议、位宽和双方映射泄漏到 GDScript，容易出现
玩家 2、高位掩码和扩展区域错位，违反 C++/Godot 边界。

### 方案 C：C++ 发布完整语义候选，Godot 只映射并点击原生卡位

采用此方案。C++ 独占协议解析、候选身份和响应组包；Godot 只消费稳定三元组，
先全量映射候选，再原子显示卡位高亮。它能复用现有决策代次和 Retry 机制，也为
额外怪兽区、场地区等后续可视节点保留扩展空间。

## 协议与规则模型

### 解析

`MSG_SELECT_PLACE` 正文严格为：

- `uint8 message_type`
- `uint8 player`
- `uint8 count`
- `uint32 forbidden`（小端）

当前里程碑支持 `count=1`。解析器必须：

- 要求正文恰好 7 字节，拒绝截断与尾随字节；
- 仅接受玩家 0 或 1；
- 将低 16 位解释为决策玩家一侧，高 16 位解释为另一侧；
- 将每个为 0 的可选位展开为 `PlaceOption{player, location, sequence}`；
- 怪兽区对应位 0–6，魔陷区对应位 8–15；
- 拒绝零候选；
- `count!=1` 明确 Unsupported，不能伪装成单选。

有效单选返回新的 `PendingActionKind::SelectPlace`。删除
`AutoSelectPlace` 以及 `allow_auto_select_place_`，使所有来源走同一玩家决策。

### 响应

新增纯值构建器：

```cpp
DuelResponse build_place_response(
    const PendingAction &pending_action,
    std::uint8_t player,
    std::uint8_t location,
    std::uint8_t sequence);
```

它只接受当前 `SelectPlace` 快照中完全匹配的候选，并输出三个原始字节。候选外
三元组、错误决策类型和过期快照都返回中文错误且不产生响应字节。

`DuelSession::submit_place(...)` 保存完整提交前快照，写入 OCGCore 后推进；
`MSG_RETRY` 恢复同一候选集合。区域选择不再依赖前一个动作类型。

## C++ / Godot 边界

Bridge 在 `pending_action` 字典中始终输出 `place_options`，每项只包含：

```text
controller: int
location: int
sequence: int
```

这里沿用界面语义命名 `controller`，值来自 C++ `PlaceOption.player`。Bridge
新增 `submit_place(controller, location, sequence)`，并执行与其他本地决策
一致的活动会话、终局、本地玩家、非负/uint8 范围门禁。GDScript 不接触
`forbidden` 位掩码或原始响应字节。

## Godot 情境交互

`DuelBoard` 收到本地 `select_place` 快照后：

1. 将每个候选映射到现有双方五个怪兽区或五个魔陷区。
2. 要求目标卡位为空，并且位置与候选三元组完全一致。
3. 必须先成功映射全部候选，才发布任何高亮或可点击入口。
4. 点击高亮卡位后发出
   `place_requested(controller, location, sequence, decision_generation)`。
5. 首次点击立即使本代入口失效，避免双击；新决策快照增加代次。
6. `MSG_RETRY` 保留代次并重建相同候选，允许重新点击。
7. 重开、终局、非本地决策和任何新快照都清除旧高亮与绑定。

卡位使用 `ZoneView` 的原生输入和主题变体显示黑白高亮，不创建悬浮于右侧的
操作列表。状态文字为“请选择放置区域”。当前场景只有双方五个基础怪兽区和
五个基础魔陷区；若候选包含 sequence 超出 0–4 的额外怪兽区、场地区或其他
尚无节点的区域，本轮不显示部分候选、不提交默认值，并以中文状态明确提示
“区域候选无法完整映射到当前场地”。这保证安全性，同时将扩展区域留给独立
布局里程碑。

## 数据流

```text
OCGCore MSG_SELECT_PLACE
  -> C++ 严格解析 PlaceOption[]
  -> DuelSession 保存不可变 PendingAction
  -> Bridge 输出 place_options
  -> Main 转发规则快照
  -> DuelBoard 全量映射并高亮空 ZoneView
  -> 玩家点击卡位
  -> Main 校验 decision_generation
  -> Bridge.submit_place(...)
  -> DuelSession 候选校验和三字节响应
  -> OCGCore 推进并重新查询场面
```

## 错误与并发输入

- 解析异常返回 Malformed，不暴露半成品候选。
- 多选请求返回 Unsupported，不擅自缩窄成单选。
- 未映射或非空卡位不产生可点击信号。
- Main 只接受当前决策代次的一次提交；提交进行中忽略重复输入。
- Bridge 和 Session 再次验证当前快照，防止伪造 GDScript 信号绕过规则。
- Retry 恢复提交前快照并保留代次；其他结果使旧节点全部失效。

## 验收

### 原生测试

- 严格解析双方怪兽区/魔陷区候选、玩家 2 高低位映射、截断、尾随、零候选、
  非法玩家和 `count!=1`。
- 响应构建器验证精确三字节、候选外三元组和错误类型。
- Session 验证真实提交、重复提交和伪造候选；不以错位 Processor 制造 Retry。
- 真实 OCGCore 固定牌组与种子：通常召唤或盖放到非首个合法区域，查询快照
  证明卡片进入玩家选择的 sequence，而非解析器第一项。

### Godot 测试

- 四类基础卡位正确高亮，非候选和已占用卡位不可点。
- 全量映射失败时无部分高亮、无信号。
- 单击提交精确三元组；双击、旧代次和重开后旧节点不提交。
- Retry 恢复同一代次，下一次成功决策使用新代次。
- 1920×1080、3840×2160 与 1920×1200 下高亮和卡位都在 SafeArea 内。

### Godot MCP

运行真实项目，通过场景树和截图确认 1920×1080 与 3840×2160 的原生场地；
使用真实鼠标点击可选空卡位，确认高亮消失、场面刷新且调试输出无项目错误。

## 最终审查修订

区域选择上线前还需补齐以下边界，且不得扩大为未实现决策类型的通用自动策略：

1. `advance_to_local_decision` 遇到玩家 2 的 `SelectPlace` 时，通过独立纯策略
   校验快照并确定性选择候选首项，再调用 `DuelSession::submit_place`。本地玩家、
   空候选或异常候选必须停止，不能构造默认三元组或原始响应。
2. 重开与退出是本地系统脱困入口，不是 OCGCore 规则响应。即使区域候选无法
   映射，它们也必须能够打开确认浮层；阶段选项仍受规则交互门禁约束。取消确认
   只关闭浮层，不消费或改写当前待决快照。
3. Session 的 Retry 回归不得用 `private public` 篡改 `pending_action_`，也不得
   把 SelectPlace 响应故意发送给 Idle Processor。Retry 证据只能来自真实
   OCGCore 状态，无法稳定制造时删除该失真用例，并由解析、响应构造、真实提交
   与 Bridge/Godot Retry 契约分层覆盖。
4. 区域提交门禁辅助函数属于 Bridge 实现细节，不作为项目公开 C++ API；Godot
   只绑定 `submit_place(controller, location, sequence)` 语义入口。
5. 首次等待区域输入时显示“请选择放置区域”；`MSG_RETRY` 恢复后显示
   “OCGCore 拒绝了响应，请重新选择放置区域”。

这轮修订不实现 `MSG_SELECT_EFFECTYN`、`MSG_SELECT_OPTION`、
`MSG_SELECT_TRIBUTE`、`MSG_SELECT_COUNTER`、`MSG_SELECT_SUM`、
`MSG_SELECT_UNSELECT_CARD`，也不为额外怪兽区、场地区等新增界面节点。
