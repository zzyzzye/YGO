extends Control

const DUEL_SEED = 0x59474f
const STARTING_DECK_SIZE = 40
const STATUS_END = 0
const STATUS_AWAITING = 1
const STATUS_CONTINUE = 2

@onready var status: Label = %Status
@onready var godot_status: Label = %GodotStatus
@onready var core_status: Label = %CoreStatus
@onready var card_status: Label = %CardStatus
@onready var cache_status: Label = %CacheStatus
@onready var test_card_status: Label = %TestCardStatus
@onready var lua_status: Label = %LuaStatus
@onready var duel_state: Label = %DuelState
@onready var player1_state: Label = %Player1State
@onready var player2_state: Label = %Player2State
@onready var step_status: Label = %StepStatus
@onready var step_button: Button = %StepButton
@onready var restart_button: Button = %RestartButton
@onready var action_label: Label = %ActionLabel
@onready var summon_button: Button = %SummonButton
@onready var set_button: Button = %SetButton
@onready var activate_button: Button = %ActivateButton
@onready var end_turn_button: Button = %EndTurnButton

var bridge: Object
var _current_status: int = STATUS_END


func _status_text_of_process(code: int) -> String:
	# 0=END, 1=AWAITING, 2=CONTINUE，和 OCGCore 的处理阶段语义一致。
	if code == 0:
		return "对局结束"
	if code == 1:
		return "等待输入"
	if code == 2:
		return "继续推进"
	return "未知状态(%d)" % code


func _status_hint_of_process(code: int) -> String:
	# WAITING 时先给出“动作入口未接入”的清晰提示。
	if code == STATUS_END:
		return "对局已结束，点击“重新开局”重新开始。"
	if code == STATUS_AWAITING:
		return "当前到达玩家决策点。你可以先点“结束回合”继续推进，或尝试其他动作（暂未接入）。"
	if code == STATUS_CONTINUE:
		return "引擎在继续自动推进，点“推进一步”可观察下一次状态切换。"
	return "当前状态异常，建议重新开局后重试。"


func _set_action_button_enabled(can_act: bool) -> void:
	# 当前阶段先保留动作控件，仅在将来接入动作系统时再放开。
	summon_button.disabled = !can_act
	set_button.disabled = !can_act
	activate_button.disabled = !can_act
	end_turn_button.disabled = !can_act


func _show_unsupported_action(action_name: String) -> void:
	# 统一提示动作未接入，避免玩家误以为点击无效无反馈。
	step_status.text = "暂不支持动作“%s”（当前版本仅支持单步推进）。" % action_name


func _on_action_button_pressed(action_name: String) -> void:
	# 这里保留动作入口，实现动作后应改为下发玩家选择给 OCGCore。
	_show_unsupported_action(action_name)


func _build_deck_ids(source_ids: PackedInt64Array, deck_size: int, duel_seed: int) -> PackedInt64Array:
	# 用确定性随机数洗牌，保证每次用同一输入时起手牌一致，可复测。
	var ids: Array = []
	ids.resize(source_ids.size())
	for i in source_ids.size():
		ids[i] = source_ids[i]
	var rng = RandomNumberGenerator.new()
	rng.seed = duel_seed
	for i in range(ids.size() - 1, 0, -1):
		var j = rng.randi_range(0, i)
		var temp = ids[i]
		ids[i] = ids[j]
		ids[j] = temp
	var deck = PackedInt64Array()
	for i in range(deck_size):
		deck.append(ids[i])
	return deck


func _state_text(state: Dictionary) -> String:
	return "卡组：%s，手牌：%s，怪区：%s，魔陷：%s，墓地：%s，除外：%s" % [
		state.deck,
		state.hand,
		state.monster_zone,
		state.spell_trap_zone,
		state.graveyard,
		state.banished,
	]


func _refresh_duel_view(process_text: String, process_code: int) -> void:
	var state_data: Dictionary = bridge.call("get_duel_state")
	_current_status = process_code
	if !state_data.ok:
		step_status.text = "当前无活动对局：" + state_data.message
		_set_action_button_enabled(false)
		return
	duel_state.text = "决斗状态：%s（代码 %s）" % [process_text, process_code]
	player1_state.text = "玩家1 -> " + _state_text(state_data.players.p1)
	player2_state.text = "玩家2 -> " + _state_text(state_data.players.p2)
	var pending: Dictionary = bridge.call("get_pending_action")
	step_status.text = pending.message if pending.kind != "none" else _status_hint_of_process(process_code)
	var can_end_turn: bool = pending.kind == "idle" and pending.can_end_turn
	# 存在待决策时禁止无响应推进，避免 OCGCore 把默认返回缓冲区解释成动作。
	step_button.disabled = pending.kind != "none"
	_set_action_button_enabled(can_end_turn)
	if can_end_turn:
		action_label.text = "玩家%s 决策：当前仅“结束回合”接入内核。" % [pending.player + 1]
	else:
		action_label.text = "动作入口（当前仅演示）："


func _start_duel_with_seed(duel_seed: int) -> void:
	var scripted_ids: PackedInt64Array = bridge.call("get_scripted_card_ids")
	if scripted_ids.size() < STARTING_DECK_SIZE:
		step_status.text = "可用脚本卡不足，无法建局"
		return

	var deck1: PackedInt64Array = _build_deck_ids(scripted_ids, STARTING_DECK_SIZE, duel_seed)
	var deck2: PackedInt64Array = _build_deck_ids(scripted_ids, STARTING_DECK_SIZE, duel_seed ^ 0x123456)

	var setup: Dictionary = bridge.call("setup_duel", deck1, deck2, duel_seed)
	if !setup.ok:
		step_status.text = "建局失败：" + setup.message
		return
	_set_action_button_enabled(false)
	_refresh_duel_view(_status_text_of_process(setup.status), setup.status)
	step_status.text = "建局完成，玩家1写入 %s 张，玩家2写入 %s 张" % [setup.player1_added, setup.player2_added]


func _ready() -> void:
	assert(ClassDB.class_exists("YgoCoreBridge"))
	bridge = ClassDB.instantiate("YgoCoreBridge")

	step_button.pressed.connect(_on_step_pressed)
	restart_button.pressed.connect(_on_restart_pressed)
	summon_button.pressed.connect(_on_summon_pressed)
	set_button.pressed.connect(_on_set_pressed)
	activate_button.pressed.connect(_on_activate_pressed)
	end_turn_button.pressed.connect(_on_end_turn_pressed)

	# 只在 C++ 统一初始化路径后读取数据库，避免界面层写死任何机器路径。
	var initialized: Dictionary = bridge.call(
		"initialize_card_database",
		ProjectSettings.globalize_path("res://")
	)
	assert(initialized.ok)

	# 启动期断言：卡库是否已成功加载、青眼白龙中文名是否正确、启动是否可被回退。
	assert(bridge.call("get_card_count") == 14110)
	var blue_eyes: Dictionary = bridge.call("get_card", 89631139)
	assert(blue_eyes.ok)
	assert(blue_eyes.cn_name == "青眼白龙")

	var version: Dictionary = bridge.call("get_core_version")

	status.text = "卡片数据库与规则脚本已就绪"
	godot_status.text = "Godot：%s" % Engine.get_version_info().string
	core_status.text = "OCGCore：%s.%s" % [version.major, version.minor]
	card_status.text = "正式卡片：%s" % initialized.card_count
	cache_status.text = "缓存：%s" % initialized.cache_state
	test_card_status.text = "测试卡片：%s（%s）" % [blue_eyes.cn_name, blue_eyes.id]
	lua_status.text = "Lua 规则：已连接"
	_set_action_button_enabled(false)

	_start_duel_with_seed(DUEL_SEED)


func _on_summon_pressed() -> void:
	_on_action_button_pressed("召唤")


func _on_set_pressed() -> void:
	_on_action_button_pressed("设定")


func _on_activate_pressed() -> void:
	_on_action_button_pressed("发动")


func _on_end_turn_pressed() -> void:
	var response: Dictionary = bridge.call("submit_end_turn")
	if !response.ok:
		step_status.text = "结束回合失败：" + response.message
		return
	_refresh_duel_view(_status_text_of_process(response.status), response.status)


func _on_step_pressed() -> void:
	var step_data: Dictionary = bridge.call("start_duel")
	if !step_data.ok:
		step_status.text = "推进失败：" + step_data.message
		return
	_refresh_duel_view(_status_text_of_process(step_data.status), step_data.status)


func _on_restart_pressed() -> void:
	# 用当前时间做重开局种子，快速观察不同洗牌效果。
	var new_seed: int = int(Time.get_unix_time_from_system()) & 0x7fffffff
	if new_seed <= 0:
		new_seed = DUEL_SEED
	_set_action_button_enabled(false)
	action_label.text = "动作入口（当前仅演示）："
	_start_duel_with_seed(new_seed)


func _exit_tree() -> void:
	if bridge != null and bridge.call("is_duel_active"):
		bridge.call("destroy_duel")
