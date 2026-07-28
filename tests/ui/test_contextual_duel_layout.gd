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
	root.add_child(board)
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
	if board.find_child("LegacyActionPanel", true, false) != null:
		_fail("情境式布局不能保留右侧永久操作列")
		return
	for required_name in [
		"Battlefield",
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

	var card_selection_snapshot := {
		"decision_kind": "select_card",
		"local_player_turn": true,
		"selection_min": 1,
		"selection_max": 1,
		"selection_cancelable": false,
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
	board.action_box.get_child(0).pressed.emit()
	if _card_selection_cancel_events.size() != 1:
		_fail("取消攻击按钮必须发出卡牌选择取消请求")
		return

	board.render_snapshot({
		"decision_kind": "yes_no",
		"decision_description": 99,
		"local_player_turn": true,
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
	):
		_fail("通用 Yes/No 必须使用确认层，且不得显示攻击目标")
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
	board.confirmation_buttons.get_child(1).pressed.emit()
	if _yes_no_events != [true, false]:
		_fail("通用 Yes/No 的“否”必须原样发出 false")
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

	main.free()
	hand.queue_free()
	zone.queue_free()
	atomic_hand.queue_free()
	atomic_zone.queue_free()
	board.queue_free()
	await process_frame
	await process_frame
	print("情境式决斗界面交互契约通过")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
