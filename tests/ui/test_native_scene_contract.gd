extends SceneTree

const CARD_SCENE_PATH := "res://src/ui/card_view.tscn"
const THEME_PATH := "res://src/ui/themes/duel_theme.tres"
const ZONE_SCENE_PATH := "res://src/ui/zone_view.tscn"
const HAND_SCENE_PATH := "res://src/ui/hand_view.tscn"
const BOARD_SCENE_PATH := "res://src/duel/duel_board.tscn"
const MAIN_SCENE_PATH := "res://src/main/main.tscn"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# Main 必须在场景资源中持有 DuelBoard，保证编辑器布局、Theme 与节点生命周期
	# 同真实运行时一致；禁止脚本以裸节点方式绕过原生场景。
	var main = load(MAIN_SCENE_PATH).instantiate()
	var main_board = main.find_child("DuelBoard", true, false)
	if main_board == null or main_board.scene_file_path != BOARD_SCENE_PATH:
		_fail("Main 必须直接实例化 DuelBoard 原生场景")
		return
	main.free()
	var main_source := FileAccess.get_file_as_string(
		ProjectSettings.globalize_path("res://src/main/main.gd")
	)
	if main_source.contains("DUEL_BOARD_SCRIPT.new()"):
		_fail("Main 不得继续在运行时创建 DuelBoard")
		return
	if !ResourceLoader.exists(THEME_PATH):
		_fail("缺少决斗界面 Theme 资源")
		return
	if !ResourceLoader.exists(CARD_SCENE_PATH):
		_fail("缺少 CardView 原生场景")
		return
	var card = load(CARD_SCENE_PATH).instantiate()
	root.add_child(card)
	await process_frame
	for node_name in [
		"SelectionFrame",
		"CardBackPanel",
		"FaceDownLabel",
		"FaceUpPlaceholder",
		"MissingImageLabel",
		"AnimationPlayer",
	]:
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
	var face_up_placeholder: Panel = card.find_child("FaceUpPlaceholder", true, false)
	var missing_image_label: Label = card.find_child("MissingImageLabel", true, false)
	var duel_theme: Theme = load(THEME_PATH)
	if (
		face_up_placeholder.theme_type_variation != &"CardImagePlaceholder"
		or !duel_theme.has_stylebox(&"panel", &"CardImagePlaceholder")
		or missing_image_label.theme_type_variation != &"CardImagePlaceholderLabel"
		or !duel_theme.has_color(&"font_color", &"CardImagePlaceholderLabel")
		or !duel_theme.has_font_size(&"font_size", &"CardImagePlaceholderLabel")
	):
		_fail("CardView 正面缺图占位及文字必须消费 duel_theme.tres 的样式")
		return
	card.configure({"image_path": "res://不存在的卡图.png"}, false)
	if (
		!face_up_placeholder.visible
		or !missing_image_label.is_visible_in_tree()
		or missing_image_label.text != "缺少卡图"
		or card.texture_normal != null
		or card_back.visible
		or face_down_label.visible
	):
		_fail("CardView 正面缺图时必须显示中文原生占位")
		return
	card.configure(
		{"image_path": "res://third_party/godot-cpp/test/project/icon.png"},
		false
	)
	if (
		face_up_placeholder.visible
		or card.texture_normal == null
		or card_back.visible
		or face_down_label.visible
	):
		_fail("CardView 正面卡图有效时必须隐藏缺图占位并显示纹理")
		return
	card.configure({}, true)
	if (
		!card_back.visible
		or !face_down_label.visible
		or face_up_placeholder.visible
		or card.texture_normal != null
	):
		_fail("CardView 卡背模式必须显示原生卡背视觉和文字")
		return
	if face_down_label.text != "卡背":
		_fail("CardView 卡背文字必须使用简体中文")
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
		"Background", "SafeArea", "FieldStage", "HandLayer", "HudLayer",
		"OverlayLayer", "OpponentField", "PlayerField", "SpecialZoneLayer",
		"OpponentExtraMonsterZoneLeft", "OpponentExtraMonsterZoneRight",
		"PlayerDeckSlot", "PlayerExtraDeckSlot", "PlayerGraveyardSlot",
		"OpponentDeckSlot", "OpponentExtraDeckSlot", "OpponentGraveyardSlot",
		"OpponentHand",
		"OpponentSpellRow", "OpponentMonsterRow", "TurnLabel",
		"PlayerMonsterRow", "PlayerSpellRow", "PlayerHand",
		"OpponentStatusSurface", "OpponentStatus", "DirectAttackHighlight",
		"PlayerStatus", "PhaseButton", "SystemTools",
		"StatusToast", "CardDetailOverlay", "ContextActionBar",
		"ConfirmationOverlay", "DebugOverlay", "AnimationPlayer",
	]:
		if board.find_child(node_name, true, false) == null:
			_fail("DuelBoard 缺少固定节点：" + node_name)
			return
	for reserved_zone_name in [
		"OpponentExtraMonsterZoneLeft",
		"OpponentExtraMonsterZoneRight",
		"PlayerDeckSlot",
		"PlayerExtraDeckSlot",
		"PlayerGraveyardSlot",
		"OpponentDeckSlot",
		"OpponentExtraDeckSlot",
		"OpponentGraveyardSlot",
	]:
		var reserved_zone := board.find_child(reserved_zone_name, true, false) as Control
		if reserved_zone.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			_fail("尚无 C++ 语义的预留区域必须忽略输入：" + reserved_zone_name)
			return
	# 棋盘、手牌、HUD 与规则浮层必须是兄弟层。这样显示确认框或改变手牌数量
	# 时不会参与四排场地的 Container 尺寸分配，场地几何才能保持稳定。
	var safe_area: Control = board.find_child("SafeArea", true, false)
	var field_stage: Control = board.find_child("FieldStage", true, false)
	var hand_layer: Control = board.find_child("HandLayer", true, false)
	var hud_layer: Control = board.find_child("HudLayer", true, false)
	var overlay_layer: Control = board.find_child("OverlayLayer", true, false)
	if (
		field_stage.get_parent() != safe_area
		or hand_layer.get_parent() != safe_area
		or hud_layer.get_parent() != safe_area
		or overlay_layer.get_parent() != safe_area
	):
		_fail("棋盘、手牌、HUD 与规则浮层必须是 SafeArea 下的独立兄弟层")
		return
	if (
		board.find_child("PlayerHand", true, false).get_parent() != hand_layer
		or board.find_child("OpponentHand", true, false).get_parent() != hand_layer
		or board.find_child("PlayerMonsterRow", true, false).get_parent().name
				!= "PlayerField"
		or board.find_child("OpponentMonsterRow", true, false).get_parent().name
				!= "OpponentField"
		or board.find_child("PhaseButton", true, false).get_parent().name
				!= "TurnPhaseHud"
		or board.find_child("ConfirmationOverlay", true, false).get_parent()
				!= overlay_layer
	):
		_fail("业务节点必须归属对应的场地、手牌、HUD 或浮层")
		return
	if board.theme == null or board.theme.resource_path != THEME_PATH:
		_fail("DuelBoard 根节点必须直接应用决斗界面 Theme")
		return
	var phase_control: Button = board.find_child("PhaseButton", true, false)
	if (
		phase_control.theme_type_variation != &"PhaseButton"
		or phase_control.has_theme_font_size_override(&"font_size")
		or !duel_theme.has_font_size(&"font_size", &"PhaseButton")
	):
		_fail("阶段按钮必须消费 PhaseButton Theme 变体")
		return
	var system_controls: Array[Button] = []
	for system_button_name in ["RestartButton", "DebugButton", "ExitButton"]:
		var system_button: Button = board.find_child(system_button_name, true, false)
		system_controls.append(system_button)
		if (
			system_button.theme_type_variation != &"SystemButton"
			or system_button.has_theme_font_size_override(&"font_size")
			or !duel_theme.has_font_size(&"font_size", &"SystemButton")
		):
			_fail("系统按钮必须消费 SystemButton Theme 变体：" + system_button_name)
			return
	var opponent_status_surface: Control = board.find_child(
		"OpponentStatusSurface",
		true,
		false
	)
	var opponent_status: Label = board.find_child("OpponentStatus", true, false)
	var player_status: Label = board.find_child("PlayerStatus", true, false)
	var direct_attack_highlight: Panel = board.find_child(
		"DirectAttackHighlight",
		true,
		false
	)
	if (
		opponent_status.get_parent() != opponent_status_surface
		or direct_attack_highlight.get_parent() != opponent_status_surface
		or direct_attack_highlight.visible
		or direct_attack_highlight.anchor_left != 0.0
		or direct_attack_highlight.anchor_top != 0.0
		or direct_attack_highlight.anchor_right != 1.0
		or direct_attack_highlight.anchor_bottom != 1.0
		or direct_attack_highlight.mouse_filter != Control.MOUSE_FILTER_IGNORE
		or direct_attack_highlight.theme_type_variation != &"DirectAttackTarget"
	):
		_fail("对手 LP 必须使用原生点击面及忽略输入的全尺寸直击高亮")
		return
	if (
		opponent_status.theme_type_variation != &"HudStatus"
		or player_status.theme_type_variation != &"HudStatus"
		or !duel_theme.has_font_size(&"font_size", &"HudStatus")
		or !duel_theme.has_color(&"font_color", &"HudStatus")
	):
		_fail("双方状态栏必须共同消费 HudStatus Theme 变体")
		return
	for type_mapping in [
		[&"ZonePanel", &"PanelContainer"],
		[&"AttackTargetPreview", &"Panel"],
		[&"TargetHighlight", &"Panel"],
		[&"TargetSelectedHighlight", &"Panel"],
		[&"DirectAttackTarget", &"Panel"],
		[&"PhaseButton", &"Button"],
		[&"SystemButton", &"Button"],
	]:
		if !duel_theme.is_type_variation(type_mapping[0], type_mapping[1]):
			_fail(
				"Theme 变体基类错误：%s 必须继承 %s"
				% [type_mapping[0], type_mapping[1]]
			)
			return
	for button_theme_type in [&"Button", &"PhaseButton", &"SystemButton"]:
		for style_state in [&"normal", &"hover", &"pressed", &"disabled", &"focus"]:
			if !duel_theme.has_stylebox(style_state, button_theme_type):
				_fail(
					"Theme 缺少 %s 的 %s 状态样式"
					% [button_theme_type, style_state]
				)
				return
	var phase_style: StyleBoxFlat = duel_theme.get_stylebox(&"normal", &"PhaseButton")
	var system_style: StyleBoxFlat = duel_theme.get_stylebox(&"normal", &"SystemButton")
	if (
		absf(phase_control.size.x - phase_control.size.y) > 1.0
		or phase_style.corner_radius_top_left < floori(minf(phase_control.size.x, phase_control.size.y) / 2.0)
	):
		_fail("阶段按钮必须以正方形尺寸和半径呈现真正圆形控制")
		return
	for system_control in system_controls:
		if (
			absf(system_control.size.x - system_control.size.y) > 1.0
			or system_style.corner_radius_top_left
				< floori(minf(system_control.size.x, system_control.size.y) / 2.0)
		):
			_fail("系统按钮必须以正方形尺寸和半径呈现圆形控制：" + system_control.name)
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
	# OCGCore 的 sequence 始终以己方视角从 0 到 4 编号；对手区域在画面中按
	# 5 到 1 反向排列，因此必须验证“语义序号 → 精确场景节点”，不能只验证两端都有卡。
	board.render_snapshot({
		"opponent_monsters": [
			{"card_id": 10001, "sequence": 0, "location": 4, "controller": 1},
			{"card_id": 10005, "sequence": 4, "location": 4, "controller": 1},
		],
		"opponent_spells": [
			{"card_id": 20001, "sequence": 0, "location": 8, "controller": 1},
			{"card_id": 20005, "sequence": 4, "location": 8, "controller": 1},
		],
	})
	for mapping in [
		{
			"row_prefix": "OpponentMonsterZone",
			"sequence": 0,
			"expected_node": "OpponentMonsterZone5",
			"expected_label": "对手怪兽 1",
		},
		{
			"row_prefix": "OpponentMonsterZone",
			"sequence": 4,
			"expected_node": "OpponentMonsterZone1",
			"expected_label": "对手怪兽 5",
		},
		{
			"row_prefix": "OpponentSpellZone",
			"sequence": 0,
			"expected_node": "OpponentSpellZone5",
			"expected_label": "对手魔陷 1",
		},
		{
			"row_prefix": "OpponentSpellZone",
			"sequence": 4,
			"expected_node": "OpponentSpellZone1",
			"expected_label": "对手魔陷 5",
		},
	]:
		var matched_nodes: Array[String] = []
		for visual_index in range(1, 6):
			var zone_name := "%s%s" % [mapping.row_prefix, visual_index]
			var mapped_zone: ZoneView = board.find_child(zone_name, true, false)
			for rendered_card in mapped_zone.card_container.get_children():
				if int(rendered_card.card_data.get("sequence", -1)) == int(mapping.sequence):
					matched_nodes.append(zone_name)
		if matched_nodes != [mapping.expected_node]:
			_fail(
				"对手 sequence=%s 必须唯一映射到 %s，实际为 %s"
				% [mapping.sequence, mapping.expected_node, matched_nodes]
			)
			return
		var expected_zone: ZoneView = board.find_child(mapping.expected_node, true, false)
		if expected_zone.title_label.text != mapping.expected_label:
			_fail(
				"对手卡位标签错误：%s 应显示“%s”，实际为“%s”"
				% [mapping.expected_node, mapping.expected_label, expected_zone.title_label.text]
			)
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
	var target_highlight: Panel = zone.find_child("TargetHighlight", true, false)
	if (
		zone.theme_type_variation != &"ZonePanel"
		or zone.has_theme_stylebox_override(&"panel")
		or target_highlight.theme_type_variation != &"TargetHighlight"
	):
		_fail("ZoneView 与目标高亮必须由共享 Theme 变体提供样式")
		return
	if (
		target_highlight.get_parent() != zone
		or target_highlight.anchor_left != 0.0
		or target_highlight.anchor_top != 0.0
		or target_highlight.anchor_right != 1.0
		or target_highlight.anchor_bottom != 1.0
		or target_highlight.mouse_filter != Control.MOUSE_FILTER_IGNORE
	):
		_fail("TargetHighlight 必须是覆盖整个 ZoneView 且忽略输入的原生覆盖层")
		return
	for method_name in [
		&"set_attack_target_preview",
		&"set_targetable",
		&"set_target_selected",
		&"set_card_selected",
	]:
		if !zone.has_method(method_name):
			_fail("ZoneView 缺少表现接口：" + method_name)
			return
	zone.set_attack_target_preview(true)
	if (
		!target_highlight.visible
		or target_highlight.theme_type_variation != &"AttackTargetPreview"
		or !duel_theme.has_stylebox(&"panel", &"AttackTargetPreview")
	):
		_fail("攻击目标预览必须显示 AttackTargetPreview 黑白样式")
		return
	zone.set_targetable(true)
	if !target_highlight.visible or target_highlight.theme_type_variation != &"TargetHighlight":
		_fail("可选目标必须显示 TargetHighlight 黑白样式")
		return
	zone.set_target_selected(true)
	if (
		!target_highlight.visible
		or target_highlight.theme_type_variation != &"TargetSelectedHighlight"
		or !duel_theme.has_stylebox(&"panel", &"TargetSelectedHighlight")
	):
		_fail("已选目标必须切换为独立的 TargetSelectedHighlight 黑白样式")
		return
	var targetable_style: StyleBoxFlat = duel_theme.get_stylebox(&"panel", &"TargetHighlight")
	var target_selected_style: StyleBoxFlat = duel_theme.get_stylebox(
		&"panel",
		&"TargetSelectedHighlight"
	)
	if (
		targetable_style.bg_color.is_equal_approx(target_selected_style.bg_color)
		and targetable_style.border_color.is_equal_approx(target_selected_style.border_color)
		and targetable_style.border_width_left == target_selected_style.border_width_left
	):
		_fail("可选目标与已选目标必须有可见差异")
		return
	zone.set_attack_target_preview(false)
	zone.set_targetable(false)
	if target_highlight.visible:
		_fail("取消目标状态后必须隐藏目标覆盖层")
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
	var zone_displayed_card: CardView = card_container.get_child(0)
	zone.set_card_selected(true)
	if !zone_displayed_card.selected or !zone_displayed_card.selection_frame.visible:
		_fail("ZoneView 场上选择必须转发到显示中的 CardView")
		return
	zone.set_card_selected(false)
	if zone_displayed_card.selected or zone_displayed_card.selection_frame.visible:
		_fail("ZoneView 清除场上选择时必须同步隐藏 CardView 选择框")
		return
	print("Godot 原生场景契约通过")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
