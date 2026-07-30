extends SceneTree

const HAND_VIEW_SCENE = preload("res://src/ui/hand_view.tscn")
const ZONE_VIEW_SCENE = preload("res://src/ui/zone_view.tscn")
const CARD_SCENE_PATH := "res://src/ui/card_view.tscn"
const DUEL_BOARD_SCENE = preload("res://src/duel/duel_board.tscn")
const MAIN_SCENE = preload("res://src/main/main.tscn")
const MAIN_SCRIPT = preload("res://src/main/main.gd")

var _selected_events: Array = []
var _hovered_events: Array = []
var _unhovered_events: Array = []
var _battle_events: Array = []
var _idle_events: Array = []
var _end_turn_events: Array = []
var _restart_events: Array = []
var _direct_attack_events: Array = []
var _attack_target_preview_events: Array = []
var _attack_target_events: Array = []
var _card_selection_cancel_events: Array = []
var _yes_no_events: Array = []
var _effect_yes_no_events: Array = []
var _place_events: Array = []
var _input_viewport: SubViewport

class FakeBridge:
	extends RefCounted

	var game_over := false
	var winner := -1
	var win_reason := -1
	var idle_actions: Array = []

	func get_duel_state() -> Dictionary:
		return {
			"ok": true,
			"game_over": game_over,
			"winner": winner,
			"win_reason": win_reason,
			"players": {
				"p1": {
					"lp": 7600,
					"deck": 35,
					"hand": 5,
					"extra": 0,
					"graveyard": 0,
					"banished": 0,
					"hand_cards": [],
					"monster_cards": [],
					"spell_trap_cards": [],
				},
				"p2": {
					"lp": 4200,
					"deck": 35,
					"hand": 5,
					"extra": 0,
					"graveyard": 0,
					"banished": 0,
					"monster_cards": [],
					"spell_trap_cards": [],
				},
			},
		}

	func get_pending_action() -> Dictionary:
		return {
			"kind": "idle",
			"player": 0,
			"can_end_turn": true,
			"idle_actions": idle_actions,
			"message_type": 11,
		}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# Main 的测试注入仍直接调用 _refresh_board；真实场景则必须提供同一个唯一
	# DuelBoard 节点，避免测试与运行时走出两套节点来源。
	var main_scene = MAIN_SCENE.instantiate()
	var scene_board = main_scene.find_child("DuelBoard", true, false)
	if scene_board == null or scene_board.scene_file_path != DUEL_BOARD_SCENE.resource_path:
		_fail("Main 场景必须提供真实 DuelBoard 供运行时与测试共用")
		return
	main_scene.free()
	# HandView 的固定容器样式属于原生场景；测试必须像真实界面一样实例化场景。
	var hand: HandView = HAND_VIEW_SCENE.instantiate()
	root.add_child(hand)
	await process_frame

	if !hand.has_signal("card_unhovered"):
		_fail("HandView 必须向决斗界面转发 card_unhovered 信号")
		return

	hand.card_selected.connect(func(card_data: Dictionary) -> void:
		_selected_events.append(card_data)
	)
	hand.card_hovered.connect(func(card_data: Dictionary) -> void:
		_hovered_events.append(card_data)
	)
	hand.card_unhovered.connect(func(card_data: Dictionary) -> void:
		_unhovered_events.append(card_data)
	)
	var card := {
		"card_id": 89631139,
		"sequence": 2,
		"location": 2,
		"controller": 0,
		"cn_name": "测试卡",
	}
	hand.render_cards([card], true)
	await process_frame
	if hand.get_child_count() != 1:
		_fail("HandView 必须为每张手牌创建 CardView 场景实例")
		return
	var hand_card: CardView = hand.get_child(0)
	if hand_card.scene_file_path != CARD_SCENE_PATH:
		_fail("HandView 必须实例化 CardView 原生场景而非裸脚本")
		return
	if !hand_card.find_child("CardBackPanel", true, false).visible:
		_fail("HandView 展示背面手牌时必须显示 CardView 卡背视觉")
		return

	# ZoneView 的 CardContainer、标题与高亮节点由原生场景提供，禁止回退到裸脚本实例。
	var zone: ZoneView = ZONE_VIEW_SCENE.instantiate()
	root.add_child(zone)
	await process_frame
	zone.configure("测试区域")
	zone.show_card(card, true)
	await process_frame
	if zone.card_container.get_child_count() != 1:
		_fail("ZoneView 必须为区域卡牌创建 CardView 场景实例")
		return
	var zone_card: CardView = zone.card_container.get_child(0)
	if zone_card.scene_file_path != CARD_SCENE_PATH:
		_fail("ZoneView 必须实例化 CardView 原生场景而非裸脚本")
		return
	if !zone_card.find_child("CardBackPanel", true, false).visible:
		_fail("ZoneView 展示背面卡牌时必须显示 CardView 卡背视觉")
		return
	hand.card_hovered.emit(card)
	hand.card_unhovered.emit(card)
	if _hovered_events.size() != 1 or _unhovered_events.size() != 1:
		_fail("HandView 必须完整转发悬浮进入和离开事件")
		return
	hand._on_card_selected(card)
	hand._on_card_selected(card)
	if _selected_events.size() != 2:
		_fail("点击事件数量不正确")
		return
	if int(_selected_events[0].get("sequence", -1)) != 2:
		_fail("首次点击必须选中目标卡牌")
		return
	if !_selected_events[1].is_empty():
		_fail("再次点击同一卡牌必须发出空字典以取消选择")
		return

	# queue_free() 延迟到帧末；组件必须在同帧先让旧卡脱离容器、禁用输入并且
	# 只断开自己建立的三条转发。测试额外保留旧卡外部观察者，防止实现粗暴断开全部连接。
	var atomic_hand: HandView = HAND_VIEW_SCENE.instantiate()
	root.add_child(atomic_hand)
	await process_frame
	var hand_forwarded_selected: Array = []
	var hand_forwarded_hovered: Array = []
	var hand_forwarded_unhovered: Array = []
	atomic_hand.card_selected.connect(
		func(data: Dictionary) -> void: hand_forwarded_selected.append(data)
	)
	atomic_hand.card_hovered.connect(
		func(data: Dictionary) -> void: hand_forwarded_hovered.append(data)
	)
	atomic_hand.card_unhovered.connect(
		func(data: Dictionary) -> void: hand_forwarded_unhovered.append(data)
	)
	var old_hand_data := {
		"card_id": 30001,
		"sequence": 0,
		"location": 2,
		"controller": 0,
	}
	var new_hand_data := {
		"card_id": 30002,
		"sequence": 1,
		"location": 2,
		"controller": 0,
	}
	atomic_hand.render_cards([old_hand_data], false)
	var retired_hand_card: CardView = atomic_hand.get_child(0)
	var retired_hand_external_events: Array[String] = []
	retired_hand_card.card_selected.connect(
		func(_data: Dictionary) -> void: retired_hand_external_events.append("选择")
	)
	retired_hand_card.card_hovered.connect(
		func(_data: Dictionary) -> void: retired_hand_external_events.append("悬浮")
	)
	retired_hand_card.card_unhovered.connect(
		func(_data: Dictionary) -> void: retired_hand_external_events.append("离开")
	)
	atomic_hand.render_cards([new_hand_data], false)
	if (
		atomic_hand.get_child_count() != 1
		or int(atomic_hand.get_child(0).card_data.card_id) != int(new_hand_data.card_id)
		or retired_hand_card.get_parent() != null
		or !retired_hand_card.disabled
		or retired_hand_card.mouse_filter != Control.MOUSE_FILTER_IGNORE
	):
		_fail("HandView 同帧替换后必须立即只保留可输入的新卡")
		return
	retired_hand_card.card_selected.emit(old_hand_data)
	retired_hand_card.card_hovered.emit(old_hand_data)
	retired_hand_card.card_unhovered.emit(old_hand_data)
	if (
		!hand_forwarded_selected.is_empty()
		or !hand_forwarded_hovered.is_empty()
		or !hand_forwarded_unhovered.is_empty()
	):
		_fail("HandView 已退休卡牌不得继续向组件转发事件")
		return
	if retired_hand_external_events != ["选择", "悬浮", "离开"]:
		_fail("HandView 退休时不得断开卡牌的外部观察者")
		return
	var current_hand_card: CardView = atomic_hand.get_child(0)
	current_hand_card.card_selected.emit(new_hand_data)
	current_hand_card.card_hovered.emit(new_hand_data)
	current_hand_card.card_unhovered.emit(new_hand_data)
	if (
		hand_forwarded_selected.size() != 1
		or hand_forwarded_hovered.size() != 1
		or hand_forwarded_unhovered.size() != 1
	):
		_fail("HandView 新卡牌必须继续完整转发三个事件")
		return

	var atomic_zone: ZoneView = ZONE_VIEW_SCENE.instantiate()
	root.add_child(atomic_zone)
	await process_frame
	var zone_forwarded_selected: Array = []
	var zone_forwarded_hovered: Array = []
	var zone_forwarded_unhovered: Array = []
	atomic_zone.card_selected.connect(
		func(data: Dictionary) -> void: zone_forwarded_selected.append(data)
	)
	atomic_zone.card_hovered.connect(
		func(data: Dictionary) -> void: zone_forwarded_hovered.append(data)
	)
	atomic_zone.card_unhovered.connect(
		func(data: Dictionary) -> void: zone_forwarded_unhovered.append(data)
	)
	var old_zone_data := {
		"card_id": 40001,
		"sequence": 0,
		"location": 4,
		"controller": 0,
	}
	var new_zone_data := {
		"card_id": 40002,
		"sequence": 0,
		"location": 4,
		"controller": 0,
	}
	atomic_zone.show_card(old_zone_data, false)
	var retired_zone_card: CardView = atomic_zone.card_container.get_child(0)
	var retired_zone_external_events: Array[String] = []
	retired_zone_card.card_selected.connect(
		func(_data: Dictionary) -> void: retired_zone_external_events.append("选择")
	)
	retired_zone_card.card_hovered.connect(
		func(_data: Dictionary) -> void: retired_zone_external_events.append("悬浮")
	)
	retired_zone_card.card_unhovered.connect(
		func(_data: Dictionary) -> void: retired_zone_external_events.append("离开")
	)
	atomic_zone.show_card(new_zone_data, false)
	if (
		atomic_zone.card_container.get_child_count() != 1
		or int(atomic_zone.card_container.get_child(0).card_data.card_id)
			!= int(new_zone_data.card_id)
		or retired_zone_card.get_parent() != null
		or !retired_zone_card.disabled
		or retired_zone_card.mouse_filter != Control.MOUSE_FILTER_IGNORE
	):
		_fail("ZoneView 同帧替换后必须立即只保留可输入的新卡")
		return
	retired_zone_card.card_selected.emit(old_zone_data)
	retired_zone_card.card_hovered.emit(old_zone_data)
	retired_zone_card.card_unhovered.emit(old_zone_data)
	if (
		!zone_forwarded_selected.is_empty()
		or !zone_forwarded_hovered.is_empty()
		or !zone_forwarded_unhovered.is_empty()
	):
		_fail("ZoneView 已退休卡牌不得继续向组件转发事件")
		return
	if retired_zone_external_events != ["选择", "悬浮", "离开"]:
		_fail("ZoneView 退休时不得断开卡牌的外部观察者")
		return
	var cleared_zone_card: CardView = atomic_zone.card_container.get_child(0)
	atomic_zone.clear_card()
	if (
		atomic_zone.card_container.get_child_count() != 0
		or cleared_zone_card.get_parent() != null
		or !cleared_zone_card.disabled
		or cleared_zone_card.mouse_filter != Control.MOUSE_FILTER_IGNORE
	):
		_fail("ZoneView 清空卡牌时必须同帧移出并禁用旧卡")
		return
	cleared_zone_card.card_selected.emit(new_zone_data)
	cleared_zone_card.card_hovered.emit(new_zone_data)
	cleared_zone_card.card_unhovered.emit(new_zone_data)
	if (
		!zone_forwarded_selected.is_empty()
		or !zone_forwarded_hovered.is_empty()
		or !zone_forwarded_unhovered.is_empty()
	):
		_fail("ZoneView 清空后的卡牌不得继续向组件转发事件")
		return

	# 决斗场的固定节点、主题和信号绑定属于原生场景契约；交互测试先固定
	# PackedScene 消费方式，Main 的同路径集成由后续迁移任务负责。
	var board: DuelBoard = DUEL_BOARD_SCENE.instantiate()
	_input_viewport = SubViewport.new()
	_input_viewport.size = Vector2i(1920, 1080)
	_input_viewport.gui_disable_input = false
	_input_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_input_viewport)
	_input_viewport.add_child(board)
	await process_frame
	board.battle_action_requested.connect(
		func(kind: String, index: int, selected: Dictionary) -> void:
			_battle_events.append({
				"kind": kind,
				"index": index,
				"card_id": selected.get("card_id", 0),
			})
	)
	board.idle_action_requested.connect(
		func(kind: String, index: int, selected: Dictionary) -> void:
			_idle_events.append({
				"kind": kind,
				"index": index,
				"card_id": selected.get("card_id", 0),
			})
	)
	board.end_turn_requested.connect(func() -> void:
		_end_turn_events.append(true)
	)
	board.restart_requested.connect(func() -> void:
		_restart_events.append(true)
	)
	for required_signal in [
		&"direct_attack_requested",
		&"attack_target_preview_requested",
		&"attack_target_requested",
		&"card_selection_cancel_requested",
		&"yes_no_requested",
		&"effect_yes_no_requested",
		&"place_requested",
	]:
		if !board.has_signal(required_signal):
			_fail("DuelBoard 缺少规则决策信号：" + required_signal)
			return
	board.direct_attack_requested.connect(func() -> void:
		_direct_attack_events.append(true)
	)
	board.attack_target_preview_requested.connect(func(location: Dictionary) -> void:
		_attack_target_preview_events.append(location)
	)
	board.attack_target_requested.connect(func(option_index: int) -> void:
		_attack_target_events.append(option_index)
	)
	board.card_selection_cancel_requested.connect(func() -> void:
		_card_selection_cancel_events.append(true)
	)
	board.yes_no_requested.connect(func(accepted: bool) -> void:
		_yes_no_events.append(accepted)
	)
	board.effect_yes_no_requested.connect(
		func(accepted: bool, generation: int) -> void:
			_effect_yes_no_events.append([accepted, generation])
	)
	board.place_requested.connect(
		func(
			controller: int,
			location: int,
			sequence: int,
			decision_generation: int
		) -> void:
			_place_events.append([
				controller,
				location,
				sequence,
				decision_generation,
			])
	)
	if board.find_child("LegacyActionPanel", true, false) != null:
		_fail("情境式布局不能保留右侧永久操作列")
		return
	for required_name in [
		"FieldStage",
		"HandLayer",
		"HudLayer",
		"OverlayLayer",
		"CardDetailOverlay",
		"ContextActionBar",
		"PhaseButton",
		"SystemTools",
		"StatusToast",
	]:
		if board.find_child(required_name, true, false) == null:
			_fail("情境式布局缺少节点：" + required_name)
			return
	if board.find_child("CardDetailOverlay", true, false).visible:
		_fail("卡片详情浮层默认必须隐藏")
		return
	if board.find_child("ContextActionBar", true, false).visible:
		_fail("情境动作条默认必须隐藏")
		return
	var action_bar: Control = board.find_child("ContextActionBar", true, false)
	var player_hand_control: Control = board.player_hand
	if action_bar.position.y + action_bar.size.y > player_hand_control.position.y:
		_fail(
			"情境动作条不能覆盖玩家手牌：动作条底部 %.1f，手牌顶部 %.1f"
			% [action_bar.position.y + action_bar.size.y, player_hand_control.position.y]
		)
		return
	var status_toast: Control = board.find_child("StatusToast", true, false)
	var opponent_hand_control: Control = board.opponent_hand
	var field_stage: Control = board.find_child("FieldStage", true, false)
	var stable_field_rect := field_stage.get_global_rect()
	if status_toast.get_global_rect().intersects(opponent_hand_control.get_global_rect()):
		_fail("顶部状态提示不能覆盖对手手牌")
		return

	var opponent_monster_0 := {
		"card_id": 10001,
		"controller": 1,
		"location": 4,
		"sequence": 0,
		"cn_name": "对手怪兽甲",
	}
	var opponent_monster_2 := {
		"card_id": 10002,
		"controller": 1,
		"location": 4,
		"sequence": 2,
		"cn_name": "对手怪兽乙",
	}
	var attack_route_snapshot := {
		"decision_kind": "yes_no",
		"decision_description": 31,
		"attack_target_context_supported": true,
		"local_player_turn": true,
		"opponent_monsters": [opponent_monster_0, opponent_monster_2],
	}
	board.render_snapshot(attack_route_snapshot)
	var direct_attack_highlight: Panel = board.find_child(
		"DirectAttackHighlight",
		true,
		false
	)
	var opponent_status_surface: Control = board.find_child(
		"OpponentStatusSurface",
		true,
		false
	)
	if !direct_attack_highlight.visible:
		_fail("直击确认必须高亮真实对手 LP 点击面")
		return
	for sequence in range(board.opponent_monster_zones.size()):
		var expected_preview := sequence in [0, 2]
		var target_highlight: Panel = board.opponent_monster_zones[sequence].target_highlight
		if (
			target_highlight.visible != expected_preview
			or (
				expected_preview
				and target_highlight.theme_type_variation != &"AttackTargetPreview"
			)
		):
			_fail("直击确认只能给有卡的对手怪兽显示预览样式")
			return
	var lp_click := InputEventMouseButton.new()
	lp_click.button_index = MOUSE_BUTTON_LEFT
	lp_click.pressed = true
	opponent_status_surface.gui_input.emit(lp_click)
	if _direct_attack_events.size() != 1:
		_fail("点击真实对手 LP 输入面必须只发一次直击请求")
		return
	board.opponent_monster_zones[0].card_selected.emit(opponent_monster_0)
	if (
		_attack_target_preview_events.size() != 1
		or _attack_target_preview_events[0] != {
			"controller": 1,
			"location": 4,
			"sequence": 0,
		}
		or !_attack_target_events.is_empty()
	):
		_fail("点击怪兽预览必须只转发规则位置，不能提前伪造候选索引")
		return

	var unsupported_card_selection_snapshot := {
		"decision_kind": "select_card",
		"attack_target_context_supported": false,
		"local_player_turn": true,
		"selection_min": 1,
		"selection_max": 1,
		"selection_cancelable": true,
		"phase_kind": "idle",
		"can_enter_battle": true,
		"can_end_turn": true,
		"opponent_monsters": [opponent_monster_0, opponent_monster_2],
		"card_options": [
			{
				"index": 8,
				"controller": 1,
				"location": 4,
				"sequence": 2,
			},
			{
				"index": 9,
				"controller": 0,
				"location": 4,
				"sequence": 0,
			},
		],
	}
	var target_count_before_unsupported := _attack_target_events.size()
	var cancel_count_before_unsupported := _card_selection_cancel_events.size()
	board.render_snapshot(unsupported_card_selection_snapshot)
	for candidate_zone in board.opponent_monster_zones:
		if candidate_zone.target_highlight.visible:
			_fail("混合候选不受支持时不得保留任何可映射子集高亮")
			return
	if (
		board.action_box.visible
		or board.action_box.get_child_count() != 0
		or board.status_label.text
			!= "当前卡牌选择上下文尚未支持：候选无法完整映射为攻击目标"
	):
		_fail("混合候选不受支持时必须只显示中文诊断，不能显示“取消攻击”")
		return
	board.opponent_monster_zones[0].card_selected.emit(opponent_monster_0)
	board.opponent_monster_zones[2].card_selected.emit(opponent_monster_2)
	board._emit_card_selection_cancel()
	if (
		_attack_target_events.size() != target_count_before_unsupported
		or _card_selection_cancel_events.size() != cancel_count_before_unsupported
	):
		_fail("不受支持的混合候选点击与取消不得发出攻击语义信号")
		return

	var card_selection_snapshot := unsupported_card_selection_snapshot.duplicate(true)
	card_selection_snapshot.attack_target_context_supported = true
	card_selection_snapshot.selection_cancelable = false
	card_selection_snapshot.card_options = [{
		"index": 8,
		"controller": 1,
		"location": 4,
		"sequence": 2,
	}]
	board.render_snapshot(card_selection_snapshot)
	for sequence in range(board.opponent_monster_zones.size()):
		var target_highlight: Panel = board.opponent_monster_zones[sequence].target_highlight
		if (
			target_highlight.visible != (sequence == 2)
			or (
				sequence == 2
				and target_highlight.theme_type_variation != &"TargetHighlight"
			)
		):
			_fail("真实候选必须按 controller/location/sequence 精确高亮卡位")
			return
	if board.action_box.visible or board.action_box.get_child_count() != 0:
		_fail("不可取消的目标选择不得显示取消按钮")
		return
	board.opponent_monster_zones[0].card_selected.emit(opponent_monster_0)
	board.opponent_monster_zones[2].card_selected.emit(opponent_monster_2)
	if _attack_target_events != [8] or _attack_target_preview_events.size() != 1:
		_fail("目标选择只能为合法卡位发出 OCGCore 候选索引")
		return

	card_selection_snapshot.selection_cancelable = true
	board.render_snapshot(card_selection_snapshot)
	if (
		!board.action_box.visible
		or board.action_box.get_child_count() != 1
		or str(board.action_box.get_child(0).text) != "取消攻击"
	):
		_fail("可取消目标选择必须只显示“取消攻击”按钮")
		return
	for ordinary_control in [
		board.restart_button,
		board.exit_button,
		board.phase_button,
	]:
		ordinary_control.pressed.emit()
		if (
			board.confirmation_overlay.visible
			or board.confirmation_buttons.get_child_count() != 0
			or !board.opponent_monster_zones[2].target_highlight.visible
			or (
				board.opponent_monster_zones[2].target_highlight.theme_type_variation
				!= &"TargetHighlight"
			)
			or !board.action_box.visible
			or board.action_box.get_child_count() != 1
			or str(board.action_box.get_child(0).text) != "取消攻击"
		):
			_fail("SelectCard 期间普通系统或阶段确认不得覆盖规则目标与取消入口")
			return
	board._handle_surface_click(board.turn_label)
	if (
		!board.action_box.visible
		or board.action_box.get_child_count() != 1
		or str(board.action_box.get_child(0).text) != "取消攻击"
	):
		_fail("可取消目标选择期间点击空白不得清除唯一取消入口")
		return
	board._on_card_selected(card)
	if (
		!board.action_box.visible
		or board.action_box.get_child_count() != 1
		or str(board.action_box.get_child(0).text) != "取消攻击"
	):
		_fail("可取消目标选择期间选择己方卡不得覆盖唯一取消入口")
		return
	var active_rule_cancel_button: Button = board.action_box.get_child(0)
	active_rule_cancel_button.pressed.emit()
	if _card_selection_cancel_events.size() != 1:
		_fail("取消攻击按钮必须发出卡牌选择取消请求")
		return

	board.render_snapshot({
		"decision_kind": "yes_no",
		"decision_description": 99,
		"local_player_turn": true,
		"phase_kind": "idle",
		"can_enter_battle": true,
		"can_end_turn": true,
		"opponent_monsters": [opponent_monster_0],
	})
	var yes_no_texts: Array[String] = []
	for child in board.confirmation_buttons.get_children():
		yes_no_texts.append(str(child.text))
	if (
		!board.confirmation_overlay.visible
		or yes_no_texts != ["是", "否"]
		or direct_attack_highlight.visible
		or board.opponent_monster_zones[0].target_highlight.visible
		or board.action_box.visible
		or board.action_box.get_child_count() != 0
	):
		_fail("新 Yes/No 快照必须清除攻击目标和上一帧取消入口")
		return
	active_rule_cancel_button.pressed.emit()
	if _card_selection_cancel_events.size() != 1:
		_fail("新快照清除的旧取消按钮不得继续发出规则请求")
		return
	for ordinary_control in [
		board.restart_button,
		board.exit_button,
		board.phase_button,
	]:
		ordinary_control.pressed.emit()
		yes_no_texts.clear()
		for child in board.confirmation_buttons.get_children():
			yes_no_texts.append(str(child.text))
		if !board.confirmation_overlay.visible or yes_no_texts != ["是", "否"]:
			_fail("通用 Yes/No 期间普通系统或阶段确认不得覆盖是/否入口")
			return
	board._handle_surface_click(board.turn_label)
	yes_no_texts.clear()
	for child in board.confirmation_buttons.get_children():
		yes_no_texts.append(str(child.text))
	if !board.confirmation_overlay.visible or yes_no_texts != ["是", "否"]:
		_fail("通用 Yes/No 期间点击战场空白不得清除是/否入口")
		return
	board.confirmation_buttons.get_child(0).pressed.emit()
	if _yes_no_events != [true]:
		_fail("通用 Yes/No 的“是”必须原样发出 true")
		return
	board.render_snapshot({
		"decision_kind": "yes_no",
		"decision_description": 99,
		"local_player_turn": true,
	})
	var background: Control = board.find_child("Background", true, false)
	background.gui_input.emit(lp_click)
	yes_no_texts.clear()
	for child in board.confirmation_buttons.get_children():
		yes_no_texts.append(str(child.text))
	if !board.confirmation_overlay.visible or yes_no_texts != ["是", "否"]:
		_fail("通用 Yes/No 期间背景输入不得清除是/否入口")
		return
	board.confirmation_buttons.get_child(1).pressed.emit()
	if _yes_no_events != [true, false]:
		_fail("通用 Yes/No 的“否”必须原样发出 false")
		return

	var effect_snapshot := {
		"decision_kind": "effect_yes_no",
		"local_player_turn": true,
		"effect_card_name": "青眼白龙",
		"effect_card_id": 89631139,
		"effect_controller": 0,
		"effect_location": 4,
		"effect_sequence": 0,
		"effect_position": 1,
	}
	board.render_snapshot(effect_snapshot)
	var effect_generation: int = board._rule_decision_generation
	if (
		board._rule_decision_kind != "effect_yes_no"
		or !board.confirmation_overlay.visible
		or board.confirmation_label.text != "是否发动「青眼白龙」的效果？"
		or board.confirmation_buttons.get_child_count() != 2
		or board.confirmation_buttons.get_child(0).text != "发动"
		or board.confirmation_buttons.get_child(1).text != "不发动"
		or board.status_label.text != "请选择是否发动卡片效果"
	):
		_fail("EffectYesNo 必须显示独立的情境确认和首次等待提示")
		return
	board.confirmation_buttons.get_child(1).pressed.emit()
	if _effect_yes_no_events != [[false, effect_generation]]:
		_fail("EffectYesNo 必须携带当前代次独立提交“不发动”")
		return
	board.render_snapshot(effect_snapshot)
	var next_effect_generation: int = board._rule_decision_generation
	board._emit_effect_yes_no(true, effect_generation)
	if (
		next_effect_generation == effect_generation
		or _effect_yes_no_events.size() != 1
	):
		_fail("旧代次 EffectYesNo 入口不得提交新快照")
		return

	board.render_snapshot(attack_route_snapshot)
	board.render_snapshot({
		"decision_kind": "yes_no",
		"decision_description": 31,
		"local_player_turn": false,
		"opponent_monsters": [opponent_monster_0],
	})
	if (
		direct_attack_highlight.visible
		or board.opponent_monster_zones[0].target_highlight.visible
		or board.confirmation_overlay.visible
		or board.action_box.visible
		or board.action_box.get_child_count() != 0
	):
		_fail("新快照或终局状态必须立即清除全部决策表现与动态按钮")
		return

	# 真实 Bridge 会隐藏对手场上卡的 card_id，CardView 因而以卡背展示。攻击规则
	# 仍必须允许该真实按钮发出卡位语义；不能只在测试中直接 emit ZoneView 信号，
	# 否则运行时预览看似可点却永远到不了 Main。
	var hidden_opponent_monster := {
		"location": 4,
		"sequence": 0,
		"position": 1,
	}
	var hidden_negative_preview_count := _attack_target_preview_events.size()
	var hidden_negative_target_count := _attack_target_events.size()
	for hidden_inactive_snapshot in [
		{
			"decision_kind": "idle",
			"local_player_turn": true,
			"opponent_monsters": [hidden_opponent_monster],
		},
		{
			"decision_kind": "yes_no",
			"decision_description": 31,
			"local_player_turn": false,
			"opponent_monsters": [hidden_opponent_monster],
		},
	]:
		board.render_snapshot(hidden_inactive_snapshot)
		var hidden_inactive_card: CardView = (
			board.opponent_monster_zones[0].card_container.get_child(0)
		)
		hidden_inactive_card.pressed.emit()
	if (
		_attack_target_preview_events.size() != hidden_negative_preview_count
		or _attack_target_events.size() != hidden_negative_target_count
	):
		_fail("普通浏览或非本地快照点击隐藏身份怪兽不得发出规则请求")
		return
	board.render_snapshot({
		"decision_kind": "yes_no",
		"decision_description": 31,
		"attack_target_context_supported": true,
		"local_player_turn": true,
		"opponent_monsters": [hidden_opponent_monster],
	})
	var hidden_preview_card: CardView = (
		board.opponent_monster_zones[0].card_container.get_child(0)
	)
	var preview_count_before := _attack_target_preview_events.size()
	hidden_preview_card.pressed.emit()
	if (
		!hidden_preview_card.face_down
		or _attack_target_preview_events.size() != preview_count_before + 1
		or _attack_target_preview_events.back() != {
			"controller": 1,
			"location": 4,
			"sequence": 0,
		}
	):
		_fail("隐藏身份的对手怪兽按钮必须能提交攻击目标预览规则位置")
		return
	board.render_snapshot({
		"decision_kind": "select_card",
		"attack_target_context_supported": true,
		"local_player_turn": true,
		"selection_min": 1,
		"selection_max": 1,
		"opponent_monsters": [hidden_opponent_monster],
		"card_options": [{
			"index": 44,
			"controller": 1,
			"location": 4,
			"sequence": 0,
		}],
	})
	var hidden_target_card: CardView = (
		board.opponent_monster_zones[0].card_container.get_child(0)
	)
	var target_count_before := _attack_target_events.size()
	hidden_preview_card.pressed.emit()
	if (
		_attack_target_preview_events.size() != preview_count_before + 1
		or _attack_target_events.size() != target_count_before
	):
		_fail("新快照替换后，隐藏身份的旧怪兽按钮不得继续发出任何规则请求")
		return
	hidden_target_card.pressed.emit()
	if (
		!hidden_target_card.face_down
		or _attack_target_events.size() != target_count_before + 1
		or int(_attack_target_events.back()) != 44
	):
		_fail("隐藏身份的真实合法目标按钮必须提交当前 OCGCore 候选索引")
		return

	var matching_action := {
		"card_id": 89631139,
		"sequence": 2,
		"location": 2,
		"controller": 0,
		"action_kind": "normal_summon",
		"index": 7,
	}
	var wrong_card_action := matching_action.duplicate()
	wrong_card_action.card_id = 1
	var wrong_sequence_action := matching_action.duplicate()
	wrong_sequence_action.sequence = 3
	var wrong_location_action := matching_action.duplicate()
	wrong_location_action.location = 4
	var wrong_controller_action := matching_action.duplicate()
	wrong_controller_action.controller = 1
	board.render_snapshot({
		"player_hand": [card],
		"idle_actions": [
			matching_action,
			wrong_card_action,
			wrong_sequence_action,
			wrong_location_action,
			wrong_controller_action,
		],
		"local_player_turn": true,
		"can_end_turn": true,
	})
	board._preview_card(card)
	board._on_card_selected(card)
	if !action_bar.visible or action_bar.get_child_count() != 2:
		_fail("情境动作条必须只保留四字段精确匹配动作及取消按钮")
		return
	if str(action_bar.get_child(0).text) != "通常召唤":
		_fail("情境动作条生成了错误动作")
		return
	var retired_action_button: Button = action_bar.get_child(0)
	var replacement_action := matching_action.duplicate()
	replacement_action.action_kind = "monster_set"
	replacement_action.index = 9
	board.current_actions = [replacement_action]
	board._on_card_selected(card)
	var rebuilt_action_texts: Array = []
	for child in action_bar.get_children():
		rebuilt_action_texts.append(str(child.text))
	if rebuilt_action_texts != ["怪兽盖放", "取消"]:
		_fail("同帧重建动作条后必须立即只保留最新动作和取消按钮")
		return
	if retired_action_button.get_parent() != null:
		_fail("同帧重建动作条时旧按钮必须立即脱离容器")
		return
	retired_action_button.pressed.emit()
	if !_idle_events.is_empty():
		_fail("已替换的动作按钮不得继续触发旧动作回调")
		return
	board._on_card_selected({})
	if !board.detail_overlay.visible:
		_fail("取消锁定后，鼠标仍悬停时必须保留临时详情")
		return
	board._handle_surface_click(board.turn_label)
	if board.detail_overlay.visible:
		_fail("点击中央战场空白必须关闭卡片详情")
		return
	board._open_confirmation("end_turn", "确定结束当前回合？")
	board._handle_surface_click(board.turn_label)
	if board.confirmation_overlay.visible:
		_fail("点击确认浮层外必须关闭确认框")
		return
	board.render_snapshot({
		"player_hand": [card],
		"idle_actions": [matching_action],
		"local_player_turn": false,
		"can_end_turn": false,
	})
	await process_frame
	if action_bar.visible or action_bar.get_child_count() != 0:
		_fail("新快照必须销毁旧动作按钮")
		return
	if !board.phase_button.disabled:
		_fail("对手回合必须禁用阶段按钮")
		return

	var field_card := card.duplicate()
	field_card.location = 4
	field_card.sequence = 0
	var battle_snapshot := {
		"player_monsters": [field_card],
		"idle_actions": [{
			"card_id": field_card.card_id,
			"sequence": 0,
			"location": 4,
			"controller": 0,
			"action_kind": "attack",
			"index": 7,
		}],
		"local_player_turn": true,
		"phase_kind": "battle",
		"can_enter_main2": true,
		"can_end_battle": true,
	}
	board.render_snapshot(battle_snapshot)
	board.player_monster_zones[0].card_selected.emit(field_card)
	var selected_field_card: CardView = (
		board.player_monster_zones[0].card_container.get_child(0)
	)
	if !selected_field_card.selected or !selected_field_card.selection_frame.visible:
		_fail("选择场上怪兽时必须显示 CardView 选择框")
		return
	board.render_snapshot(battle_snapshot)
	await process_frame
	var refreshed_field_card: CardView = (
		board.player_monster_zones[0].card_container.get_child(0)
	)
	if (
		!board.selected_card.is_empty()
		or refreshed_field_card.selected
		or refreshed_field_card.selection_frame.visible
	):
		_fail("新快照必须清除场上怪兽的选择视觉")
		return
	board.player_monster_zones[0].card_selected.emit(field_card)
	if !action_bar.visible or str(action_bar.get_child(0).text) != "攻击":
		_fail("战斗阶段必须在场上怪兽旁显示真实攻击动作")
		return
	action_bar.get_child(0).pressed.emit()
	if (
		_battle_events.size() != 1
		or str(_battle_events[0].kind) != "attack"
		or int(_battle_events[0].index) != 7
	):
		_fail("攻击按钮必须原样转发动作类型和 OCGCore 类别内索引")
		return
	board._on_phase_pressed()
	if !board.confirmation_overlay.visible:
		_fail("阶段按钮必须显示真实可用阶段选项")
		return
	var phase_option_texts: Array = []
	for child in board.confirmation_buttons.get_children():
		phase_option_texts.append(str(child.text))
	if !phase_option_texts.has("进入主要阶段二") or !phase_option_texts.has("结束战斗阶段"):
		_fail("战斗阶段选项必须来自 OCGCore 能力")
		return
	board._open_phase_options([{"kind": "end_turn", "text": "结束回合"}])
	var retired_phase_button: Button = board.confirmation_buttons.get_child(0)
	board._open_confirmation("restart", "确定重新开局？")
	var rebuilt_confirmation_texts: Array = []
	for child in board.confirmation_buttons.get_children():
		rebuilt_confirmation_texts.append(str(child.text))
	if rebuilt_confirmation_texts != ["确认", "取消"]:
		_fail("同帧重建确认选项后必须立即只保留最新按钮")
		return
	if retired_phase_button.get_parent() != null:
		_fail("同帧重建确认选项时旧按钮必须立即脱离容器")
		return
	retired_phase_button.pressed.emit()
	if !_end_turn_events.is_empty():
		_fail("已替换的阶段按钮不得继续触发旧阶段回调")
		return
	var retired_confirm_button: Button = board.confirmation_buttons.get_child(0)
	board._close_confirmation()
	if board.confirmation_buttons.get_child_count() != 0:
		_fail("关闭确认层时必须立即清空动态按钮")
		return
	if retired_confirm_button.get_parent() != null:
		_fail("关闭确认层时确认按钮必须立即脱离容器")
		return
	retired_confirm_button.pressed.emit()
	if !_restart_events.is_empty():
		_fail("已关闭确认层的按钮不得继续触发确认回调")
		return

	# 区域选择只消费 OCGCore 的语义三元组，四组原生 ZoneView 必须先全部映射
	# 且确认为空，再原子发布高亮。该测试会在缺失 PlaceCandidate 与代次入口时
	# 失败，并能捕获“先高亮可映射子集、遇到坏候选才停止”的错误实现。
	var place_snapshot := {
		"decision_kind": "select_place",
		"local_player_turn": true,
		"player_monsters": [],
		"player_spells": [],
		"opponent_monsters": [],
		"opponent_spells": [],
		"place_options": [
			{"controller": 0, "location": 4, "sequence": 0},
			{"controller": 0, "location": 8, "sequence": 1},
			{"controller": 1, "location": 4, "sequence": 2},
			{"controller": 1, "location": 8, "sequence": 3},
		],
	}
	board.render_snapshot(place_snapshot)
	var place_generation: int = board._rule_decision_generation
	if board.status_label.text != "请选择放置区域":
		_fail("SelectPlace 首次等待必须显示“请选择放置区域”")
		return
	var place_candidate_zones: Array[ZoneView] = [
		board.player_monster_zones[0],
		board.player_spell_zones[1],
		board.opponent_monster_zones[2],
		board.opponent_spell_zones[3],
	]
	for candidate_zone in place_candidate_zones:
		if (
			!candidate_zone.target_highlight.visible
			or candidate_zone.target_highlight.theme_type_variation != &"PlaceCandidate"
		):
			_fail("合法空卡位必须使用 PlaceCandidate 原生主题变体")
			return
	for non_candidate_zone in [
		board.player_monster_zones[1],
		board.player_spell_zones[0],
		board.opponent_monster_zones[0],
		board.opponent_spell_zones[0],
	]:
		if non_candidate_zone.target_highlight.visible:
			_fail("非候选卡位不得显示区域选择高亮")
			return

	# 所有点击都从 SubViewport 进入真实 GUI 命中链，不能直接 emit
	# gui_input 或 Button.pressed，否则无法发现覆盖层、mouse_filter 与坐标错误。
	await _viewport_click(board.player_monster_zones[1])
	await _viewport_click_position(Vector2(4, 4))
	if !_place_events.is_empty():
		_fail("非候选卡位或背景的真实点击不得发出区域请求")
		return
	await _viewport_click(board.opponent_spell_zones[3], true)
	if (
		!_place_events.is_empty()
		or !board.opponent_spell_zones[3].target_highlight.visible
	):
		_fail("double_click=true 的真实输入不得消费活动区域候选")
		return
	await _viewport_click(board.opponent_spell_zones[3])
	if _place_events != [[1, 8, 3, place_generation]]:
		_fail(
			"区域点击必须原样发出 controller/location/sequence 与当前代次；"
			+ "实际事件=%s，候选矩形=%s，悬浮控件=%s"
			% [
				_place_events,
				board.opponent_spell_zones[3].get_global_rect(),
				_input_viewport.gui_get_hovered_control(),
			]
		)
		return
	for candidate_zone in place_candidate_zones:
		if candidate_zone.target_highlight.visible:
			_fail("第一次区域点击必须立即退休本代全部候选入口")
			return
	# 同帧双击和旧代次信号都只能观察到已退休入口；不能把同一规则响应发两次。
	await _viewport_click(board.opponent_spell_zones[3])
	board.opponent_spell_zones[3].place_requested.emit(place_generation)
	if _place_events.size() != 1:
		_fail("区域候选双击或退休节点不得发出第二次请求")
		return

	# MSG_RETRY 仍是同一决策代次，但必须以同一份候选重新建立原生高亮。
	board.render_snapshot(place_snapshot, true)
	if (
		board._rule_decision_generation != place_generation
		or !board.player_monster_zones[0].target_highlight.visible
	):
		_fail("区域选择 Retry 必须保留代次并重建全部候选")
		return
	board.render_snapshot(place_snapshot)
	if board._rule_decision_generation != place_generation + 1:
		_fail("正常新区域快照必须推进决策代次")
		return
	board.player_monster_zones[0].place_requested.emit(place_generation)
	if _place_events.size() != 1:
		_fail("上一代 ZoneView 信号不得提交当前区域决策")
		return

	var occupied_place_snapshot := place_snapshot.duplicate(true)
	occupied_place_snapshot.player_monsters = [{
		"card_id": 700001,
		"location": 4,
		"sequence": 0,
		"cn_name": "占位测试怪兽",
	}]
	board.render_snapshot(occupied_place_snapshot)
	for zone_with_occupied_candidate in place_candidate_zones:
		if zone_with_occupied_candidate.target_highlight.visible:
			_fail("任一候选已占用时必须原子隐藏全部区域候选")
			return
	var occupied_card: CardView = board.player_monster_zones[0].card_container.get_child(0)
	await _viewport_click(occupied_card)
	if (
		_place_events.size() != 1
		or int(board.selected_card.get("card_id", 0)) != 700001
		or !occupied_card.selected
	):
		_fail("已占用卡位真实点击不得放置，且必须保留原 CardView 选择行为")
		return

	for malformed_option in [
		{"controller": 0, "location": 4, "sequence": 5},
		{"controller": 0, "location": 16, "sequence": 0},
	]:
		var malformed_place_snapshot := place_snapshot.duplicate(true)
		malformed_place_snapshot.place_options.append(malformed_option)
		board.render_snapshot(malformed_place_snapshot)
		for malformed_candidate_zone in place_candidate_zones:
			if malformed_candidate_zone.target_highlight.visible:
				_fail("越界 sequence 或未知 location 必须原子隐藏全部候选")
				return

		# 无法映射时 OCGCore 没有可点击响应入口，重开与退出必须作为本地系统
		# 脱困路径继续可用；取消确认不能消费或改写当前规则等待状态。
		await _viewport_click(board.restart_button)
		if (
			!board.confirmation_overlay.visible
			or board._rule_decision_kind != "select_place_unmapped"
		):
			_fail("区域候选无法映射时必须仍能打开重开确认")
			return
		await _viewport_click(board.confirmation_buttons.get_child(1))
		if (
			board.confirmation_overlay.visible
			or board._rule_decision_kind != "select_place_unmapped"
		):
			_fail("取消重开确认不得消费无法映射的区域决策")
			return
		await _viewport_click(board.exit_button)
		if (
			!board.confirmation_overlay.visible
			or board._rule_decision_kind != "select_place_unmapped"
		):
			_fail("区域候选无法映射时必须仍能打开退出确认")
			return
		await _viewport_click(board.confirmation_buttons.get_child(1))

	var empty_place_snapshot := place_snapshot.duplicate(true)
	empty_place_snapshot.place_options = []
	board.render_snapshot(empty_place_snapshot)
	var empty_generation: int = board._rule_decision_generation
	await _viewport_click(board.player_monster_zones[0])
	board.player_monster_zones[0].place_requested.emit(empty_generation)
	if _place_events.size() != 1 or _has_place_highlight(board):
		_fail("空区域候选不得显示或提交，且旧 ZoneView 信号必须失效")
		return

	board.render_snapshot(place_snapshot)
	board.render_snapshot({
		"decision_kind": "select_place",
		"local_player_turn": false,
		"place_options": place_snapshot.place_options,
	})
	for terminal_candidate_zone in place_candidate_zones:
		if terminal_candidate_zone.target_highlight.visible:
			_fail("终局或非本地快照必须清除区域候选高亮")
			return

	var main = MAIN_SCRIPT.new()
	main.bridge = FakeBridge.new()
	main.board = board
	main._refresh_board("测试本地回合能力")
	if board.confirmation_overlay.visible:
		_fail("新快照必须关闭旧阶段选项")
		return
	if board.find_child("PhaseButton", true, false).disabled:
		_fail("Main 必须把本地回合和可结束回合能力写入快照")
		return
	if !"LP 7600" in board.player_stats_label.text or !"LP 4200" in board.opponent_stats_label.text:
		_fail("Main 必须显示桥接层提供的真实双方生命值")
		return
	main.bridge.game_over = true
	main.bridge.winner = 0
	main.bridge.win_reason = 1
	main.bridge.idle_actions = [matching_action]
	main._refresh_board("这条提示必须被终局状态覆盖")
	if board.status_label.text != "对局结束：玩家1获胜":
		_fail("Main 必须用桥接层胜负状态覆盖普通操作提示")
		return
	if !board.phase_button.disabled:
		_fail("对局结束后必须禁用阶段操作")
		return
	board._on_card_selected(card)
	if action_bar.visible:
		_fail("对局结束后不能再显示卡牌动作")
		return

	var real_bridge = YgoCoreBridge.new()
	var initialized: Dictionary = real_bridge.initialize_card_database(
		ProjectSettings.globalize_path("res://")
	)
	if !initialized.ok:
		_fail("本地玩家门禁测试无法初始化真实卡库：" + str(initialized.message))
		return
	var scripted_ids: PackedInt64Array = real_bridge.get_scripted_card_ids()
	var setup: Dictionary = real_bridge.setup_duel(scripted_ids, scripted_ids, 0x4c4f43414c)
	if !setup.ok:
		_fail("本地玩家门禁测试无法建立真实决斗：" + str(setup.message))
		return
	var first_end: Dictionary = real_bridge.submit_end_turn()
	var next_pending: Dictionary = real_bridge.get_pending_action()
	if !first_end.ok or int(next_pending.player) != 0:
		_fail("确定性对手必须自动结束回合并返回本地玩家决策")
		return
	var continued_state: Dictionary = real_bridge.get_duel_state()
	if (
		int(continued_state.players.p1.deck) != 34
		or int(continued_state.players.p1.hand) != 6
		or int(continued_state.players.p1.lp) != 8000
		or int(continued_state.players.p2.lp) != 8000
	):
		_fail("连续回合快照没有反映双方抽牌与真实生命值")
		return
	real_bridge.destroy_duel()

	# 上述用例依次打开动作条、位置选择、连锁、EffectYN 与确认层。它们只能
	# 覆盖于棋盘上方，不能像旧 VBox 那样参与行高分配并挤压场地；系统脱困
	# 入口也必须始终可用。
	if (
		!field_stage.get_global_rect().is_equal_approx(stable_field_rect)
		or board.restart_button.disabled
		or board.exit_button.disabled
	):
		_fail("规则浮层不得改变棋盘矩形或禁用重开、退出入口")
		return

	main.free()
	hand.queue_free()
	zone.queue_free()
	atomic_hand.queue_free()
	atomic_zone.queue_free()
	board.queue_free()
	_input_viewport.queue_free()
	await process_frame
	await process_frame
	print("情境式决斗界面交互契约通过")
	quit(0)


func _has_place_highlight(board: DuelBoard) -> bool:
	for zone in (
		board.player_monster_zones
		+ board.player_spell_zones
		+ board.opponent_monster_zones
		+ board.opponent_spell_zones
	):
		if (
			zone.target_highlight.visible
			and zone.target_highlight.theme_type_variation == &"PlaceCandidate"
		):
			return true
	return false


func _viewport_click(control: Control, double_click := false) -> void:
	await _viewport_click_position(
		control.get_global_rect().get_center(),
		double_click
	)


func _viewport_click_position(position: Vector2, double_click := false) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	_input_viewport.push_input(motion)
	await process_frame
	var press := InputEventMouseButton.new()
	press.position = position
	press.global_position = position
	press.button_index = MOUSE_BUTTON_LEFT
	press.button_mask = MOUSE_BUTTON_MASK_LEFT
	press.pressed = true
	press.double_click = double_click
	_input_viewport.push_input(press)
	await process_frame
	var release := InputEventMouseButton.new()
	release.position = position
	release.global_position = position
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.double_click = double_click
	_input_viewport.push_input(release)
	await process_frame


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
