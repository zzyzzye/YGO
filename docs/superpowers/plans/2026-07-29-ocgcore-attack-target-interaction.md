# OCGCore 攻击目标情境交互 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让玩家通过点击对手 LP 或怪兽完成由真实 OCGCore 驱动的直接攻击和怪兽目标选择。

**Architecture:** C++ 解析并验证 `MSG_SELECT_YESNO` 与单选 `MSG_SELECT_CARD`，`DuelSession` 独占响应组包；Bridge 只暴露值类型语义。Godot 的 `Main` 编排跨消息预选，`DuelBoard` 与原生场景只显示 LP/卡位候选并发出点击意图，场面与 LP 始终从 OCGCore 快照刷新。

**Tech Stack:** C++20、OCGCore 11、Godot 4.6 GDExtension、GDScript、CMake/CTest、Godot MCP。

## Global Constraints

- 项目文件全部保存在 `/Volumes/WD/YGO`。
- 新增或修改的自有代码包含解释设计意图、协议约束和失败处理的中文注释。
- 项目自有日志、警告、错误、断言和用户可见文本使用简体中文。
- Godot 不解析或构造 OCGCore 原始字节，不推测合法目标，不提前修改 LP 或场面。
- 对手里侧卡的 `card_id` 不得经 Bridge 泄露。
- 固定 UI 节点与共享视觉使用 `.tscn`/`.tres`；只允许数据数量驱动的按钮动态创建。
- 场景修改必须经 Godot MCP 读取和运行验收，并在结束后清理注入脚本与 Autoload。
- 每个提交使用中文 Conventional Commits 标题和详细正文。

---

### Task 1: 解析 YesNo 与单选卡牌候选

**Files:**
- Modify: `native/include/ygo/duel_message_parser.hpp`
- Modify: `native/src/duel_message_parser.cpp`
- Modify: `native/tests/test_duel_message_parser.cpp`

**Interfaces:**
- Produces: `PendingActionKind::YesNo`、`PendingActionKind::SelectCard`。
- Produces: `CardSelectionOption` 和 `PendingAction::{description,cancelable,min_select,max_select,card_options}`。
- Consumes: OCGCore `MSG_SELECT_YESNO`、`MSG_SELECT_CARD` 帧格式。

- [x] **Step 1: 为 YesNo 写失败测试**

在 `test_duel_message_parser.cpp` 增加正常帧、非法玩家和截断描述测试：

```cpp
std::vector<std::uint8_t> yes_no{MSG_SELECT_YESNO, 0};
append_u64(yes_no, 31);
const auto pending = ygo::parse_pending_action(
		framed(yes_no).data(), framed(yes_no).size());
assert(pending.kind == ygo::PendingActionKind::YesNo);
assert(pending.player == 0);
assert(pending.description == 31);
```

测试必须用局部 `stream` 保存 `framed()` 返回值，避免临时容器指针失效；另断言非法玩家和少于 10 字节的正文返回 `Malformed` 与中文诊断。

- [x] **Step 2: 运行解析器测试确认红灯**

Run:

```bash
cmake --build build/native --target test_duel_message_parser -j 10
./build/native/native/test_duel_message_parser
```

Expected: 编译失败，提示 `YesNo` 或 `description` 尚不存在。

- [x] **Step 3: 为 SelectCard 写失败测试**

增加构造单选帧的测试辅助函数，并覆盖：

```cpp
// 玩家0、可取消、min=max=1、两个候选。
std::vector<std::uint8_t> select{MSG_SELECT_CARD, 0, 1};
append_u32(select, 1);
append_u32(select, 1);
append_u32(select, 2);
append_card_option(select, 123, 1, LOCATION_MZONE, 0, POS_FACEUP_ATTACK);
append_card_option(select, 456, 1, LOCATION_MZONE, 4, POS_FACEUP_DEFENSE);
```

断言候选索引为 `0/1`，位置字段逐项准确。再分别覆盖：

- `player=2`。
- `cancelable=2`。
- `min > max`。
- `max > candidate_count`。
- 第二个 `loc_info` 截断。

全部非法输入必须返回 `Malformed`，且 `card_options` 为空。

- [x] **Step 4: 实现值类型和两个解析函数**

在头文件增加：

```cpp
enum class PendingActionKind {
	None,
	Idle,
	Battle,
	YesNo,
	SelectCard,
	AutoPassChain,
	AutoSelectPlace,
	Retry,
	Unsupported,
	Malformed,
};

struct CardSelectionOption {
	std::size_t index = 0;
	std::uint32_t card_id = 0;
	std::uint8_t controller = 0;
	std::uint8_t location = 0;
	std::uint32_t sequence = 0;
	std::uint32_t position = 0;
};
```

在 `PendingAction` 末尾增加规格中的五个字段。实现
`parse_yes_no_message()` 与 `parse_select_card_message()`；使用 `ByteReader`
逐字段读取并在成功前不写入最终候选。`parse_pending_action()` 对两种消息显式分派，
并从 `requires_player_response()` 的 Unsupported 路径中移除。

- [x] **Step 5: 运行解析器测试确认绿灯**

Run:

```bash
cmake --build build/native --target test_duel_message_parser -j 10
./build/native/native/test_duel_message_parser
```

Expected: PASS，退出码 0。

- [x] **Step 6: 提交解析器变更**

```bash
git add native/include/ygo/duel_message_parser.hpp \
  native/src/duel_message_parser.cpp \
  native/tests/test_duel_message_parser.cpp
git commit -m "feat(规则): 解析攻击确认与卡牌候选" \
  -m "接入 MSG_SELECT_YESNO 与 MSG_SELECT_CARD 的完整长度和字段校验，向上层提供稳定值类型候选。" \
  -m "验证：test_duel_message_parser 通过。"
```

---

### Task 2: 用 DuelSession 校验并提交语义响应

**Files:**
- Create: `native/include/ygo/duel_response.hpp`
- Create: `native/src/duel_response.cpp`
- Create: `native/tests/test_duel_response.cpp`
- Modify: `native/include/ygo/duel_session.hpp`
- Modify: `native/src/duel_session.cpp`
- Modify: `native/tests/test_duel_session.cpp`
- Modify: `native/CMakeLists.txt`

**Interfaces:**
- Consumes: Task 1 的 `PendingActionKind` 与 `card_options`。
- Produces: `submit_yes_no(bool)`。
- Produces: `submit_card_selection(std::size_t)`。
- Produces: `cancel_card_selection()`。

- [x] **Step 1: 写响应构造与会话门禁失败测试**

新增纯值类型 `DuelResponse`：

```cpp
struct DuelResponse {
	bool ok = false;
	std::string message;
	std::vector<std::uint8_t> bytes;
};
```

在 `test_duel_response.cpp` 直接构造 `PendingAction`，测试
`build_yes_no_response()`、`build_card_selection_response()` 和
`build_card_selection_cancel_response()`。至少断言错误 kind、候选越界、不可取消、
合法索引的 12 字节内容和取消的 `ff ff ff ff`。在现有 Session 测试中再断言当前
Idle 决策调用 `submit_yes_no(true)` 返回“当前不是是非选择”且快照不变。

- [x] **Step 2: 运行会话测试确认红灯**

Run:

```bash
cmake --build build/native --target test_duel_session -j 10
./build/native/native/test_duel_session
```

Expected: 编译失败，`duel_response.hpp` 和三个语义接口尚不存在。

- [x] **Step 3: 实现纯响应构造器**

`duel_response.cpp` 根据传入的不可变 `PendingAction` 完成全部 kind、候选与取消
验证，并返回字节；不得调用 OCGCore。YesNo 的合法响应为：

```cpp
const std::int32_t value = accepted ? 1 : 0;
const std::uint8_t response[4]{
	static_cast<std::uint8_t>(value & 0xff),
	static_cast<std::uint8_t>((value >> 8) & 0xff),
	static_cast<std::uint8_t>((value >> 16) & 0xff),
	static_cast<std::uint8_t>((value >> 24) & 0xff),
};
```

卡牌候选提交先按 `option.index == option_index` 查找当前候选，再返回 OCGCore 的
32 位索引列表响应：

```cpp
const std::uint8_t response[12]{
	0, 0, 0, 0, // type=0，索引宽度为 uint32
	1, 0, 0, 0, // count=1
	static_cast<std::uint8_t>(option_index & 0xffU),
	static_cast<std::uint8_t>((option_index >> 8U) & 0xffU),
	static_cast<std::uint8_t>((option_index >> 16U) & 0xffU),
	static_cast<std::uint8_t>((option_index >> 24U) & 0xffU),
};
```

取消构造器仅在 `SelectCard && cancelable` 时返回 `int32_t(-1)` 的四字节小端值。

- [x] **Step 4: 让 Session 使用响应构造器**

三个 Session 公共方法调用对应构造器；失败时原样返回中文错误和当前快照，不调用
OCGCore。成功时先保存 `last_submitted_action_`、清除自动选区能力，再把
`response.bytes` 交给 `OCG_DuelSetResponse`，清空当前快照并推进。把
`duel_response.cpp` 加入 `ygo_duel_session`，新增 `test_duel_response` CTest。

- [x] **Step 5: 覆盖 Retry 恢复**

构造 OCGCore 拒绝后的 `MSG_RETRY`，断言 `last_submitted_action_` 恢复 YesNo 或
SelectCard 的完整字段和候选，且再次提交仍受相同门禁约束。

- [x] **Step 6: 运行 Session 与全套原生测试**

Run:

```bash
./scripts/build_native.sh
```

Expected: CTest 全部通过，0 失败。

- [x] **Step 7: 提交会话变更**

```bash
git add native/include/ygo/duel_session.hpp \
  native/include/ygo/duel_response.hpp \
  native/src/duel_response.cpp \
  native/src/duel_session.cpp \
  native/tests/test_duel_response.cpp \
  native/CMakeLists.txt \
  native/tests/test_duel_session.cpp
git commit -m "feat(规则): 提交攻击目标语义响应" \
  -m "由 DuelSession 校验是非决策、单选候选和取消能力，并独占构造 OCGCore 响应。" \
  -m "验证：scripts/build_native.sh 全部通过。"
```

---

### Task 3: 通过 Bridge 暴露安全决策

**Files:**
- Create: `native/include/ygo/pending_action_godot_adapter.hpp`
- Create: `native/src/pending_action_godot_adapter.cpp`
- Create: `native/tests/test_pending_action_godot_adapter.cpp`
- Modify: `native/include/ygo/ygo_core_bridge.hpp`
- Modify: `native/src/ygo_core_bridge.cpp`
- Modify: `native/CMakeLists.txt`
- Modify: `src/main/main.gd`

**Interfaces:**
- Consumes: Task 2 的三个 Session 方法。
- Produces: Godot 方法 `submit_yes_no(bool)`、
  `submit_card_selection(int)`、`cancel_card_selection()`。
- Produces: pending 字典字段 `description`、`cancelable`、
  `min_select`、`max_select`、`card_options`。

- [x] **Step 1: 写 Bridge 值转换契约失败测试**

把 `pending_action_to_dictionary(const PendingAction &)` 声明在新的
`pending_action_godot_adapter.hpp` 中，并让新测试直接传入受控值类型，验证：

- `kind` 为 `yes_no`/`select_card`。
- 每个候选包含 `index/controller/location/sequence/position`。
- 对手里侧候选不包含真实 `card_id`，正面候选可以包含。
- `submit_card_selection(-1)` 返回中文范围错误而不窄化。

- [x] **Step 2: 实现值转换并扩展绑定**

把现有转换从 `ygo_core_bridge.cpp` 移入 adapter 源文件，增加两个 kind，并始终写出
选择元数据。候选转换规则：

```cpp
item["index"] = static_cast<std::int64_t>(option.index);
item["controller"] = option.controller;
item["location"] = option.location;
item["sequence"] = static_cast<std::int64_t>(option.sequence);
item["position"] = static_cast<std::int64_t>(option.position);
if (option.controller == 0 || (option.position & POS_FACEUP) != 0) {
	item["card_id"] = static_cast<std::int64_t>(option.card_id);
}
```

三个提交方法复用 `advance_to_local_decision()`；负索引先在 Bridge 拒绝。把方法加入
`_bind_methods()`，方法名和参数名与规格一致。新增 adapter 测试目标，并让 Bridge
链接该源文件。

- [x] **Step 3: 让 Main 识别新决策但暂不添加目标 UI**

`_refresh_board()` 继续原样读取状态，并在 snapshot 中加入：

```gdscript
"decision_kind": str(pending.kind),
"decision_description": int(pending.get("description", 0)),
"selection_cancelable": bool(pending.get("cancelable", false)),
"selection_min": int(pending.get("min_select", 0)),
"selection_max": int(pending.get("max_select", 0)),
"card_options": pending.get("card_options", []),
```

`local_player_turn` 扩展到 `yes_no/select_card`，但仍要求 `player == 0` 且非终局。

- [x] **Step 4: 运行完整原生构建和 Godot 启动**

Run:

```bash
./scripts/build_native.sh
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path /Volumes/WD/YGO --quit-after 3
```

Expected: 原生 CTest 全绿；Godot 无项目自有错误。

- [x] **Step 5: 提交 Bridge 变更**

```bash
git add native/include/ygo/ygo_core_bridge.hpp \
  native/include/ygo/pending_action_godot_adapter.hpp \
  native/src/pending_action_godot_adapter.cpp \
  native/src/ygo_core_bridge.cpp \
  native/tests/test_pending_action_godot_adapter.cpp \
  native/CMakeLists.txt \
  src/main/main.gd
git commit -m "feat(桥接): 暴露攻击目标决策语义" \
  -m "向 Godot 提供经校验的是非与卡牌候选字段，并保持对手里侧信息隐藏。" \
  -m "验证：原生测试与 Godot 无界面启动通过。"
```

---

### Task 4: 建立原生 LP 与怪兽目标表现

**Files:**
- Modify: `src/ui/themes/duel_theme.tres`
- Modify: `src/ui/zone_view.tscn`
- Modify: `src/ui/zone_view.gd`
- Modify: `src/duel/duel_board.tscn`
- Modify: `src/duel/duel_board.gd`
- Modify: `tests/ui/test_native_scene_contract.gd`
- Modify: `tests/ui/test_contextual_duel_layout.gd`

**Interfaces:**
- Consumes: snapshot 的决策与 `card_options`。
- Produces signals:
  `direct_attack_requested`,
  `attack_target_preview_requested(location: Dictionary)`、
  `attack_target_requested(option_index: int)`、
  `card_selection_cancel_requested`、
  `yes_no_requested(accepted: bool)`。
- Produces: `ZoneView.set_attack_target_preview(bool)`。

- [x] **Step 1: 写原生场景红灯契约**

断言 `OpponentStatus` 的原生父容器中存在全锚点 `DirectAttackHighlight`，其
`mouse_filter == Control.MOUSE_FILTER_IGNORE`，默认隐藏并消费
`DirectAttackTarget` Theme 变体。断言 `ZoneView` 能区分：

```gdscript
zone.set_attack_target_preview(true)
assert(zone.target_highlight.visible)
assert(zone.target_highlight.theme_type_variation == &"AttackTargetPreview")
zone.set_targetable(true)
assert(zone.target_highlight.theme_type_variation == &"TargetHighlight")
```

- [x] **Step 2: 运行场景契约确认红灯**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO \
  --script res://tests/ui/test_native_scene_contract.gd
```

Expected: 缺少 LP 高亮或预览 Theme 失败。

- [x] **Step 3: 用 `.tscn`/`.tres` 添加固定视觉**

把 `OpponentStatus` 包入仍由 Container 管理的 `Control`/`PanelContainer`
点击表面，增加忽略输入的高亮覆盖层；不得在 GDScript 中 `Panel.new()`。
为直击、预览、合法目标、已选目标提供黑白层级明确的 StyleBox。所有覆盖层都不得
截获卡牌悬浮或点击。

- [x] **Step 4: 写交互状态机红灯契约**

构造以下快照并直接驱动真实 `DuelBoard` 场景：

- `yes_no + description=31`：LP 高亮，所有有卡对手怪兽只显示预览。
- 点击 LP：只发一次 `direct_attack_requested`。
- 点击怪兽预览：只发一次规则位置字典，未发候选 index。
- `select_card`：仅 options 中的 zone 高亮。
- 点击合法 zone：发 option index。
- 不可取消：无取消按钮；可取消：显示“取消攻击”并发取消信号。
- 通用 YesNo：确认层显示“是”“否”，不显示 LP/怪兽目标。
- 新快照/终局：所有高亮和动态按钮立即清除。

- [x] **Step 5: 实现 DuelBoard 表现与信号**

`render_snapshot()` 首先清理旧决策表现，再按新字段调用：

```gdscript
func _render_rule_decision(snapshot: Dictionary) -> void:
	var kind := str(snapshot.get("decision_kind", "none"))
	if kind == "yes_no" and int(snapshot.get("decision_description", 0)) == 31:
		_show_attack_route_choice()
	elif kind == "select_card":
		_show_card_options(snapshot)
	elif kind == "yes_no":
		_open_yes_no_prompt()
```

对手怪兽的选择信号始终连接到一个路由方法；该方法只在当前表现状态允许时发出预选
或候选语义。候选位置映射同时比较 controller/location/sequence。点击 LP 的输入面
必须是实际原生 Control，而不是通过全局鼠标坐标猜测。

- [x] **Step 6: 运行两个 Godot 契约确认绿灯**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO \
  --script res://tests/ui/test_native_scene_contract.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO \
  --script res://tests/ui/test_contextual_duel_layout.gd
```

Expected: 两项均输出中文通过信息并退出 0。

- [x] **Step 7: 使用 Godot MCP 检查场景**

通过 MCP：

1. 读取 `duel_board.tscn` 与 `zone_view.tscn` 场景树。
2. 确认高亮固定节点、Theme 变体、锚点和鼠标策略。
3. 运行测试快照，触发 LP 与怪兽点击并读取信号计数。
4. 停止实例，清理 MCP 注入。

- [x] **Step 8: 提交原生目标 UI**

```bash
git add src/ui/themes/duel_theme.tres \
  src/ui/zone_view.tscn src/ui/zone_view.gd \
  src/duel/duel_board.tscn src/duel/duel_board.gd \
  tests/ui/test_native_scene_contract.gd \
  tests/ui/test_contextual_duel_layout.gd
git commit -m "feat(界面): 增加攻击目标情境交互" \
  -m "用原生 LP 与卡位高亮呈现直击、怪兽预选和 OCGCore 合法目标，不在前端推断规则。" \
  -m "验证：Godot 场景与情境交互契约、Godot MCP 检查通过。"
```

---

### Task 5: 编排快捷预选和真实 Bridge 提交

**Files:**
- Modify: `src/main/main.gd`
- Modify: `src/duel/duel_board.gd`
- Modify: `tests/ui/test_contextual_duel_layout.gd`
- Create: `tests/ui/test_attack_target_flow.gd`

**Interfaces:**
- Consumes: Task 3 Bridge 方法与 Task 4 DuelBoard signals。
- Produces: `Main` 的一次性 `_pending_attack_target_preview` 规则位置。
- Produces: 完整 YesNo→SelectCard→规则快照状态机。

- [x] **Step 1: 写 FakeBridge 端到端红灯测试**

`test_attack_target_flow.gd` 使用可注入 FakeBridge 和入树 `Main`/`DuelBoard`，
记录方法调用并返回后续 pending。测试以下序列：

```text
攻击动作 → YesNo(31)
点击 LP → submit_yes_no(true) → 新快照
```

以及：

```text
攻击动作 → YesNo(31)
点击怪兽 sequence=2 → submit_yes_no(false)
SelectCard 含 sequence=2 → submit_card_selection(option.index)
```

断言合法预选只自动提交一次；不合法预选不会提交 index，而是保留真实候选高亮。

- [x] **Step 2: 运行端到端测试确认红灯**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO \
  --script res://tests/ui/test_attack_target_flow.gd
```

Expected: Main 尚未连接目标信号或 Bridge 方法。

- [x] **Step 3: 实现 Main 编排**

连接 Task 4 的五类信号。规则为：

- LP：调用 `submit_yes_no(true)`。
- 预选怪兽：保存 `{controller,location,sequence}`，调用 `submit_yes_no(false)`。
- 新 pending 为 `select_card` 时，刷新场景后查找精确候选；匹配则清空预选并调用
  `submit_card_selection(index)`，不匹配则只清空预选。
- 合法候选点击：调用 `submit_card_selection(index)`。
- 取消：调用 `cancel_card_selection()`。
- 通用 YesNo：调用 `submit_yes_no(accepted)`。

每个失败响应都保留当前 Bridge 快照并调用 `board.show_status()`；成功后只通过
`_refresh_board()` 更新 LP/场面。重新开局、终局、非攻击 YesNo 和显式取消都清除
预选。

- [x] **Step 4: 覆盖过期、重复和失败路径**

FakeBridge 测试必须证明：

- 快照变化后旧 option index 不会再次提交。
- 双击 LP 期间只允许一次未决提交。
- Bridge 返回 `ok=false` 后解除本地提交锁但不清除合法目标。
- 终局快照清空预选和高亮。

- [x] **Step 5: 运行全部 Godot 契约**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO \
  --script res://tests/ui/test_native_scene_contract.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO \
  --script res://tests/ui/test_contextual_duel_layout.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO \
  --script res://tests/ui/test_attack_target_flow.gd
```

Expected: 三项全部通过。

- [x] **Step 6: 提交完整编排**

```bash
git add src/main/main.gd src/duel/duel_board.gd \
  tests/ui/test_contextual_duel_layout.gd \
  tests/ui/test_attack_target_flow.gd
git commit -m "feat(战斗): 编排真实攻击目标流程" \
  -m "连接直击、怪兽预选、合法候选和取消信号，所有状态变化均等待 OCGCore 快照。" \
  -m "验证：攻击目标端到端及全部 Godot UI 契约通过。"
```

---

### Task 6: 真实流程、多分辨率与最终验收

**Files:**
- Modify: `tests/ui/test_responsive_duel_layout.gd`
- Modify: `docs/superpowers/plans/2026-07-29-ocgcore-attack-target-interaction.md`

**Interfaces:**
- Consumes: 完整攻击流程。
- Produces: 自动化、MCP 与清洁工作区的完成证据。

- [x] **Step 1: 扩展响应式满载测试**

在现有 `1920×1080` 逻辑画布 + `canvas_items` Stretch 测试中分别渲染：

- 直击 LP 高亮 + 怪兽预览。
- 五个合法目标高亮。
- 通用 YesNo 确认层。
- 可取消目标选择。

对 `1920×1080`、`3840×2160` 和 `1920×1200` 检查 LP 点击面、阶段球、动作条、
确认层、手牌与系统按钮矩形均位于安全区域且不重叠。

- [x] **Step 2: 运行完整自动化**

Run:

```bash
./scripts/build_native.sh
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO --script res://tests/ui/test_native_scene_contract.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO --script res://tests/ui/test_contextual_duel_layout.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO --script res://tests/ui/test_attack_target_flow.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO --script res://tests/ui/test_responsive_duel_layout.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO --quit-after 3
git diff --check
```

Expected: CTest 全部通过；四项 Godot 测试输出中文通过信息；启动无项目错误；
`git diff --check` 无输出。

- [x] **Step 3: 使用 Godot MCP 验收真实运行**

必须在真实项目完成：

1. 原生全屏启动并读取 `DisplayServer.window_get_size()`。
2. 召唤怪兽、进入战斗阶段并点击“攻击”。
3. 走一次点击 LP 的真实直接攻击，确认 LP 只在 Bridge 新快照后减少。
4. 通过可复现牌局或测试入口走一次怪兽预选→SelectCard；确认合法自动提交或非法
   回退到真实候选。
5. 验证取消、重复点击、非法点击没有推进规则。
6. 检查 1080p、宿主高分辨率和 16:10 的关键矩形与 Theme。
7. 停止项目，删除 `mcp_interaction_server.gd`，移除临时 Autoload。

宿主不能创建物理 4K 窗口时，记录实际限制，同时以 headless 3840×2160 契约作为
精确 Stretch 证据；不得把黑帧截图描述成成功截图。

- [x] **Step 4: 最终独立代码审查**

审查范围从计划基线提交到当前 HEAD，逐项验证：

- 协议长度与索引响应格式。
- Session 快照门禁和 Retry。
- 里侧信息隐藏。
- Main 预选只提交一次。
- Godot 无规则推测、无提前场面更新。
- 原生固定节点和 Theme。
- MCP 无残留。

Critical/Important 必须修复并重新跑相应测试。

- [x] **Step 5: 更新计划完成勾选并提交验收**

```bash
git add tests/ui/test_responsive_duel_layout.gd \
  docs/superpowers/plans/2026-07-29-ocgcore-attack-target-interaction.md
git commit -m "test(战斗): 验收攻击目标完整流程" \
  -m "覆盖真实 Stretch 满载布局、直击、怪兽目标、取消和非法输入，并记录 Godot MCP 运行证据。" \
  -m "验证：原生 CTest、四项 Godot 契约、无界面启动和差异检查全部通过。"
```

- [ ] **Step 6: 推送 main 并确认同步**

```bash
git push origin main
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
git status --short
```

Expected: push 成功，HEAD 与 `origin/main` 相同，工作区无输出。
