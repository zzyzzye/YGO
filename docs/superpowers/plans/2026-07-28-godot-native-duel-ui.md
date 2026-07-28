# Godot 原生决斗界面迁移实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将当前由 GDScript 动态拼装的黑白决斗界面迁移为可在 Godot 编辑器中直接编辑、可复用、可动画并适配 1080p 与 4K 的原生场景和主题，同时保持真实 OCGCore 流程与现有交互行为不变。

**Architecture:** C++/GDExtension 继续独占规则、数据和候选动作；`Main` 继续把 Bridge 状态转换为快照；`DuelBoard`、`HandView`、`ZoneView` 和 `CardView` 改为 `.tscn`，共享视觉改为 `.tres` Theme。固定节点由场景声明，脚本只缓存唯一节点、实例化数据驱动子场景、绑定快照和转发信号。

**Tech Stack:** Godot 4.6.3、GDScript、Godot `.tscn`/`.tres`、AnimationPlayer、C++20 GDExtension、OCGCore 11.0、Godot MCP、CTest。

## Global Constraints

- 项目文件只能保存在 `/Volumes/WD/YGO`；不得在仓库外创建项目副本或长期文件。
- 项目自有代码注释、日志、测试诊断和用户可见文本必须使用简体中文。
- 固定界面结构必须来自 `.tscn`；动态节点必须优先实例化预制 PackedScene。
- OCGCore、规则校验、响应编码、生命值和胜负仍由 C++ 层独占，Godot 不得伪造结果。
- 共享视觉值必须进入 `.tres` Theme/StyleBox；不得继续散落在多个脚本中。
- 响应式布局必须同时覆盖 1920×1080、3840×2160 和至少一种非 16:9 尺寸。
- 每个场景任务必须先运行失败测试，再实现最小修改，并使用 Godot MCP 读取或运行真实场景。
- MCP 验收结束后必须清理 `project.godot` 中的临时 Autoload 和 `mcp_interaction_server.gd`。
- 每个 Git 提交使用中文 Conventional Commits，并在正文写明原因、改动和验证命令。

---

## 文件结构

### 新建

- `src/ui/themes/duel_theme.tres`：决斗界面共享字体、颜色、间距、按钮、区域和浮层样式。
- `src/ui/card_view.tscn`：卡牌按钮、卡背标签、选择边框和 AnimationPlayer。
- `src/ui/zone_view.tscn`：区域容器、卡片挂点、标题、目标高亮和 AnimationPlayer。
- `src/ui/hand_view.tscn`：数据驱动手牌容器。
- `src/duel/duel_board.tscn`：完整固定决斗场景树。
- `tests/ui/test_native_scene_contract.gd`：原生场景资源、唯一节点、主题和信号契约。
- `tests/ui/test_responsive_duel_layout.gd`：1080p、4K 和 16:10 的真实节点矩形契约。

### 修改

- `src/ui/card_view.gd`：删除固定绘制职责，缓存场景节点并驱动 AnimationPlayer。
- `src/ui/zone_view.gd`：删除固定子节点创建，实例化 `card_view.tscn`。
- `src/ui/hand_view.gd`：实例化 `card_view.tscn`。
- `src/duel/duel_board.gd`：删除 `_build_interface()` 和固定节点工厂，缓存原生场景节点。
- `src/main/main.tscn`：实例化 `duel_board.tscn`。
- `src/main/main.gd`：通过 `%DuelBoard` 使用场景节点，不再 `DUEL_BOARD_SCRIPT.new()`。
- `tests/ui/test_contextual_duel_layout.gd`：从 PackedScene 实例化真实 UI，保留现有交互和 Bridge 断言。

---

### Task 1: 建立 CardView 原生场景与共享主题

**Files:**
- Create: `src/ui/themes/duel_theme.tres`
- Create: `src/ui/card_view.tscn`
- Create: `tests/ui/test_native_scene_contract.gd`
- Modify: `src/ui/card_view.gd`

**Interfaces:**
- Consumes: `CardView.configure(data: Dictionary, show_back := false)`、`set_selected(value: bool)`。
- Produces: `CARD_VIEW_SCENE = preload("res://src/ui/card_view.tscn")` 可供 HandView 和 ZoneView 实例化；保留 `card_selected`、`card_hovered`、`card_unhovered` 信号。

- [ ] **Step 1: 写入 CardView 失败契约**

在 `tests/ui/test_native_scene_contract.gd` 中创建 SceneTree 测试，先验证资源存在，再验证节点和动画：

```gdscript
extends SceneTree

const CARD_SCENE_PATH := "res://src/ui/card_view.tscn"
const THEME_PATH := "res://src/ui/themes/duel_theme.tres"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if !ResourceLoader.exists(THEME_PATH):
		_fail("缺少决斗界面 Theme 资源")
		return
	if !ResourceLoader.exists(CARD_SCENE_PATH):
		_fail("缺少 CardView 原生场景")
		return
	var card = load(CARD_SCENE_PATH).instantiate()
	root.add_child(card)
	await process_frame
	for node_name in ["SelectionFrame", "FaceDownLabel", "AnimationPlayer"]:
		if card.find_child(node_name, true, false) == null:
			_fail("CardView 缺少固定节点：" + node_name)
			return
	var animator: AnimationPlayer = card.find_child("AnimationPlayer", true, false)
	for animation_name in ["hover_in", "hover_out", "select", "reset"]:
		if !animator.has_animation(animation_name):
			_fail("CardView 缺少动画：" + animation_name)
			return
	card.queue_free()
	await process_frame
	print("Godot 原生场景契约通过")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
```

- [ ] **Step 2: 运行测试并确认因资源缺失而失败**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path /Volumes/WD/YGO \
  --script res://tests/ui/test_native_scene_contract.gd
```

Expected: exit code 1，中文错误为“缺少决斗界面 Theme 资源”。

- [ ] **Step 3: 用 Godot MCP 创建 Theme 和 CardView 场景**

使用 Godot MCP 在 `/Volumes/WD/YGO` 中执行：

1. 创建 `src/ui/themes` 目录。
2. 创建 `src/ui/themes/duel_theme.tres`，资源类型为 `Theme`。
3. 创建 `src/ui/card_view.tscn`，根节点为 `TextureButton`，名称为 `CardView`。
4. 添加 `SelectionFrame: Panel`、`FaceDownLabel: Label` 和
   `AnimationPlayer: AnimationPlayer`。
5. 将 `src/ui/card_view.gd` 挂到根节点。
6. 通过 MCP 读取场景，确认三个固定节点存在后保存。

Theme 至少提供以下类型变化名称，供后续场景复用：

```text
CardSelection
ZonePanel
TargetHighlight
OverlayPanel
PhaseButton
SystemButton
```

- [ ] **Step 4: 将 CardView 脚本改为缓存原生节点**

删除 `_draw()` 中的完整卡背、占位和边框绘制。保留外部卡图加载，并加入：

```gdscript
@onready var selection_frame: Panel = %SelectionFrame
@onready var face_down_label: Label = %FaceDownLabel
@onready var animator: AnimationPlayer = %AnimationPlayer

func configure(data: Dictionary, show_back := false) -> void:
	card_data = data
	face_down = show_back
	texture_normal = null
	face_down_label.visible = show_back
	tooltip_text = "对手手牌" if show_back else str(
		data.get("cn_name", data.get("card_id", "未知卡片"))
	)
	if !show_back:
		texture_normal = _load_external_texture(str(data.get("image_path", "")))

func set_selected(value: bool) -> void:
	selected = value
	selection_frame.visible = value
	animator.play("select" if value else "reset")
```

`_on_mouse_entered()` 和 `_on_mouse_exited()` 在发信号前分别播放 `hover_in` 和
`hover_out`；卡背不发出可选信号。

- [ ] **Step 5: 运行场景契约并确认通过**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path /Volumes/WD/YGO \
  --script res://tests/ui/test_native_scene_contract.gd
```

Expected: 输出“Godot 原生场景契约通过”，exit code 0。

- [ ] **Step 6: 用 Godot MCP 验证 Theme 继承和动画**

启动 `card_view.tscn`，读取 `SelectionFrame.visible`；调用
`set_selected(true)` 后等待两个渲染帧，再读取该属性和 AnimationPlayer 当前动画。
Expected: `visible=true`，当前动画为 `select`。随后调用 `set_selected(false)`，
Expected: `visible=false`。

- [ ] **Step 7: 提交 Task 1**

```bash
git add src/ui/themes/duel_theme.tres src/ui/card_view.tscn \
  src/ui/card_view.gd tests/ui/test_native_scene_contract.gd
git diff --cached --check
git commit -m "feat(界面): 原生化卡牌场景与主题"
```

提交正文写明失败测试、MCP 场景树和动画属性验证结果。

---

### Task 2: 原生化 ZoneView 与 HandView

**Files:**
- Create: `src/ui/zone_view.tscn`
- Create: `src/ui/hand_view.tscn`
- Modify: `src/ui/zone_view.gd`
- Modify: `src/ui/hand_view.gd`
- Modify: `tests/ui/test_native_scene_contract.gd`

**Interfaces:**
- Consumes: `CARD_VIEW_SCENE.instantiate()`。
- Produces: `ZoneView.configure()`、`show_card()`、`clear_card()`；
  `HandView.render_cards()`、`clear_selection()`；保留现有三种卡牌信号。

- [ ] **Step 1: 扩展失败契约**

在资源加载前加入：

```gdscript
const ZONE_SCENE_PATH := "res://src/ui/zone_view.tscn"
const HAND_SCENE_PATH := "res://src/ui/hand_view.tscn"
```

在 CardView 断言之后加入：

```gdscript
for scene_path in [ZONE_SCENE_PATH, HAND_SCENE_PATH]:
	if !ResourceLoader.exists(scene_path):
		_fail("缺少原生子场景：" + scene_path)
		return
var zone = load(ZONE_SCENE_PATH).instantiate()
root.add_child(zone)
await process_frame
for node_name in ["CardContainer", "TitleLabel", "TargetHighlight", "AnimationPlayer"]:
	if zone.find_child(node_name, true, false) == null:
		_fail("ZoneView 缺少固定节点：" + node_name)
		return
var hand = load(HAND_SCENE_PATH).instantiate()
root.add_child(hand)
await process_frame
hand.render_cards([{"card_id": 89631139, "sequence": 0}], false)
await process_frame
if hand.get_child_count() != 1 or hand.get_child(0).scene_file_path != CARD_SCENE_PATH:
	_fail("HandView 必须实例化 CardView PackedScene")
	return
zone.show_card({"card_id": 89631139, "sequence": 0}, false)
await process_frame
var card_container = zone.find_child("CardContainer", true, false)
if card_container.get_child_count() != 1:
	_fail("ZoneView 必须把 CardView 实例放入 CardContainer")
	return
```

- [ ] **Step 2: 运行测试并确认因 ZoneView 场景缺失而失败**

Run the native scene contract command from Task 1.

Expected: exit code 1，错误包含
`缺少原生子场景：res://src/ui/zone_view.tscn`。

- [ ] **Step 3: 用 Godot MCP 创建两个原生子场景**

创建并保存：

```text
ZoneView: PanelContainer
└── Stack: VBoxContainer
    ├── CardContainer: CenterContainer
    ├── TitleLabel: Label
    ├── TargetHighlight: Panel
    └── AnimationPlayer

HandView: HBoxContainer
```

`CardContainer`、`TitleLabel`、`TargetHighlight` 和 `AnimationPlayer` 设为唯一名称。
`TargetHighlight.visible=false`，鼠标过滤为 Ignore。将对应脚本挂到根节点，并通过
MCP 读取场景树确认结构。

- [ ] **Step 4: 改为实例化 CardView PackedScene**

两个脚本都定义：

```gdscript
const CARD_VIEW_SCENE := preload("res://src/ui/card_view.tscn")
```

`ZoneView.show_card()` 使用：

```gdscript
var card = CARD_VIEW_SCENE.instantiate()
card_container.add_child(card)
card.custom_minimum_size = Vector2(72, 105)
card.configure(card_data, show_back)
```

`HandView.render_cards()` 使用同样的 `instantiate()`，不再比较脚本资源；选中清理使用：

```gdscript
for child in get_children():
	if child is CardView:
		child.set_selected(false)
```

`ZoneView._ready()` 只连接或缓存场景节点，不创建 StyleBox、VBox、Label 或容器。

- [ ] **Step 5: 运行场景契约和现有 UI 契约**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO --script res://tests/ui/test_native_scene_contract.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO --script res://tests/ui/test_contextual_duel_layout.gd
```

Expected: 两条命令均 exit code 0。

- [ ] **Step 6: 用 Godot MCP 验证动态实例来源**

启动 `hand_view.tscn`，调用 `render_cards()` 写入两张测试卡；读取运行时子树。
Expected: 两个子节点均带 `res://src/ui/card_view.tscn` 场景来源。调用
`clear_selection()` 后 SelectionFrame 均不可见。

- [ ] **Step 7: 提交 Task 2**

```bash
git add src/ui/zone_view.tscn src/ui/hand_view.tscn \
  src/ui/zone_view.gd src/ui/hand_view.gd \
  tests/ui/test_native_scene_contract.gd
git diff --cached --check
git commit -m "refactor(界面): 原生化手牌与卡位子场景"
```

---

### Task 3: 建立 DuelBoard 固定原生场景树

**Files:**
- Create: `src/duel/duel_board.tscn`
- Modify: `src/duel/duel_board.gd`
- Modify: `tests/ui/test_native_scene_contract.gd`
- Modify: `tests/ui/test_contextual_duel_layout.gd`

**Interfaces:**
- Consumes: `hand_view.tscn`、`zone_view.tscn`、`duel_theme.tres`。
- Produces: 保持 `DuelBoard.render_snapshot()`、`show_status()`、七个现有请求信号及测试访问的节点属性。

- [ ] **Step 1: 写入 DuelBoard 失败契约**

加入：

```gdscript
const BOARD_SCENE_PATH := "res://src/duel/duel_board.tscn"
```

测试：

```gdscript
if !ResourceLoader.exists(BOARD_SCENE_PATH):
	_fail("缺少 DuelBoard 原生场景")
	return
var board = load(BOARD_SCENE_PATH).instantiate()
root.add_child(board)
await process_frame
for node_name in [
	"Background", "SafeArea", "Battlefield", "OpponentHand",
	"OpponentSpellRow", "OpponentMonsterRow", "TurnLabel",
	"PlayerMonsterRow", "PlayerSpellRow", "PlayerHand",
	"OpponentStatus", "PlayerStatus", "PhaseButton", "SystemTools",
	"StatusToast", "CardDetailOverlay", "ContextActionBar",
	"ConfirmationOverlay", "DebugOverlay", "AnimationPlayer",
]:
	if board.find_child(node_name, true, false) == null:
		_fail("DuelBoard 缺少固定节点：" + node_name)
		return
if board.has_method("_build_interface"):
	_fail("DuelBoard 不得继续用脚本动态拼装固定界面")
	return
```

- [ ] **Step 2: 运行测试并确认缺少 DuelBoard 场景**

Run the native scene contract command.

Expected: exit code 1，错误为“缺少 DuelBoard 原生场景”。

- [ ] **Step 3: 用 Godot MCP 创建 DuelBoard 场景骨架**

按规格文档的固定场景树创建节点。关键布局值：

```text
DuelBoard anchors: full rect
SafeArea anchors: full rect
SafeArea offsets: left 24, top 18, right -24, bottom -18
Battlefield anchors: left 0.18, right 0.82, top 0, bottom 1
CardDetailOverlay anchors: left 0.015, top 0.14, right 0.245, bottom 0.82
ContextActionBar anchors: left 0.33, top 0.64, right 0.67, bottom 0.69
PhaseButton anchors: left 0.84, top 0.43, right 0.935, bottom 0.57
SystemTools anchors: left 0.84, top 0.92, right 0.985, bottom 0.985
```

四个区域行各实例化五个 `zone_view.tscn`。两个手牌节点实例化
`hand_view.tscn`。为脚本直接访问的节点设置唯一名称。场景根应用
`duel_theme.tres`。

通过 MCP `read_scene` 检查所有固定节点和 20 个 ZoneView 实例，再保存场景。

- [ ] **Step 4: 重构 DuelBoard 脚本为节点绑定**

删除以下函数及相关脚本内 StyleBox 工厂：

```text
_build_interface
_build_battlefield
_add_zone_row
_build_player_status
_make_corner_status
_build_card_detail_overlay
_build_context_action_bar
_build_phase_control
_build_system_tools
_make_tool_button
_build_status_toast
_build_confirmation_overlay
_build_debug_overlay
_panel_style
_round_button_style
```

用唯一节点缓存替代：

```gdscript
@onready var player_hand: HandView = %PlayerHand
@onready var opponent_hand: HandView = %OpponentHand
@onready var detail_overlay: PanelContainer = %CardDetailOverlay
@onready var detail_image: TextureRect = %DetailImage
@onready var detail_name: Label = %DetailName
@onready var detail_type: Label = %DetailType
@onready var detail_text: Label = %DetailText
@onready var action_box: HBoxContainer = %ContextActionBar
@onready var status_label: Label = %StatusToast
@onready var turn_label: Label = %TurnLabel
@onready var phase_button: Button = %PhaseButton
@onready var debug_overlay: Label = %DebugOverlay
@onready var player_stats_label: Label = %PlayerStatus
@onready var opponent_stats_label: Label = %OpponentStatus
@onready var confirmation_overlay: PanelContainer = %ConfirmationOverlay
@onready var confirmation_label: Label = %ConfirmationLabel
@onready var confirmation_buttons: HBoxContainer = %ConfirmationButtons
```

在 `_ready()` 中以明确数组绑定区域：

```gdscript
player_monster_zones = %PlayerMonsterRow.get_children()
player_spell_zones = %PlayerSpellRow.get_children()
opponent_monster_zones = %OpponentMonsterRow.get_children()
opponent_spell_zones = %OpponentSpellRow.get_children()
assert(player_monster_zones.size() == 5, "玩家怪兽区必须有五个原生卡位")
```

连接玩家手牌、玩家场上卡和固定按钮信号。对手卡位暂时只转发悬浮，不允许提交动作。
动态情境按钮和确认按钮仍按候选数量创建；按钮从 Theme 继承视觉。

- [ ] **Step 5: 修改现有契约以加载真实场景**

将：

```gdscript
const DUEL_BOARD_SCRIPT = preload("res://src/duel/duel_board.gd")
var board = DUEL_BOARD_SCRIPT.new()
```

替换为：

```gdscript
const DUEL_BOARD_SCENE = preload("res://src/duel/duel_board.tscn")
var board = DUEL_BOARD_SCENE.instantiate()
```

HandView 同样改为加载 `hand_view.tscn`。保留现有动作精确匹配、悬浮、取消、阶段选项、
真实 Bridge 和终局门禁断言。

- [ ] **Step 6: 运行两个 UI 契约**

Run both Godot commands from Task 2.

Expected: 原生场景契约和情境式决斗界面交互契约均通过。

- [ ] **Step 7: 用 Godot MCP 读取并运行 DuelBoard**

1. MCP 读取 `duel_board.tscn`，确认所有固定节点存在。
2. 启动该场景。
3. 调用 `render_snapshot()` 注入一张手牌和一个通常召唤动作。
4. 点击该卡，确认 `ContextActionBar` 显示“通常召唤”和“取消”。
5. 点击空白，确认动作条和详情浮层隐藏。

- [ ] **Step 8: 提交 Task 3**

```bash
git add src/duel/duel_board.tscn src/duel/duel_board.gd \
  tests/ui/test_native_scene_contract.gd \
  tests/ui/test_contextual_duel_layout.gd
git diff --cached --check
git commit -m "refactor(界面): 迁移决斗场到原生场景"
```

---

### Task 4: 将 Main 场景与真实决斗接入原生 DuelBoard

**Files:**
- Modify: `src/main/main.tscn`
- Modify: `src/main/main.gd`
- Modify: `tests/ui/test_native_scene_contract.gd`
- Modify: `tests/ui/test_contextual_duel_layout.gd`

**Interfaces:**
- Consumes: `duel_board.tscn` 与既有 `YgoCoreBridge`。
- Produces: 主场景启动时使用场景内 `%DuelBoard`，保持所有真实决斗行为。

- [ ] **Step 1: 写入 Main 原生集成失败断言**

```gdscript
const MAIN_SCENE_PATH := "res://src/main/main.tscn"
var main = load(MAIN_SCENE_PATH).instantiate()
var board = main.find_child("DuelBoard", true, false)
if board == null or board.scene_file_path != BOARD_SCENE_PATH:
	_fail("Main 必须直接实例化 DuelBoard 原生场景")
	return
```

同时用文本检查或脚本资源源代码检查：

```gdscript
var main_source := FileAccess.get_file_as_string("res://src/main/main.gd")
if "DUEL_BOARD_SCRIPT.new()" in main_source:
	_fail("Main 不得继续在运行时创建 DuelBoard")
	return
```

- [ ] **Step 2: 运行测试并确认 Main 尚未实例化 DuelBoard**

Expected: exit code 1，错误为“Main 必须直接实例化 DuelBoard 原生场景”。

- [ ] **Step 3: 用 Godot MCP 把 DuelBoard 实例加入 Main**

修改 `src/main/main.tscn`：

```text
Main: Control
└── DuelBoard: instance(res://src/duel/duel_board.tscn)
```

设置 DuelBoard 为唯一名称和全屏布局。通过 MCP 读取 Main 场景确认实例来源。

- [ ] **Step 4: 修改 Main 脚本**

删除 `DUEL_BOARD_SCRIPT` 常量和 `_ready()` 中的 `new()/add_child()`：

```gdscript
@onready var board: DuelBoard = %DuelBoard

func _ready() -> void:
	assert(ClassDB.class_exists("YgoCoreBridge"))
	bridge = ClassDB.instantiate("YgoCoreBridge")
	_connect_board_signals()
	# 保留卡库初始化和真实建局流程。
```

新增 `_connect_board_signals()`，集中连接七个已有信号；测试注入 `board` 时仍允许直接
调用 `_refresh_board()`。

- [ ] **Step 5: 运行所有 Godot 自动化测试与无界面启动**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO --script res://tests/ui/test_native_scene_contract.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO --script res://tests/ui/test_contextual_duel_layout.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO --quit-after 3
```

Expected: 两个契约通过；启动命令无项目自有错误。

- [ ] **Step 6: 用 Godot MCP 验收真实主场景**

启动项目并确认：

1. `/root/Main/DuelBoard` 的 `scene_file_path` 为
   `res://src/duel/duel_board.tscn`。
2. 结束第一个回合后确定性对手自动结束，玩家1进入下一回合。
3. 点击一张具有通常召唤候选的手牌，情境按钮出现。
4. 点击“通常召唤”后场区由 Bridge 新快照更新。
5. 点击阶段按钮再点“取消”，确认没有调用 Bridge，阶段不变。

- [ ] **Step 7: 提交 Task 4**

```bash
git add src/main/main.tscn src/main/main.gd \
  tests/ui/test_native_scene_contract.gd \
  tests/ui/test_contextual_duel_layout.gd
git diff --cached --check
git commit -m "refactor(主场景): 接入原生决斗场实例"
```

---

### Task 5: 建立 1080p、4K 与 16:10 响应式布局契约

**Files:**
- Create: `tests/ui/test_responsive_duel_layout.gd`
- Modify: `src/duel/duel_board.tscn`
- Modify: `src/ui/themes/duel_theme.tres`

**Interfaces:**
- Consumes: `duel_board.tscn` 真实节点矩形。
- Produces: 三种尺寸下可重复验证的安全边距和不重叠保证。

- [ ] **Step 1: 写入多尺寸失败测试**

测试对每个尺寸重新实例化场景：

```gdscript
extends SceneTree

const BOARD_SCENE = preload("res://src/duel/duel_board.tscn")
const SIZES := [
	Vector2i(1920, 1080),
	Vector2i(3840, 2160),
	Vector2i(1920, 1200),
]

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	for viewport_size in SIZES:
		root.size = viewport_size
		var board = BOARD_SCENE.instantiate()
		root.add_child(board)
		await process_frame
		await process_frame
		_assert_layout(board, viewport_size)
		board.free()
	print("多分辨率决斗布局契约通过")
	quit(0)

func _assert_layout(board: Control, viewport_size: Vector2i) -> void:
	var viewport_rect := Rect2(Vector2.ZERO, Vector2(viewport_size))
	var action_bar: Control = board.find_child("ContextActionBar", true, false)
	var player_hand: Control = board.find_child("PlayerHand", true, false)
	var status: Control = board.find_child("StatusToast", true, false)
	var opponent_hand: Control = board.find_child("OpponentHand", true, false)
	var tools: Control = board.find_child("SystemTools", true, false)
	if action_bar.get_global_rect().intersects(player_hand.get_global_rect()):
		_fail("动作条覆盖玩家手牌：" + str(viewport_size))
	if status.get_global_rect().intersects(opponent_hand.get_global_rect()):
		_fail("状态提示覆盖对手手牌：" + str(viewport_size))
	if !viewport_rect.encloses(tools.get_global_rect()):
		_fail("系统工具离开安全视口：" + str(viewport_size))
	if board.player_monster_zones.size() != 5:
		_fail("玩家怪兽区数量错误：" + str(viewport_size))

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
```

- [ ] **Step 2: 运行测试并确认至少一个尺寸失败**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO --script res://tests/ui/test_responsive_duel_layout.gd
```

Expected: exit code 1，失败来自真实矩形重叠或视口越界，而不是脚本语法错误。

- [ ] **Step 3: 用容器和 Theme 修复布局**

只修改 `.tscn` 锚点、Container、Size Flags、最小尺寸和 Theme 常量。不得在
`duel_board.gd` 中加入按分辨率分支。优先调整：

- SafeArea 四边偏移。
- Battlefield 的左右锚点。
- HandView 和 ZoneView 的最小尺寸。
- ContextActionBar 的下边界。
- StatusToast 的最小宽度和位置。
- SystemTools 的右下安全边距。

- [ ] **Step 4: 运行响应式契约并确认三种尺寸通过**

Run the responsive contract command.

Expected: 输出“多分辨率决斗布局契约通过”。

- [ ] **Step 5: 用 Godot MCP 切换窗口尺寸检查真实属性**

分别设置运行窗口为 1920×1080、3840×2160、1920×1200。每种尺寸读取
Battlefield、PlayerHand、ContextActionBar、OpponentHand、StatusToast、
SystemTools 的位置和尺寸，确认与自动化矩形断言一致。保存每种尺寸的截图供当前
任务人工比对，但截图如为临时文件必须放系统临时目录并在任务结束后清理。

- [ ] **Step 6: 提交 Task 5**

```bash
git add src/duel/duel_board.tscn src/ui/themes/duel_theme.tres \
  tests/ui/test_responsive_duel_layout.gd
git diff --cached --check
git commit -m "feat(界面): 增加多分辨率原生布局"
```

---

### Task 6: 完整回归、Godot MCP 交互验收与清理

**Files:**
- Modify only if verification exposes a regression.
- Verify: all files from Tasks 1–5.

**Interfaces:**
- Consumes: 完整原生场景体系与真实 YgoCoreBridge。
- Produces: 可提交、可推送、无 MCP 污染的主分支状态。

- [ ] **Step 1: 运行完整原生构建和 CTest**

```bash
./scripts/build_native.sh
```

Expected: `8/8` CTest 通过，`ygo_core` 构建成功。

- [ ] **Step 2: 运行全部 Godot 契约**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO --script res://tests/ui/test_native_scene_contract.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO --script res://tests/ui/test_contextual_duel_layout.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO --script res://tests/ui/test_responsive_duel_layout.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Volumes/WD/YGO --quit-after 3
```

Expected: 三项契约通过；项目启动无自有错误。

- [ ] **Step 3: 用 Godot MCP 跑真实主路径**

1. 启动主项目。
2. 验证当前窗口为原生全屏。
3. 结束首回合，等待确定性对手自动结束。
4. 选择一张有通常召唤候选的手牌。
5. 点击“通常召唤”并确认怪兽出现在玩家怪兽区。
6. 进入战斗阶段，点击该怪兽，再点击“攻击”。
7. 确认对手 LP 从 8000 降低，且状态来自 Bridge 新快照。

- [ ] **Step 4: 用 Godot MCP 跑取消和非法路径**

1. 打开阶段选择后点击“取消”，确认面板隐藏且阶段不变。
2. 选中卡片后点击场地空白，确认详情和动作条关闭。
3. 在对局结束或 `local_player_turn=false` 快照下点击卡片，确认不出现动作按钮。

- [ ] **Step 5: 停止 MCP 并清理注入内容**

停止项目后执行：

```bash
git status --short
rg -n "McpInteractionServer|\\[autoload\\]" project.godot
test ! -e mcp_interaction_server.gd
git diff --check
git -C third_party/godot-cpp status --short
```

Expected:

- `project.godot` 不包含 MCP Autoload。
- `mcp_interaction_server.gd` 不存在。
- godot-cpp 子模块干净。
- `git diff --check` 无输出。

- [ ] **Step 6: 请求独立代码审查**

审查重点：

- 固定节点是否仍在脚本中动态创建。
- Theme 是否真正被场景继承。
- PackedScene 是否用于所有动态卡牌。
- 1080p/4K 断言是否检查真实矩形。
- Main 与 Bridge 数据流是否保持单向。
- MCP 临时文件是否清理。

修复所有 Critical 和 Important 后，重新执行 Steps 1–5。

- [ ] **Step 7: 提交验证中产生的必要修正**

若验证没有产生代码修正，不创建空提交。若有修正：

```bash
git add src/main/main.gd src/main/main.tscn \
  src/duel/duel_board.gd src/duel/duel_board.tscn \
  src/ui/card_view.gd src/ui/card_view.tscn \
  src/ui/zone_view.gd src/ui/zone_view.tscn \
  src/ui/hand_view.gd src/ui/hand_view.tscn \
  src/ui/themes/duel_theme.tres \
  tests/ui/test_native_scene_contract.gd \
  tests/ui/test_contextual_duel_layout.gd \
  tests/ui/test_responsive_duel_layout.gd
git diff --cached --check
git commit -m "fix(界面): 修正原生场景验收问题"
```

- [ ] **Step 8: 推送 main 并确认远端一致**

```bash
git push origin main
git status --short
git rev-parse HEAD
git rev-parse origin/main
```

Expected: 工作区干净，HEAD 与 `origin/main` 相同。

---

## 计划自审结果

- 规格覆盖：场景、主题、C++ 边界、响应式布局、动画挂点、自动化测试和 MCP 验收均有对应任务。
- 占位符检查：计划不包含未决标记、模糊的类比实现或未指定的错误处理。
- 类型一致性：CardView、ZoneView、HandView、DuelBoard 的类名、场景路径、信号和方法与当前代码及设计规格一致。
- 范围控制：本计划只完成原生场景迁移；真实攻击目标选择在迁移完成后使用独立设计与实施计划推进。
