class_name DuelBoard
extends Control

const HAND_VIEW_SCRIPT = preload("res://src/ui/hand_view.gd")
const ZONE_VIEW_SCRIPT = preload("res://src/ui/zone_view.gd")

signal idle_action_requested(action_kind: String, index: int, card_data: Dictionary)
signal end_turn_requested
signal restart_requested
signal exit_requested

var player_hand
var opponent_hand
var player_monster_zones: Array = []
var player_spell_zones: Array = []
var opponent_monster_zones: Array = []
var opponent_spell_zones: Array = []
var detail_image: TextureRect
var detail_name: Label
var detail_type: Label
var detail_text: Label
var action_box: VBoxContainer
var status_label: Label
var turn_label: Label
var debug_overlay: Label
var player_stats_label: Label
var opponent_stats_label: Label
var selected_card: Dictionary = {}
var current_actions: Array = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_interface()


func _build_interface() -> void:
	var background := ColorRect.new()
	background.color = Color("#111111")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)

	var root := HBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 28
	root.offset_top = 22
	root.offset_right = -28
	root.offset_bottom = -22
	root.add_theme_constant_override("separation", 24)
	add_child(root)

	root.add_child(_build_detail_panel())
	root.add_child(_build_field_panel())
	root.add_child(_build_action_panel())

	debug_overlay = Label.new()
	debug_overlay.visible = false
	debug_overlay.position = Vector2(345, 27)
	debug_overlay.size = Vector2(1230, 168)
	debug_overlay.z_index = 20
	debug_overlay.add_theme_color_override("font_color", Color.WHITE)
	debug_overlay.add_theme_color_override("font_shadow_color", Color.BLACK)
	debug_overlay.add_theme_constant_override("shadow_offset_x", 2)
	debug_overlay.add_theme_constant_override("shadow_offset_y", 2)
	add_child(debug_overlay)


func _build_detail_panel() -> Control:
	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(290, 0)
	panel.add_theme_constant_override("separation", 12)
	var heading := Label.new()
	heading.text = "卡片资料"
	heading.add_theme_font_size_override("font_size", 30)
	panel.add_child(heading)
	detail_image = TextureRect.new()
	detail_image.custom_minimum_size = Vector2(270, 393)
	detail_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	detail_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	panel.add_child(detail_image)
	detail_name = Label.new()
	detail_name.text = "悬停或选择手牌"
	detail_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_name.add_theme_font_size_override("font_size", 24)
	panel.add_child(detail_name)
	detail_type = Label.new()
	detail_type.modulate = Color("#bbbbbb")
	detail_type.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(detail_type)
	detail_text = Label.new()
	detail_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_text.clip_text = true
	panel.add_child(detail_text)
	return panel


func _build_field_panel() -> Control:
	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(1170, 0)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 8)

	opponent_hand = HAND_VIEW_SCRIPT.new()
	opponent_hand.custom_minimum_size.y = 149
	panel.add_child(opponent_hand)
	opponent_stats_label = Label.new()
	opponent_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	opponent_stats_label.modulate = Color("#cfcfcf")
	panel.add_child(opponent_stats_label)
	opponent_spell_zones = _add_zone_row(panel, "对手魔陷", true)
	opponent_monster_zones = _add_zone_row(panel, "对手怪兽", true)

	var divider := HSeparator.new()
	divider.custom_minimum_size.y = 18
	panel.add_child(divider)
	turn_label = Label.new()
	turn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	turn_label.add_theme_font_size_override("font_size", 23)
	turn_label.text = "等待决斗数据"
	panel.add_child(turn_label)

	player_monster_zones = _add_zone_row(panel, "玩家怪兽", false)
	player_spell_zones = _add_zone_row(panel, "玩家魔陷", false)
	player_stats_label = Label.new()
	player_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	player_stats_label.modulate = Color("#cfcfcf")
	panel.add_child(player_stats_label)
	player_hand = HAND_VIEW_SCRIPT.new()
	player_hand.custom_minimum_size.y = 149
	player_hand.card_selected.connect(_on_card_selected)
	player_hand.card_hovered.connect(_show_card_detail)
	panel.add_child(player_hand)
	return panel


func _add_zone_row(parent: VBoxContainer, prefix: String, opponent := false) -> Array:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 9)
	parent.add_child(row)
	var zones: Array = []
	for index in range(5):
		var zone = ZONE_VIEW_SCRIPT.new()
		row.add_child(zone)
		var display_index := 5 - index if opponent else index + 1
		zone.configure("%s %s" % [prefix, display_index])
		zones.append(zone)
	return zones


func _build_action_panel() -> Control:
	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(290, 0)
	panel.add_theme_constant_override("separation", 15)
	var heading := Label.new()
	heading.text = "决斗操作"
	heading.add_theme_font_size_override("font_size", 30)
	panel.add_child(heading)
	status_label = Label.new()
	status_label.text = "正在初始化……"
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(status_label)
	action_box = VBoxContainer.new()
	action_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(action_box)
	var cancel := Button.new()
	cancel.text = "取消选择"
	cancel.pressed.connect(_clear_selection)
	panel.add_child(cancel)
	var end_turn := Button.new()
	end_turn.text = "结束回合"
	end_turn.pressed.connect(end_turn_requested.emit)
	panel.add_child(end_turn)
	var restart := Button.new()
	restart.text = "重新开局"
	restart.pressed.connect(restart_requested.emit)
	panel.add_child(restart)
	var exit_game := Button.new()
	exit_game.text = "退出游戏"
	exit_game.pressed.connect(exit_requested.emit)
	panel.add_child(exit_game)
	var help := Label.new()
	help.text = "F1：诊断信息"
	help.modulate = Color("#999999")
	panel.add_child(help)
	return panel


func render_snapshot(snapshot: Dictionary) -> void:
	current_actions = snapshot.get("idle_actions", [])
	# 每份后端快照都会使旧候选失效；先清空选择和按钮，防止跨回合点击
	# 陈旧的 kind/index 操纵另一名玩家当前恰好同索引的候选。
	_clear_selection()
	player_hand.render_cards(snapshot.get("player_hand", []), false)
	var opponent_cards: Array = []
	for index in range(int(snapshot.get("opponent_hand_count", 0))):
		opponent_cards.append({"sequence": index})
	opponent_hand.render_cards(opponent_cards, true)
	turn_label.text = str(snapshot.get("turn_text", "等待玩家操作"))
	player_stats_label.text = str(snapshot.get("player_stats", ""))
	opponent_stats_label.text = str(snapshot.get("opponent_stats", ""))
	status_label.text = str(snapshot.get("status_text", ""))
	debug_overlay.text = str(snapshot.get("debug_text", ""))
	_render_zone_cards(player_monster_zones, snapshot.get("player_monsters", []))
	_render_zone_cards(player_spell_zones, snapshot.get("player_spells", []))
	_render_zone_cards(opponent_monster_zones, snapshot.get("opponent_monsters", []))
	_render_zone_cards(opponent_spell_zones, snapshot.get("opponent_spells", []))


func _render_zone_cards(zones: Array, cards: Array) -> void:
	for zone in zones:
		zone.clear_card()
	for card in cards:
		var sequence := int(card.get("sequence", -1))
		if sequence >= 0 and sequence < zones.size():
			zones[sequence].show_card(card, !card.has("card_id"))


func _on_card_selected(card_data: Dictionary) -> void:
	selected_card = card_data
	_show_card_detail(card_data)
	_rebuild_action_buttons()


func _show_card_detail(card_data: Dictionary) -> void:
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
			idle_action_requested.emit.bind(kind, int(action.get("index", 0)), selected_card)
		)
		action_box.add_child(button)
		matched += 1
	if matched == 0:
		var empty := Label.new()
		empty.text = "当前没有可执行动作"
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		action_box.add_child(empty)


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
		_:
			return ""


func _clear_selection() -> void:
	selected_card = {}
	player_hand.clear_selection()
	_rebuild_action_buttons()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F1:
		debug_overlay.visible = !debug_overlay.visible
		get_viewport().set_input_as_handled()
