# OCGCore 攻击目标情境交互设计

## 背景

YGO Offline 已能从真实 `MSG_SELECT_BATTLECMD` 显示攻击动作，并能把攻击者候选
提交给 OCGCore。当前缺口发生在攻击声明之后：OCGCore 可能继续返回
`MSG_SELECT_YESNO` 询问是否直接攻击，也可能返回 `MSG_SELECT_CARD` 要求选择攻击
目标；解析器目前把这两类消息标记为“不支持”，导致基础战斗流程中断。

本阶段要在不复制规则、不推测目标的前提下，提供接近《游戏王：大师决斗》的情境式
点击体验：

- 点击己方怪兽的“攻击”声明攻击。
- 点击对手 LP 选择直接攻击。
- 点击对手怪兽选择攻击目标。
- 所有最终合法性、候选集合和响应约束均来自 OCGCore。

## 范围

本规格包含：

1. 解析并提交通用 `MSG_SELECT_YESNO`。
2. 解析并提交单选攻击目标所需的 `MSG_SELECT_CARD`。
3. 将待决策语义通过 GDExtension Bridge 暴露给 Godot。
4. 在现有原生 `DuelBoard`、`ZoneView` 和对手 LP 面板上实现攻击情境交互。
5. 支持“先点击怪兽、再由 OCGCore 校验”的快捷预选。
6. 自动化覆盖合法、非法、取消、过期快照、直击与目标攻击。
7. 使用 Godot MCP 验收真实引擎布局与交互，并清理所有注入文件。

本规格不包含：

- 通用多选卡牌操作、排序、宣言卡名或计数器选择。
- 连锁响应、效果发动确认和任意卡牌效果的完整 UI。
- 在 Godot 中解析或构造 OCGCore 原始响应字节。
- 由前端根据场面、卡片效果或 `direct_attackable` 自行计算攻击目标。
- 攻击箭头、粒子、音效或彩色美术资源。

若真实基础流程在本阶段遇到非攻击用途的 `MSG_SELECT_CARD`，C++ 仍应完整解析其通用
单选语义；Godot 只在当前上下文能映射为场上攻击目标时使用卡位交互，其余上下文显示
明确的中文“不支持当前选择上下文”，不得误提交。

## OCGCore 协议事实

### `MSG_SELECT_YESNO`

消息正文依次为：

1. 消息类型 `uint8`。
2. 决策玩家 `uint8`。
3. 描述标识 `uint64`。

响应为一个 4 字节有符号整数语义：

- `0`：否。
- `1`：是。

攻击流程中描述标识 `31` 表示“是否直接攻击”。当攻击者既能直接攻击又存在怪兽目标
时，OCGCore 先发出该询问；只有回答“否”后，才会继续返回合法怪兽候选。

### `MSG_SELECT_CARD`

消息正文依次为：

1. 消息类型 `uint8`。
2. 决策玩家 `uint8`。
3. 是否可取消 `uint8`。
4. 最少选择数 `uint32`。
5. 最多选择数 `uint32`。
6. 候选数量 `uint32`。
7. 每个候选的卡号 `uint32` 与 `loc_info`：
   `controller uint8`、`location uint8`、`sequence uint32`、
   `position uint32`。

本阶段只允许提交 `min=1 && max=1` 的单选卡牌决策。候选响应使用 OCGCore 支持的
32 位索引列表格式，并由 `DuelSession` 独占构造。取消使用 OCGCore 约定的 `-1`，
且仅在 `cancelable=true` 时允许。

解析器必须验证玩家编号、布尔字段、选择数量关系、候选数量与帧剩余长度；任何截断、
越界或不一致都返回中文 `Malformed` 诊断，不保留半解析候选。

## C++ 领域模型

### 新的待决策类型

`PendingActionKind` 增加：

- `YesNo`：通用是/否询问。
- `SelectCard`：卡牌候选选择。

`PendingAction` 增加：

- `std::uint64_t description`：规则描述标识。
- `bool cancelable`：是否允许取消。
- `std::uint32_t min_select`：最少选择数量。
- `std::uint32_t max_select`：最多选择数量。
- `std::vector<CardSelectionOption> card_options`：候选列表。

`CardSelectionOption` 是值类型，字段为：

- `index`：候选在当前 OCGCore 消息中的索引。
- `card_id`：卡号；对手里侧卡在桥接层仍不得泄露身份。
- `controller`、`location`、`sequence`、`position`：规则定位信息。

该类型只描述 OCGCore 已给出的候选，不持有核心指针或消息缓冲区。

### 会话接口

`DuelSession` 增加以下语义接口：

- `submit_yes_no(bool accepted)`。
- `submit_card_selection(std::size_t option_index)`。
- `cancel_card_selection()`。

每个接口必须：

1. 要求活动决斗存在。
2. 要求当前 `PendingActionKind` 精确匹配。
3. 检查当前决策玩家、候选索引和取消能力。
4. 只根据当前待决策快照构造响应。
5. 在提交前保存 `last_submitted_action_`，使 `MSG_RETRY` 能重放原决策。
6. 清空当前快照并立即调用 `process_once()`。

Godot 不获得原始响应字节，也不能调用“提交任意整数”之类的旁路接口。

## Bridge 契约

`get_pending_action()` 对新决策暴露：

- `kind`: `"yes_no"` 或 `"select_card"`。
- `description`、`cancelable`、`min_select`、`max_select`。
- `card_options`：只包含语义字段和候选索引。

Bridge 增加：

- `submit_yes_no(accepted: bool)`。
- `submit_card_selection(option_index: int)`。
- `cancel_card_selection()`。

负数索引或超出 `std::size_t`/当前候选范围的值必须在 Bridge 或 Session 边界被拒绝，
返回简体中文错误。对手里侧候选的 `card_id` 必须在输出字典中省略或置零，保持现有
隐藏信息策略。

## Godot 交互状态机

Godot 只消费 Bridge 的语义快照。`Main` 负责把决策转换成 `DuelBoard` 快照字段，
`DuelBoard` 负责表现和发出用户意图，`Main` 再调用 Bridge。

### 状态 A：选择攻击者

现有行为保持不变：

- 玩家点击己方怪兽。
- 情境动作条显示 OCGCore 的“攻击”候选。
- 点击“攻击”调用 `submit_battle_action("attack", index)`。

此时记录攻击者的规则位置仅用于视觉选择反馈，不用于推断后续候选。

### 状态 B：直击确认

当 `kind == "yes_no"` 且 `description == 31`、决策玩家为本地玩家：

- 对手 LP 面板进入 `direct_attack_targetable` 高亮和可点击状态。
- 对手有卡的怪兽区进入 `attack_target_preview` 状态。预览只表示“可尝试进入怪兽
  目标选择”，不表示该怪兽已被 OCGCore 判定合法。
- 状态提示显示“点击对手 LP 直接攻击，或点击怪兽选择目标”。
- 点击对手 LP 发出 `direct_attack_requested`，由 `Main` 提交
  `submit_yes_no(true)`。
- 点击任意对手怪兽发出包含其规则位置的 `attack_target_preview_requested`，
  `Main` 暂存该位置后提交 `submit_yes_no(false)`。
- 点击取消按钮等价于回答“否”后等待目标，仅当用户明确要放弃整个攻击且后续
  `MSG_SELECT_CARD.cancelable` 为真时，才允许在下一状态取消；不能把 `YesNo` 的
  “否”错误解释成取消攻击。

如果是其他 `MSG_SELECT_YESNO`：

- 使用现有确认浮层显示“是”“否”。
- 描述标识暂以数值和中文通用提示展示。
- 两个按钮分别提交 `true`、`false`。

### 状态 C：真实目标选择

当 `kind == "select_card"` 且为本地玩家、`min_select == 1`、
`max_select == 1`，并且所有可显示候选都位于对手怪兽区：

- 清除预览样式。
- 仅将 `card_options` 指定的卡位设为 `targetable`。
- 点击高亮卡位按该候选的 `index` 发出 `attack_target_requested`。
- `Main` 调用 `submit_card_selection(index)`。
- 若状态 B 暂存的预选位置与一个候选精确匹配，则在渲染新快照后自动提交该候选，
  实现一次点击完成怪兽攻击。
- 若预选位置不合法，则清除预选，不提交任何候选，并保留真实目标高亮供玩家重选。
- `cancelable == true` 时显示“取消攻击”；点击调用 `cancel_card_selection()`。
- `cancelable == false` 时不得显示或响应取消入口。

候选映射必须同时比较 `controller`、`location` 和 `sequence`，不能只按卡号或视觉
节点序号匹配。

### 状态 D：完成、拒绝或新快照

- 每次成功提交后立即锁定交互，直到收到新快照。
- 新快照清除 LP、卡位预览、目标高亮、攻击者选择和暂存预选。
- Bridge 拒绝提交时保留当前合法快照，恢复可操作状态，并显示中文失败原因。
- `MSG_RETRY` 由 Session 恢复上一份决策语义，不允许 Godot 猜测重试内容。
- 对手或非本地玩家的决策不显示可点击目标。

## 原生场景与 Theme

固定视觉结构必须继续由 `.tscn` 和共享 `duel_theme.tres` 管理：

- 对手状态面板增加全尺寸、忽略鼠标的直击高亮覆盖层；点击仍由状态面板根控件接收。
- `ZoneView` 复用现有 `TargetHighlight`，新增预览与合法目标两个 Theme 变体，
  以及不改变规则状态的表现接口。
- 确认浮层复用现有原生容器；按钮文本与可见性由快照驱动。
- 所有新增提示、错误、按钮与诊断使用简体中文。
- 1080p、4K Stretch 和 16:10 下不得遮挡阶段球、系统按钮、手牌或确认层。

不新增运行时构造的固定 Panel、Label 或覆盖层。动态候选按钮可继续按数据创建，但
攻击目标优先直接绑定卡位与 LP 面板，不另建右侧操作列表。

## 数据与权限边界

- C++ 解析 OCGCore、验证候选、构造响应并推进规则。
- Bridge 只翻译值类型，不保存 UI 选择状态。
- `Main` 保存一次性的预选规则位置，用于跨越 YesNo→SelectCard 两个快照。
- `DuelBoard` 保存当前表现状态并发出语义信号，不修改 LP、卡位或候选。
- `ZoneView` 与卡片视图只负责表现与点击。

任何 UI 点击都不能提前改变 LP、破坏卡片或移动区域。场面变化必须来自后续
`get_duel_state()`。

## 错误处理

- 截断或非法协议：返回 `Malformed`，中文说明具体字段或长度问题。
- 未支持的多选：保留 `SelectCard` 快照但禁用提交，界面提示当前原型只支持单选。
- 候选无法映射到可见卡位：不丢弃决策；显示中文诊断和通用候选信息，禁止伪造点击。
- 预选目标不合法：不视为错误，不自动提交；显示真实合法目标。
- 非当前快照索引、重复提交、负数索引、不可取消时取消：Session 拒绝且不推进核心。
- 终局到达时：终局快照优先，清除全部目标交互。

## 测试策略

### C++ 单元测试

`test_duel_message_parser` 覆盖：

- `MSG_SELECT_YESNO` 正常、截断、非法玩家。
- `MSG_SELECT_CARD` 正常单选、可取消、多个候选、截断候选、非法数量关系、非法玩家。
- 连续通知帧后保留 LP/胜负事件。

`test_duel_session` 覆盖：

- 是、否响应。
- 合法候选索引与可取消选择。
- 错误决策类型、越界索引、不可取消、重复提交。
- `MSG_RETRY` 后恢复原始 YesNo/SelectCard 决策。
- 真实攻击者→直击→LP 变化路径。
- 真实攻击者→怪兽目标→战斗结果路径；若演示卡组无法稳定制造目标场面，则使用
  固定消息与 Session 响应边界测试证明协议，真实 MCP 流程证明可达性。

### Godot 契约测试

- 原生场景节点、Theme 变体、默认输入策略。
- 直击 LP 高亮与点击信号。
- 对手怪兽预选、合法目标高亮、非法预选回退。
- 自动提交合法预选时只提交一次。
- `cancelable` 控制取消入口。
- 新快照、失败、终局清理所有表现状态。
- 1920×1080、3840×2160 Stretch、1920×1200 满载布局安全。

### Godot MCP 验收

1. 读取场景树，确认新增固定节点来自 `.tscn`，Theme 变体已消费。
2. 启动真实项目并进入战斗阶段。
3. 声明攻击，检查 LP 和怪兽预览状态。
4. 走一次直接攻击，确认 LP 只在 OCGCore 快照后变化。
5. 走一次怪兽预选；合法时自动提交，非法时显示真实候选。
6. 检查取消、重复点击和非法点击。
7. 在 1080p、宿主可提供的高分辨率窗口和 16:10 下读取关键矩形。
8. 停止运行，删除 MCP 注入脚本和 Autoload，确认工作区无残留。

## 完成标准

只有同时满足以下条件，本阶段才算完成：

1. `MSG_SELECT_YESNO` 与单选 `MSG_SELECT_CARD` 不再进入 Unsupported。
2. 所有响应均由 `DuelSession` 根据当前 OCGCore 快照验证并构造。
3. 玩家可通过点击对手 LP 完成真实直接攻击。
4. 玩家可通过点击对手怪兽完成合法目标选择；非法预选不会被提交。
5. 取消、拒绝、快照失效、终局和重试路径都有明确行为。
6. UI 不自行修改 LP、场面或胜负。
7. 原生构建、全部 CTest、Godot UI 契约和无界面启动通过。
8. Godot MCP 完成真实攻击路径和多分辨率验收，且无注入残留。
