extends SceneTree

const CARD_SCENE_PATH := "res://src/ui/card_view.tscn"
const THEME_PATH := "res://src/ui/themes/duel_theme.tres"
const ZONE_SCENE_PATH := "res://src/ui/zone_view.tscn"
const HAND_SCENE_PATH := "res://src/ui/hand_view.tscn"
const BOARD_SCENE_PATH := "res://src/duel/duel_board.tscn"


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
	for node_name in ["SelectionFrame", "CardBackPanel", "FaceDownLabel", "AnimationPlayer"]:
		if card.find_child(node_name, true, false) == null:
			_fail("CardView 缺少固定节点：" + node_name)
			return
	var animator: AnimationPlayer = card.find_child("AnimationPlayer", true, false)
	for animation_name in ["hover_in", "hover_out", "select", "reset"]:
		if !animator.has_animation(animation_name):
			_fail("CardView 缺少动画：" + animation_name)
			return
	var card_back: Panel = card.find_child("CardBackPanel", true, false)
	var face_down_label: Label = card.find_child("FaceDownLabel", true, false)
	card.configure({}, true)
	if !card_back.visible or !face_down_label.visible:
		_fail("CardView 卡背模式必须显示原生卡背视觉和文字")
		return
	if face_down_label.text != "卡背":
		_fail("CardView 卡背文字必须使用简体中文")
		return
	card.configure({}, false)
	if card_back.visible or face_down_label.visible:
		_fail("CardView 正面模式必须隐藏卡背视觉和文字")
		return
	card.queue_free()
	await process_frame
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
	if board.theme == null or board.theme.resource_path != THEME_PATH:
		_fail("DuelBoard 根节点必须直接应用决斗界面 Theme")
		return
	for hand_name in ["OpponentHand", "PlayerHand"]:
		var board_hand = board.find_child(hand_name, true, false)
		if board_hand.scene_file_path != HAND_SCENE_PATH:
			_fail("DuelBoard 手牌节点必须来自 HandView 原生场景：" + hand_name)
			return
	for row_name in [
		"OpponentSpellRow",
		"OpponentMonsterRow",
		"PlayerMonsterRow",
		"PlayerSpellRow",
	]:
		var row = board.find_child(row_name, true, false)
		if row.get_child_count() != 5:
			_fail("DuelBoard 每个区域行必须固定包含五个卡位：" + row_name)
			return
		for board_zone in row.get_children():
			if board_zone.scene_file_path != ZONE_SCENE_PATH:
				_fail("DuelBoard 卡位必须来自 ZoneView 原生场景：" + row_name)
				return
	var board_source := FileAccess.get_file_as_string(
		ProjectSettings.globalize_path("res://src/duel/duel_board.gd")
	)
	if board_source.is_empty():
		_fail("无法读取 DuelBoard 脚本以检查固定界面工厂")
		return
	for forbidden_factory in [
		"_build_interface",
		"_build_battlefield",
		"_add_zone_row",
		"_build_player_status",
		"_make_corner_status",
		"_build_card_detail_overlay",
		"_build_context_action_bar",
		"_build_phase_control",
		"_build_system_tools",
		"_make_tool_button",
		"_build_status_toast",
		"_build_confirmation_overlay",
		"_build_debug_overlay",
		"_panel_style",
		"_round_button_style",
	]:
		if board_source.contains(forbidden_factory):
			_fail("DuelBoard 不得保留固定界面工厂：" + forbidden_factory)
			return
	var opponent_card := {
		"card_id": 89631139,
		"sequence": 0,
		"location": 4,
		"controller": 0,
		"cn_name": "对手区域选择门禁测试",
	}
	board.current_actions = [{
		"card_id": opponent_card.card_id,
		"sequence": opponent_card.sequence,
		"location": opponent_card.location,
		"controller": 0,
		"action_kind": "attack",
		"index": 0,
	}]
	var opponent_action_requests: Array = []
	board.idle_action_requested.connect(
		func(_kind: String, _index: int, _card_data: Dictionary) -> void:
			opponent_action_requests.append(true)
	)
	board.battle_action_requested.connect(
		func(_kind: String, _index: int, _card_data: Dictionary) -> void:
			opponent_action_requests.append(true)
	)
	board.opponent_monster_zones[0].card_selected.emit(opponent_card)
	if (
		!board.selected_card.is_empty()
		or board.action_box.visible
		or board.action_box.get_child_count() != 0
		or !opponent_action_requests.is_empty()
	):
		_fail("对手区域不得向 DuelBoard 转发卡牌选择")
		return
	board.queue_free()
	await process_frame
	for scene_path in [ZONE_SCENE_PATH, HAND_SCENE_PATH]:
		if !ResourceLoader.exists(scene_path):
			_fail("缺少原生子场景：" + scene_path)
			return
	var preconfigured_zone = load(ZONE_SCENE_PATH).instantiate()
	# DuelBoard 会先配置区域标题、再把区域加入战场容器；场景就绪后必须回填这项缓存数据。
	preconfigured_zone.configure("测试区域")
	root.add_child(preconfigured_zone)
	await process_frame
	var preconfigured_title: Label = preconfigured_zone.find_child("TitleLabel", true, false)
	if preconfigured_title.text != "测试区域":
		_fail("ZoneView 必须在入树后回填预先配置的区域标题")
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
	print("Godot 原生场景契约通过")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
