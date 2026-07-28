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
signal direct_attack_requested
signal attack_target_preview_requested(location: Dictionary)
signal attack_target_requested(option_index: int)
signal card_selection_cancel_requested
signal yes_no_requested(accepted: bool)
signal position_requested(position: int, decision_generation: int)
signal chain_requested(index: int, decision_generation: int)
signal chain_pass_requested(decision_generation: int)

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
@onready var opponent_status_surface: Control = %OpponentStatusSurface
@onready var opponent_stats_label: Label = %OpponentStatus
@onready var direct_attack_highlight: Panel = %DirectAttackHighlight
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
var _rule_decision_kind := "none"
var _card_selection_cancelable := false
# 每次规则快照重绘都会推进代次。动态按钮绑定创建时的代次，使已经退休的
# 节点即使在 queue_free 前残留引用，也不能提交紧随其后的同形决策。
var _rule_decision_generation := 0
# key 只由 OCGCore 公开的 controller/location/sequence 组成，值是同一决策帧中的
# 候选 index；卡号不参与映射，避免同名卡或隐藏身份影响规则位置选择。
var _card_option_indices: Dictionary = {}
# 连锁候选按公开规则位置分组，同一位置允许多个效果。只有所有候选都能映射到
# 当前真实 CardView 后才写入此表；空表表示整个窗口不可提交，绝不保留可映射子集。
var _chain_options_by_location: Dictionary = {}
var _chain_forced := false


func _ready() -> void:
	# OCGCore 的 sequence=0..4 对应画面标号 1..5。对手卡位在场景树中按
	# 5→1 的视觉顺序排列，因此这里必须逐个绑定语义节点，不能依赖子节点顺序。
	player_monster_zones = [
		$SafeArea/Battlefield/PlayerMonsterRow/PlayerMonsterZone1,
		$SafeArea/Battlefield/PlayerMonsterRow/PlayerMonsterZone2,
		$SafeArea/Battlefield/PlayerMonsterRow/PlayerMonsterZone3,
		$SafeArea/Battlefield/PlayerMonsterRow/PlayerMonsterZone4,
		$SafeArea/Battlefield/PlayerMonsterRow/PlayerMonsterZone5,
	]
	player_spell_zones = [
		$SafeArea/Battlefield/PlayerSpellRow/PlayerSpellZone1,
		$SafeArea/Battlefield/PlayerSpellRow/PlayerSpellZone2,
		$SafeArea/Battlefield/PlayerSpellRow/PlayerSpellZone3,
		$SafeArea/Battlefield/PlayerSpellRow/PlayerSpellZone4,
		$SafeArea/Battlefield/PlayerSpellRow/PlayerSpellZone5,
	]
	opponent_monster_zones = [
		$SafeArea/Battlefield/OpponentMonsterRow/OpponentMonsterZone5,
		$SafeArea/Battlefield/OpponentMonsterRow/OpponentMonsterZone4,
		$SafeArea/Battlefield/OpponentMonsterRow/OpponentMonsterZone3,
		$SafeArea/Battlefield/OpponentMonsterRow/OpponentMonsterZone2,
		$SafeArea/Battlefield/OpponentMonsterRow/OpponentMonsterZone1,
	]
	opponent_spell_zones = [
		$SafeArea/Battlefield/OpponentSpellRow/OpponentSpellZone5,
		$SafeArea/Battlefield/OpponentSpellRow/OpponentSpellZone4,
		$SafeArea/Battlefield/OpponentSpellRow/OpponentSpellZone3,
		$SafeArea/Battlefield/OpponentSpellRow/OpponentSpellZone2,
		$SafeArea/Battlefield/OpponentSpellRow/OpponentSpellZone1,
	]
	assert(player_monster_zones.size() == 5, "玩家怪兽区必须有五个原生卡位")
	assert(player_spell_zones.size() == 5, "玩家魔陷区必须有五个原生卡位")
	assert(opponent_monster_zones.size() == 5, "对手怪兽区必须有五个原生卡位")
	assert(opponent_spell_zones.size() == 5, "对手魔陷区必须有五个原生卡位")

	_configure_zone_row(player_monster_zones, "玩家怪兽")
	_configure_zone_row(player_spell_zones, "玩家魔陷")
	_configure_zone_row(opponent_monster_zones, "对手怪兽")
	_configure_zone_row(opponent_spell_zones, "对手魔陷")

	player_hand.card_selected.connect(_on_card_selected)
	player_hand.card_hovered.connect(_preview_card)
	player_hand.card_unhovered.connect(_on_card_unhovered)
	for zone in player_monster_zones + player_spell_zones:
		# 绑定信号来源后，场上卡牌选择才能精确驱动对应 ZoneView 的 CardView
		# 选择框；卡牌数据本身不携带其场景节点引用，不能据此猜测视觉来源。
		zone.card_selected.connect(_on_card_selected.bind(zone))
		zone.card_hovered.connect(_preview_card)
		zone.card_unhovered.connect(_on_card_unhovered)
	# 对手场区始终连接同一个选择路由；路由只在当前 OCGCore 决策允许时发出
	# 攻击目标或连锁候选意图，普通浏览状态不会产生规则动作。
	for zone in opponent_monster_zones:
		zone.card_selected.connect(
			_route_opponent_field_selection.bind(zone, 1, 4)
		)
	for zone in opponent_spell_zones:
		zone.card_selected.connect(
			_route_opponent_field_selection.bind(zone, 1, 8)
		)
	for zone in opponent_monster_zones + opponent_spell_zones:
		zone.card_hovered.connect(_preview_card)
		zone.card_unhovered.connect(_on_card_unhovered)

	phase_button.pressed.connect(_on_phase_pressed)
	restart_button.pressed.connect(_request_restart)
	debug_button.pressed.connect(_toggle_debug)
	exit_button.pressed.connect(_request_exit)
	opponent_status_surface.gui_input.connect(_on_opponent_status_input)
	%Background.gui_input.connect(_on_background_input)


func _configure_zone_row(zones: Array, prefix: String) -> void:
	for index in range(zones.size()):
		zones[index].configure("%s %s" % [prefix, index + 1])


func render_snapshot(snapshot: Dictionary, preserve_decision_generation := false) -> void:
	# 所有高亮和动态决策按钮都绑定上一份 OCGCore 快照；读取任何新字段前先
	# 原子清除旧表现，终局或无决策快照就不会残留可点击目标。MSG_RETRY
	# 仍属于同一次规则决策，重建节点时保留代次；正常推进才让旧信号整体失效。
	_clear_rule_decision_presentation(preserve_decision_generation)
	current_actions = snapshot.get("idle_actions", [])
	_local_player_turn = bool(snapshot.get("local_player_turn", false))
	_can_end_turn = bool(snapshot.get("can_end_turn", false))
	_phase_kind = str(snapshot.get("phase_kind", "idle"))
	_can_enter_battle = bool(snapshot.get("can_enter_battle", false))
	_can_enter_main2 = bool(snapshot.get("can_enter_main2", false))
	_can_end_battle = bool(snapshot.get("can_end_battle", false))
	# 阶段选项绑定的是上一份 OCGCore 决策快照。任何新快照到达后都必须
	# 立即失效，避免玩家在卡牌动作完成后继续点击旧阶段按钮。
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
	_bind_hidden_opponent_field_inputs()
	_render_rule_decision(snapshot)


func _render_rule_decision(snapshot: Dictionary) -> void:
	# 非本地玩家或终局快照即使携带 OCGCore 最后一帧决策，也只能展示场面，
	# 不得暴露可点击入口。
	if !_local_player_turn:
		return
	var kind := str(snapshot.get("decision_kind", "none"))
	var attack_context_supported := bool(
		snapshot.get("attack_target_context_supported", false)
	)
	if (
		kind == "yes_no"
		and int(snapshot.get("decision_description", 0)) == 31
		and attack_context_supported
	):
		_show_attack_route_choice()
	elif kind == "select_card" and attack_context_supported:
		_show_card_options(snapshot)
	elif kind == "select_card":
		# pending 仍由 OCGCore 持有；这里只明确说明当前界面没有安全的攻击语义，
		# 不创建高亮、取消入口或任何可提交信号，避免把效果选择伪装成攻击目标。
		show_status("当前卡牌选择上下文尚未支持：候选无法完整映射为攻击目标")
	elif kind == "yes_no" and int(snapshot.get("decision_description", 0)) == 31:
		# 描述 31 只有 Main 保存了本地攻击来源时才是攻击路线；来源缺失时既不能
		# 显示攻击入口，也不能降级成通用 YesNo，因为 Main 会拒绝这类伪入口。
		return
	elif kind == "yes_no":
		_open_yes_no_prompt(int(snapshot.get("decision_description", 0)))
	elif kind == "select_position":
		_open_position_prompt(
			int(snapshot.get("selection_card_id", 0)),
			snapshot.get("position_options", [])
		)
	elif kind == "select_chain":
		_show_chain_options(snapshot)


func _show_chain_options(snapshot: Dictionary) -> void:
	var options: Array = snapshot.get("chain_options", [])
	var mapped_nodes: Dictionary = {}
	var grouped_options: Dictionary = {}
	for option in options:
		var location := _rule_location(option)
		var candidate_node: Variant = _find_chain_candidate_node(location)
		if candidate_node == null:
			_rule_decision_kind = "select_chain_unmapped"
			show_status("连锁候选无法完整映射到当前场面，请等待状态刷新")
			return
		var key := _rule_location_key(location)
		if !grouped_options.has(key):
			grouped_options[key] = []
		grouped_options[key].append(option.duplicate(true))
		mapped_nodes[key] = candidate_node

	# 先完成全量映射，再一次性发布高亮与索引。若上面的任一项失败，界面看不到
	# 部分候选，也没有“不连锁”捷径绕过当前异常快照。
	_rule_decision_kind = "select_chain"
	_chain_forced = bool(snapshot.get("chain_forced", false))
	_chain_options_by_location = grouped_options
	var hand_sequences: Dictionary = {}
	for key in mapped_nodes:
		var candidate_node = mapped_nodes[key]
		if candidate_node is CardView and candidate_node.get_parent() == player_hand:
			hand_sequences[int(candidate_node.card_data.get("sequence", -1))] = true
		elif candidate_node is ZoneView:
			candidate_node.set_chain_candidate(true)
	player_hand.set_chain_candidate_sequences(hand_sequences)
	if _chain_forced:
		show_status("必须选择一个连锁效果")
	else:
		_restore_chain_pass()


func _find_chain_candidate_node(location: Dictionary):
	var controller := int(location.get("controller", -1))
	var area := int(location.get("location", -1))
	var sequence := int(location.get("sequence", -1))
	if sequence < 0:
		return null
	if controller == 0 and area == 2:
		for child in player_hand.get_children():
			if (
				child is CardView
				and int(child.card_data.get("sequence", -1)) == sequence
				and int(child.card_data.get("location", -1)) == 2
			):
				return child
		return null
	var zones: Array = []
	if controller == 0 and area == 4:
		zones = player_monster_zones
	elif controller == 0 and area == 8:
		zones = player_spell_zones
	elif controller == 1 and area == 4:
		zones = opponent_monster_zones
	elif controller == 1 and area == 8:
		zones = opponent_spell_zones
	else:
		return null
	if sequence >= zones.size():
		return null
	var zone: ZoneView = zones[sequence]
	if zone.card_container.get_child_count() != 1:
		return null
	return zone


func _show_attack_route_choice() -> void:
	_rule_decision_kind = "attack_route"
	direct_attack_highlight.visible = true
	# 这里只标记“可以请求 OCGCore 选择该怪兽”；真实合法性要等待随后返回的
	# select_card.card_options，不能根据当前场面自行推断。
	for zone in opponent_monster_zones:
		zone.set_attack_target_preview(zone.card_container.get_child_count() > 0)
	show_status("点击对手 LP 直接攻击，或点击怪兽选择目标")


func _show_card_options(snapshot: Dictionary) -> void:
	if (
		int(snapshot.get("selection_min", 0)) != 1
		or int(snapshot.get("selection_max", 0)) != 1
	):
		return
	_rule_decision_kind = "select_card"
	for option in snapshot.get("card_options", []):
		var location := _rule_location(option)
		var zone := _find_opponent_monster_zone(location)
		if zone == null:
			continue
		var key := _rule_location_key(location)
		_card_option_indices[key] = int(option.get("index", -1))
		zone.set_targetable(true)
	_card_selection_cancelable = bool(snapshot.get("selection_cancelable", false))
	_restore_card_selection_cancel()


func _restore_card_selection_cancel() -> void:
	# 规则取消入口属于当前 OCGCore SelectCard 快照，不属于普通卡牌选择动作。
	# 空白点击或选择己方卡只能清理本地浏览状态，不能让核心仍等待时失去取消能力。
	if _rule_decision_kind == "select_card" and _card_selection_cancelable:
		var cancel := Button.new()
		cancel.text = "取消攻击"
		cancel.pressed.connect(_emit_card_selection_cancel)
		action_box.add_child(cancel)
		action_box.visible = true


func _open_yes_no_prompt(description: int) -> void:
	_rule_decision_kind = "yes_no"
	_confirmation_kind = "rule_yes_no"
	confirmation_label.text = "请选择是或否（规则描述 %s）" % description
	_clear_confirmation_buttons()
	for option in [
		{"accepted": true, "text": "是"},
		{"accepted": false, "text": "否"},
	]:
		var button := Button.new()
		button.text = str(option.text)
		button.pressed.connect(_emit_yes_no.bind(bool(option.accepted)))
		confirmation_buttons.add_child(button)
	confirmation_overlay.visible = true


func _open_position_prompt(card_id: int, options: Array) -> void:
	_rule_decision_kind = "select_position"
	_confirmation_kind = "rule_position"
	confirmation_label.text = "请选择卡片 %s 的表示形式" % card_id
	_clear_confirmation_buttons()
	# 文案映射只消费 C++ 已验证的单值候选；未知值不创建按钮，更不能由
	# Godot 猜测位掩码组合。固定遍历输入顺序保持 OCGCore 候选顺序。
	const POSITION_TEXT := {
		1: "表侧攻击",
		2: "里侧攻击",
		4: "表侧守备",
		8: "里侧守备",
	}
	for raw_position in options:
		var selected_position := int(raw_position)
		if !POSITION_TEXT.has(selected_position):
			continue
		var button := Button.new()
		button.text = str(POSITION_TEXT[selected_position])
		button.pressed.connect(
			_emit_position.bind(selected_position, _rule_decision_generation)
		)
		confirmation_buttons.add_child(button)
	confirmation_overlay.visible = confirmation_buttons.get_child_count() > 0


func _emit_position(selected_position: int, decision_generation: int) -> void:
	if (
		_rule_decision_kind == "select_position"
		and decision_generation == _rule_decision_generation
	):
		position_requested.emit(selected_position, decision_generation)


func _clear_rule_decision_presentation(preserve_decision_generation := false) -> void:
	if !preserve_decision_generation:
		_rule_decision_generation += 1
	_rule_decision_kind = "none"
	_card_selection_cancelable = false
	_card_option_indices.clear()
	_chain_options_by_location.clear()
	_chain_forced = false
	direct_attack_highlight.visible = false
	if player_hand != null:
		player_hand.set_chain_candidate_sequences({})
	for zone in (
		player_monster_zones
		+ player_spell_zones
		+ opponent_monster_zones
		+ opponent_spell_zones
	):
		zone.set_chain_candidate(false)
	for zone in opponent_monster_zones:
		zone.set_attack_target_preview(false)
		zone.set_targetable(false)
	_clear_dynamic_children(action_box)
	action_box.visible = false
	_close_confirmation()


func _find_opponent_monster_zone(location: Dictionary) -> ZoneView:
	if (
		int(location.get("controller", -1)) != 1
		or int(location.get("location", -1)) != 4
	):
		return null
	var sequence := int(location.get("sequence", -1))
	if sequence < 0 or sequence >= opponent_monster_zones.size():
		return null
	var zone: ZoneView = opponent_monster_zones[sequence]
	if zone.card_container.get_child_count() == 0:
		return null
	var displayed_card: CardView = zone.card_container.get_child(0)
	if _opponent_monster_rule_location(displayed_card.card_data) != location:
		return null
	return zone


func _rule_location(data: Dictionary) -> Dictionary:
	return {
		"controller": int(data.get("controller", -1)),
		"location": int(data.get("location", -1)),
		"sequence": int(data.get("sequence", -1)),
	}


func _local_rule_location(card_data: Dictionary, source_zone: ZoneView) -> Dictionary:
	# 原生公开卡快照只携带 location/sequence，不重复输出 controller。己方
	# controller=0 必须由可信的信号来源补齐：空来源只代表 PlayerHand，场区
	# 来源则必须是本面板持有的己方怪兽区或魔陷区。这样既不扩大 Bridge 的
	# 公开卡契约，也不会相信卡数据里可能被伪造的 controller/location。
	var expected_location := 2
	if source_zone in player_monster_zones:
		expected_location = 4
	elif source_zone in player_spell_zones:
		expected_location = 8
	elif source_zone != null:
		return {}
	if int(card_data.get("location", -1)) != expected_location:
		return {}
	var sequence := int(card_data.get("sequence", -1))
	if sequence < 0:
		return {}
	return {
		"controller": 0,
		"location": expected_location,
		"sequence": sequence,
	}


func _opponent_monster_rule_location(data: Dictionary) -> Dictionary:
	# 对手公开场区由场景节点本身确定 controller=1/location=MZONE(4)；Bridge
	# 为隐藏身份卡省略 controller 时，仍可安全补齐这两个非秘密语义字段。
	# sequence 必须继续来自核心快照，不能用视觉子节点顺序推断。
	return {
		"controller": 1,
		"location": 4,
		"sequence": int(data.get("sequence", -1)),
	}


func _rule_location_key(location: Dictionary) -> String:
	return "%s:%s:%s" % [
		int(location.get("controller", -1)),
		int(location.get("location", -1)),
		int(location.get("sequence", -1)),
	]


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


func _bind_hidden_opponent_field_inputs() -> void:
	# Bridge 会隐藏对手场上卡的 card_id，CardView 因而以卡背展示并主动抑制
	# card_selected，防止隐藏身份被普通浏览选中。但攻击目标和连锁候选都只需要
	# controller/location/sequence，必须继续消费真实按钮的 pressed 输入。
	# 这里只为隐藏的对手场区卡补规则路由；公开卡仍走 ZoneView 转发，避免双发。
	for zone in opponent_monster_zones:
		if zone.card_container.get_child_count() != 1:
			continue
		var card: CardView = zone.card_container.get_child(0)
		if card.face_down:
			card.pressed.connect(
				_route_hidden_opponent_field_press.bind(card, zone, 1, 4)
			)
	for zone in opponent_spell_zones:
		if zone.card_container.get_child_count() != 1:
			continue
		var card: CardView = zone.card_container.get_child(0)
		if card.face_down:
			card.pressed.connect(
				_route_hidden_opponent_field_press.bind(card, zone, 1, 8)
			)


func _route_hidden_opponent_field_press(
	card: CardView,
	source_zone: ZoneView,
	controller: int,
	location: int
) -> void:
	# 新快照会同步把旧 CardView 移出容器；即使外部仍持有并触发旧按钮，也不能
	# 把上一帧位置重新送入当前规则决策。
	if (
		!is_instance_valid(card)
		or card.get_parent() != source_zone.card_container
		or source_zone.card_container.get_child_count() != 1
		or source_zone.card_container.get_child(0) != card
	):
		return
	_route_opponent_field_selection(card.card_data, source_zone, controller, location)


func _on_card_selected(card_data: Dictionary, source_zone: ZoneView = null) -> void:
	if card_data.is_empty():
		_unlock_selection()
		return
	if _rule_decision_kind == "select_chain":
		_select_chain_card(_local_rule_location(card_data, source_zone), card_data, source_zone)
		return
	selected_card = card_data
	if source_zone != null and player_hand != null:
		player_hand.clear_selection()
	_set_field_card_selection(source_zone)
	_show_card_detail(card_data)
	_rebuild_action_buttons()


func _route_opponent_field_selection(
	card_data: Dictionary,
	source_zone: ZoneView,
	controller: int = 1,
	location_kind: int = 4
) -> void:
	if card_data.is_empty():
		return
	var location := {
		"controller": controller,
		"location": location_kind,
		"sequence": int(card_data.get("sequence", -1)),
	}
	if _rule_decision_kind == "select_chain":
		_select_chain_card(location, card_data, source_zone)
		return
	if _rule_decision_kind == "attack_route":
		if (
			source_zone.target_highlight.visible
			and source_zone.target_highlight.theme_type_variation == &"AttackTargetPreview"
		):
			attack_target_preview_requested.emit(location)
		return
	if _rule_decision_kind != "select_card":
		return
	var option_index = _card_option_indices.get(_rule_location_key(location), null)
	if (
		option_index != null
		and source_zone.target_highlight.visible
		and source_zone.target_highlight.theme_type_variation == &"TargetHighlight"
	):
		attack_target_requested.emit(int(option_index))


func _select_chain_card(
	location: Dictionary,
	card_data: Dictionary,
	source_zone: ZoneView = null
) -> void:
	var key := _rule_location_key(location)
	if !_chain_options_by_location.has(key):
		# HandView 会先更新自己的选中框再转发点击；若该卡不是当前连锁候选，
		# 必须同时撤销旧效果按钮和这次无效选中，避免视觉卡牌与可提交效果错位。
		_clear_selection()
		return
	# 对手里侧卡的快照可能只公开 sequence。controller/location 由已命中的真实
	# ZoneView 语义补齐，仅用于当前候选分组键；不得把候选中的 card_id 回填到卡面。
	selected_card = card_data.duplicate(true)
	selected_card["controller"] = int(location.get("controller", -1))
	selected_card["location"] = int(location.get("location", -1))
	selected_card["sequence"] = int(location.get("sequence", -1))
	if source_zone == null:
		_set_field_card_selection(null)
	else:
		player_hand.clear_selection()
		_set_field_card_selection(source_zone if int(location.controller) == 0 else null)
	_show_card_detail(selected_card)
	_rebuild_action_buttons()


func _on_opponent_status_input(event: InputEvent) -> void:
	if (
		_rule_decision_kind == "attack_route"
		and direct_attack_highlight.visible
		and event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and event.pressed
	):
		direct_attack_requested.emit()


func _emit_card_selection_cancel() -> void:
	if _rule_decision_kind == "select_card":
		card_selection_cancel_requested.emit()


func _emit_yes_no(accepted: bool) -> void:
	if _rule_decision_kind == "yes_no":
		yes_no_requested.emit(accepted)


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
	_clear_dynamic_children(action_box)
	if _rule_decision_kind == "select_chain":
		var options: Array = _chain_options_by_location.get(
			_rule_location_key(selected_card),
			[]
		)
		for effect_index in range(options.size()):
			var option: Dictionary = options[effect_index]
			var button := Button.new()
			button.text = "发动效果 %s（描述 %s）" % [
				effect_index + 1,
				int(option.get("description", 0)),
			]
			button.pressed.connect(
				_emit_chain.bind(
					int(option.get("index", -1)),
					_rule_decision_generation
				)
			)
			action_box.add_child(button)
		_restore_chain_pass()
		action_box.visible = action_box.get_child_count() > 0
		return
	if _rule_decision_kind == "select_card":
		action_box.visible = false
		_restore_card_selection_cancel()
		return
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


func _restore_chain_pass() -> void:
	if _rule_decision_kind != "select_chain" or _chain_forced:
		return
	var pass_button := Button.new()
	pass_button.text = "不连锁"
	pass_button.pressed.connect(
		_emit_chain_pass.bind(_rule_decision_generation)
	)
	action_box.add_child(pass_button)
	action_box.visible = true


func _emit_chain(index: int, decision_generation: int) -> void:
	if (
		_rule_decision_kind == "select_chain"
		and decision_generation == _rule_decision_generation
	):
		chain_requested.emit(index, decision_generation)


func _emit_chain_pass(decision_generation: int) -> void:
	if (
		_rule_decision_kind == "select_chain"
		and !_chain_forced
		and decision_generation == _rule_decision_generation
	):
		chain_pass_requested.emit(decision_generation)


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
	_set_field_card_selection(null)
	_clear_dynamic_children(action_box)
	action_box.visible = false
	_restore_card_selection_cancel()
	_restore_chain_pass()
	_hide_card_detail()


func _unlock_selection() -> void:
	# 重复点击只解除“锁定”，不能伪造一次鼠标离开。若指针仍停在该卡上，
	# 详情应退回临时预览状态，直到真实的 card_unhovered 事件到来。
	selected_card = {}
	if player_hand != null:
		player_hand.clear_selection()
	_set_field_card_selection(null)
	_clear_dynamic_children(action_box)
	action_box.visible = false
	_restore_card_selection_cancel()
	_restore_chain_pass()
	if _hovered_card.is_empty():
		_hide_card_detail()
	else:
		_show_card_detail(_hovered_card)


func _set_field_card_selection(selected_zone: ZoneView) -> void:
	# selected_card 只保存来自公开快照的语义字段；节点选择框是纯表现状态。
	# 每次来源变化都遍历全部己方场区，保证手牌选择、取消和新快照不会留下旧边框。
	for zone in player_monster_zones + player_spell_zones:
		zone.set_card_selected(zone == selected_zone)


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
	# restart/exit 属于本地工具确认，不能覆盖 OCGCore 正在等待的任何规则决策；
	# 只有新快照清理 YesNo、卡牌/表示形式/连锁等入口后才允许打开普通确认。
	if _rule_decision_kind != "none":
		return
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
	# 阶段选项同样只是本地快捷入口。规则决策未完成时即使阶段能力仍留在快照中，
	# 也必须保留规则控件，不能让普通取消把核心置于无人可响应的等待状态。
	if _rule_decision_kind != "none":
		return
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
	_clear_dynamic_children(confirmation_buttons)


func _clear_dynamic_children(container: Container) -> void:
	# queue_free() 只在帧末销毁节点；若不先脱离容器，同帧重建会让旧按钮继续
	# 参与 Container 排版。旧按钮对象在帧末前仍可被持有，因此还必须断开
	# pressed 回调，避免已退休的候选动作被测试、输入转发或外部引用再次提交。
	for child in container.get_children():
		container.remove_child(child)
		if child is BaseButton:
			for connection in child.get_signal_connection_list(&"pressed"):
				var callback: Callable = connection.get("callable", Callable())
				if callback.is_valid() and child.is_connected(&"pressed", callback):
					child.disconnect(&"pressed", callback)
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
	_clear_confirmation_buttons()
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
		# 任意规则确认按钮都是 OCGCore 当前唯一可推进入口；外部点击只能关闭
		# restart/phase 等本地确认，不能让核心等待期间把入口销毁。
		if _rule_decision_kind == "none":
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
	if _rule_decision_kind == "none":
		_close_confirmation()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F1:
		_toggle_debug()
		get_viewport().set_input_as_handled()
