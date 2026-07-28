class_name DuelBoard
extends Control

signal idle_action_requested(action_kind: String, index: int, card_data: Dictionary)
signal battle_action_requested(action_kind: String, index: int, card_data: Dictionary)
signal end_turn_requested
signal enter_battle_requested
signal enter_main2_requested
signal end_battle_requested
signal restart_requested
signal exit_requested

var player_monster_zones: Array = []
var player_spell_zones: Array = []
var opponent_monster_zones: Array = []
var opponent_spell_zones: Array = []
# 固定节点全部由 duel_board.tscn 持有。脚本只绑定语义节点并驱动状态，
# 避免运行时拼装导致 Theme 继承、Container 重排和输入命中规则不稳定。
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
@onready var restart_button: Button = %RestartButton
@onready var debug_button: Button = %DebugButton
@onready var exit_button: Button = %ExitButton
var selected_card: Dictionary = {}
var _hovered_card: Dictionary = {}
var current_actions: Array = []
var _confirmation_kind := ""
var _local_player_turn := false
var _can_end_turn := false
var _phase_kind := "idle"
var _can_enter_battle := false
var _can_enter_main2 := false
var _can_end_battle := false


func _ready() -> void:
	player_monster_zones = %PlayerMonsterRow.get_children()
	player_spell_zones = %PlayerSpellRow.get_children()
	opponent_monster_zones = %OpponentMonsterRow.get_children()
	opponent_spell_zones = %OpponentSpellRow.get_children()
	assert(player_monster_zones.size() == 5, "玩家怪兽区必须有五个原生卡位")
	assert(player_spell_zones.size() == 5, "玩家魔陷区必须有五个原生卡位")
	assert(opponent_monster_zones.size() == 5, "对手怪兽区必须有五个原生卡位")
	assert(opponent_spell_zones.size() == 5, "对手魔陷区必须有五个原生卡位")

	_configure_zone_row(player_monster_zones, "玩家怪兽", false)
	_configure_zone_row(player_spell_zones, "玩家魔陷", false)
	_configure_zone_row(opponent_monster_zones, "对手怪兽", true)
	_configure_zone_row(opponent_spell_zones, "对手魔陷", true)

	player_hand.card_selected.connect(_on_card_selected)
	player_hand.card_hovered.connect(_preview_card)
	player_hand.card_unhovered.connect(_on_card_unhovered)
	for zone in player_monster_zones + player_spell_zones:
		zone.card_selected.connect(_on_card_selected)
		zone.card_hovered.connect(_preview_card)
		zone.card_unhovered.connect(_on_card_unhovered)
	# 对手区域只允许预览。规则层不会为它们暴露可提交动作，界面也不连接选择信号，
	# 防止未来的卡片脚本变化绕过 OCGCore 候选动作门禁。
	for zone in opponent_monster_zones + opponent_spell_zones:
		zone.card_hovered.connect(_preview_card)
		zone.card_unhovered.connect(_on_card_unhovered)

	phase_button.pressed.connect(_on_phase_pressed)
	restart_button.pressed.connect(_request_restart)
	debug_button.pressed.connect(_toggle_debug)
	exit_button.pressed.connect(_request_exit)
	%Background.gui_input.connect(_on_background_input)


func _configure_zone_row(zones: Array, prefix: String, opponent: bool) -> void:
	for index in range(zones.size()):
		var display_index := 5 - index if opponent else index + 1
		zones[index].configure("%s %s" % [prefix, display_index])


func render_snapshot(snapshot: Dictionary) -> void:
	current_actions = snapshot.get("idle_actions", [])
	_local_player_turn = bool(snapshot.get("local_player_turn", false))
	_can_end_turn = bool(snapshot.get("can_end_turn", false))
	_phase_kind = str(snapshot.get("phase_kind", "idle"))
	_can_enter_battle = bool(snapshot.get("can_enter_battle", false))
	_can_enter_main2 = bool(snapshot.get("can_enter_main2", false))
	_can_end_battle = bool(snapshot.get("can_end_battle", false))
	# 阶段选项绑定的是上一份 OCGCore 决策快照。任何新快照到达后都必须
	# 立即失效，避免玩家在卡牌动作完成后继续点击旧阶段按钮。
	_close_confirmation()
	_clear_selection()
	player_hand.render_cards(snapshot.get("player_hand", []), false)
	var opponent_cards: Array = []
	for index in range(int(snapshot.get("opponent_hand_count", 0))):
		opponent_cards.append({"sequence": index})
	opponent_hand.render_cards(opponent_cards, true)
	turn_label.text = str(snapshot.get("turn_text", "等待玩家操作"))
	phase_button.text = str(snapshot.get("turn_text", "等待阶段数据")).replace(" · ", "\n")
	phase_button.disabled = !_local_player_turn or !(
		(_phase_kind == "idle" and (_can_enter_battle or _can_end_turn))
		or (_phase_kind == "battle" and (_can_enter_main2 or _can_end_battle))
	)
	player_stats_label.text = str(snapshot.get("player_stats", ""))
	opponent_stats_label.text = str(snapshot.get("opponent_stats", ""))
	show_status(str(snapshot.get("status_text", "")))
	debug_overlay.text = str(snapshot.get("debug_text", ""))
	_render_zone_cards(player_monster_zones, snapshot.get("player_monsters", []))
	_render_zone_cards(player_spell_zones, snapshot.get("player_spells", []))
	_render_zone_cards(opponent_monster_zones, snapshot.get("opponent_monsters", []))
	_render_zone_cards(opponent_spell_zones, snapshot.get("opponent_spells", []))


func show_status(message: String) -> void:
	status_label.text = message
	status_label.visible = !message.is_empty()


func _render_zone_cards(zones: Array, cards: Array) -> void:
	for zone in zones:
		zone.clear_card()
	for card in cards:
		var sequence := int(card.get("sequence", -1))
		if sequence >= 0 and sequence < zones.size():
			zones[sequence].show_card(card, !card.has("card_id"))


func _on_card_selected(card_data: Dictionary) -> void:
	if card_data.is_empty():
		_unlock_selection()
		return
	selected_card = card_data
	_show_card_detail(card_data)
	_rebuild_action_buttons()


func _preview_card(card_data: Dictionary) -> void:
	_hovered_card = card_data
	_show_card_detail(card_data)


func _on_card_unhovered(card_data: Dictionary) -> void:
	if _same_card(_hovered_card, card_data):
		_hovered_card = {}
	if selected_card.is_empty():
		_hide_card_detail()
	else:
		_show_card_detail(selected_card)


func _show_card_detail(card_data: Dictionary) -> void:
	detail_overlay.visible = true
	detail_name.text = str(card_data.get("cn_name", "未知卡片"))
	detail_type.text = str(card_data.get("types", ""))
	detail_text.text = str(card_data.get("description", ""))
	detail_image.texture = null
	var image_path := str(card_data.get("image_path", ""))
	if !image_path.is_empty():
		var absolute_path := ProjectSettings.globalize_path(image_path)
		if FileAccess.file_exists(absolute_path):
			var image := Image.load_from_file(absolute_path)
			if image != null and !image.is_empty():
				detail_image.texture = ImageTexture.create_from_image(image)


func _hide_card_detail() -> void:
	detail_overlay.visible = false
	detail_image.texture = null


func _rebuild_action_buttons() -> void:
	for child in action_box.get_children():
		child.queue_free()
	var matched := 0
	for action in current_actions:
		if int(action.get("card_id", 0)) != int(selected_card.get("card_id", -1)):
			continue
		if int(action.get("sequence", -1)) != int(selected_card.get("sequence", -2)):
			continue
		if int(action.get("location", -1)) != int(selected_card.get("location", -2)):
			continue
		if int(action.get("controller", -1)) != 0:
			continue
		var kind := str(action.get("action_kind", ""))
		var label := _action_label(kind)
		if label.is_empty():
			continue
		var button := Button.new()
		button.text = label
		button.pressed.connect(
			_emit_card_action.bind(kind, int(action.get("index", 0)), selected_card)
		)
		action_box.add_child(button)
		matched += 1
	if matched > 0:
		var cancel := Button.new()
		cancel.text = "取消"
		cancel.pressed.connect(_clear_selection)
		action_box.add_child(cancel)
	action_box.visible = matched > 0


func _action_label(kind: String) -> String:
	match kind:
		"normal_summon":
			return "通常召唤"
		"monster_set":
			return "怪兽盖放"
		"spell_trap_set":
			return "魔陷盖放"
		"activate":
			return "发动效果"
		"battle_activate":
			return "发动效果"
		"attack":
			return "攻击"
		_:
			return ""

func _emit_card_action(kind: String, index: int, card_data: Dictionary) -> void:
	if kind == "attack" or kind == "battle_activate":
		battle_action_requested.emit(kind, index, card_data)
	else:
		idle_action_requested.emit(kind, index, card_data)


func _clear_selection() -> void:
	selected_card = {}
	_hovered_card = {}
	if player_hand != null:
		player_hand.clear_selection()
	for child in action_box.get_children():
		child.queue_free()
	action_box.visible = false
	_hide_card_detail()


func _unlock_selection() -> void:
	# 重复点击只解除“锁定”，不能伪造一次鼠标离开。若指针仍停在该卡上，
	# 详情应退回临时预览状态，直到真实的 card_unhovered 事件到来。
	selected_card = {}
	if player_hand != null:
		player_hand.clear_selection()
	for child in action_box.get_children():
		child.queue_free()
	action_box.visible = false
	if _hovered_card.is_empty():
		_hide_card_detail()
	else:
		_show_card_detail(_hovered_card)


func _same_card(left: Dictionary, right: Dictionary) -> bool:
	return (
		int(left.get("card_id", -1)) == int(right.get("card_id", -2))
		and int(left.get("sequence", -1)) == int(right.get("sequence", -2))
		and int(left.get("location", -1)) == int(right.get("location", -2))
	)


func _on_phase_pressed() -> void:
	if !_local_player_turn:
		return
	var options: Array = []
	if _phase_kind == "idle":
		if _can_enter_battle:
			options.append({"kind": "enter_battle", "text": "进入战斗阶段"})
		if _can_end_turn:
			options.append({"kind": "end_turn", "text": "结束回合"})
	elif _phase_kind == "battle":
		if _can_enter_main2:
			options.append({"kind": "enter_main2", "text": "进入主要阶段二"})
		if _can_end_battle:
			options.append({"kind": "end_battle", "text": "结束战斗阶段"})
	if !options.is_empty():
		_open_phase_options(options)


func _request_restart() -> void:
	_open_confirmation("restart", "确定使用新种子重新开局？")


func _request_exit() -> void:
	_open_confirmation("exit", "确定退出游戏？")


func _open_confirmation(kind: String, message: String) -> void:
	_confirmation_kind = kind
	confirmation_label.text = message
	_clear_confirmation_buttons()
	var confirm := Button.new()
	confirm.text = "确认"
	confirm.pressed.connect(_confirm_pending_action)
	confirmation_buttons.add_child(confirm)
	_add_confirmation_cancel()
	confirmation_overlay.visible = true

func _open_phase_options(options: Array) -> void:
	_confirmation_kind = ""
	confirmation_label.text = "选择要前往的阶段"
	_clear_confirmation_buttons()
	for option in options:
		var button := Button.new()
		button.text = str(option.text)
		button.pressed.connect(_emit_phase_action.bind(str(option.kind)))
		confirmation_buttons.add_child(button)
	_add_confirmation_cancel()
	confirmation_overlay.visible = true


func _clear_confirmation_buttons() -> void:
	for child in confirmation_buttons.get_children():
		child.queue_free()


func _add_confirmation_cancel() -> void:
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.pressed.connect(_close_confirmation)
	confirmation_buttons.add_child(cancel)


func _emit_phase_action(kind: String) -> void:
	_close_confirmation()
	match kind:
		"enter_battle":
			enter_battle_requested.emit()
		"enter_main2":
			enter_main2_requested.emit()
		"end_battle":
			end_battle_requested.emit()
		"end_turn":
			end_turn_requested.emit()


func _close_confirmation() -> void:
	_confirmation_kind = ""
	confirmation_overlay.visible = false


func _confirm_pending_action() -> void:
	var kind := _confirmation_kind
	_close_confirmation()
	match kind:
		"end_turn":
			end_turn_requested.emit()
		"restart":
			restart_requested.emit()
		"exit":
			exit_requested.emit()


func _toggle_debug() -> void:
	debug_overlay.visible = !debug_overlay.visible


func _on_background_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_clear_selection()
		_close_confirmation()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_handle_surface_click(get_viewport().gui_get_hovered_control())


func _handle_surface_click(target: Control) -> void:
	# GUI 输入会先命中战场中的容器和区域节点，不能依赖位于最底层的背景
	# 收到事件。这里从视口取得实际命中控件：按钮和浮层内部保留其语义，
	# 其余表面统一视作“场地空白”，用于解除选择和关闭确认。
	if target is BaseButton:
		return
	for overlay in [detail_overlay, confirmation_overlay, debug_overlay, action_box]:
		if target == overlay or (target != null and overlay.is_ancestor_of(target)):
			return
	_clear_selection()
	_close_confirmation()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F1:
		_toggle_debug()
		get_viewport().set_input_as_handled()
