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
var detail_overlay: PanelContainer
var detail_image: TextureRect
var detail_name: Label
var detail_type: Label
var detail_text: Label
var action_box: HBoxContainer
var status_label: Label
var turn_label: Label
var phase_button: Button
var debug_overlay: Label
var player_stats_label: Label
var opponent_stats_label: Label
var confirmation_overlay: PanelContainer
var confirmation_label: Label
var selected_card: Dictionary = {}
var current_actions: Array = []
var _confirmation_kind := ""
var _local_player_turn := false
var _can_end_turn := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_interface()


func _build_interface() -> void:
	var background := ColorRect.new()
	background.name = "Background"
	background.color = Color("#0b0d10")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_STOP
	background.gui_input.connect(_on_background_input)
	add_child(background)

	add_child(_build_battlefield())
	_build_player_status()
	_build_card_detail_overlay()
	_build_context_action_bar()
	_build_phase_control()
	_build_system_tools()
	_build_status_toast()
	_build_confirmation_overlay()
	_build_debug_overlay()


func _build_battlefield() -> Control:
	var panel := VBoxContainer.new()
	panel.name = "Battlefield"
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.anchor_left = 0.18
	panel.anchor_right = 0.82
	panel.offset_left = 0
	panel.offset_right = 0
	panel.offset_top = 18
	panel.offset_bottom = -18
	panel.add_theme_constant_override("separation", 7)

	opponent_hand = HAND_VIEW_SCRIPT.new()
	opponent_hand.custom_minimum_size.y = 128
	panel.add_child(opponent_hand)
	opponent_spell_zones = _add_zone_row(panel, "对手魔陷", true)
	opponent_monster_zones = _add_zone_row(panel, "对手怪兽", true)

	var divider := HSeparator.new()
	divider.custom_minimum_size.y = 14
	panel.add_child(divider)
	turn_label = Label.new()
	turn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	turn_label.add_theme_font_size_override("font_size", 22)
	turn_label.text = "等待决斗数据"
	panel.add_child(turn_label)

	player_monster_zones = _add_zone_row(panel, "玩家怪兽", false)
	player_spell_zones = _add_zone_row(panel, "玩家魔陷", false)
	player_hand = HAND_VIEW_SCRIPT.new()
	player_hand.custom_minimum_size.y = 146
	player_hand.card_selected.connect(_on_card_selected)
	player_hand.card_hovered.connect(_preview_card)
	player_hand.card_unhovered.connect(_on_card_unhovered)
	panel.add_child(player_hand)
	return panel


func _add_zone_row(parent: VBoxContainer, prefix: String, opponent := false) -> Array:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)
	var zones: Array = []
	for index in range(5):
		var zone = ZONE_VIEW_SCRIPT.new()
		row.add_child(zone)
		var display_index := 5 - index if opponent else index + 1
		zone.configure("%s %s" % [prefix, display_index])
		zones.append(zone)
	return zones


func _build_player_status() -> void:
	opponent_stats_label = _make_corner_status("OpponentStatus")
	opponent_stats_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	opponent_stats_label.position = Vector2(-440, 28)
	opponent_stats_label.size = Vector2(410, 62)
	opponent_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(opponent_stats_label)

	player_stats_label = _make_corner_status("PlayerStatus")
	player_stats_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	player_stats_label.position = Vector2(28, -90)
	player_stats_label.size = Vector2(410, 62)
	add_child(player_stats_label)


func _make_corner_status(node_name: String) -> Label:
	var label := Label.new()
	label.name = node_name
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color("#f4f7fa"))
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	return label


func _build_card_detail_overlay() -> void:
	detail_overlay = PanelContainer.new()
	detail_overlay.name = "CardDetailOverlay"
	detail_overlay.visible = false
	detail_overlay.z_index = 10
	detail_overlay.anchor_left = 0.015
	detail_overlay.anchor_top = 0.14
	detail_overlay.anchor_right = 0.245
	detail_overlay.anchor_bottom = 0.82
	detail_overlay.add_theme_stylebox_override("panel", _panel_style(Color("#0d1218ee")))
	add_child(detail_overlay)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	detail_overlay.add_child(content)
	detail_name = Label.new()
	detail_name.add_theme_font_size_override("font_size", 24)
	detail_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(detail_name)
	detail_image = TextureRect.new()
	detail_image.custom_minimum_size = Vector2(240, 350)
	detail_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	detail_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	content.add_child(detail_image)
	detail_type = Label.new()
	detail_type.modulate = Color("#bdc7d0")
	detail_type.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(detail_type)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(scroll)
	detail_text = Label.new()
	detail_text.custom_minimum_size.x = 390
	detail_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	scroll.add_child(detail_text)


func _build_context_action_bar() -> void:
	action_box = HBoxContainer.new()
	action_box.name = "ContextActionBar"
	action_box.visible = false
	action_box.z_index = 12
	action_box.anchor_left = 0.33
	action_box.anchor_top = 0.79
	action_box.anchor_right = 0.67
	action_box.anchor_bottom = 0.845
	action_box.alignment = BoxContainer.ALIGNMENT_CENTER
	action_box.add_theme_constant_override("separation", 10)
	add_child(action_box)


func _build_phase_control() -> void:
	phase_button = Button.new()
	phase_button.name = "PhaseButton"
	phase_button.text = "玩家1\n主要阶段"
	phase_button.disabled = true
	phase_button.z_index = 8
	phase_button.anchor_left = 0.84
	phase_button.anchor_top = 0.43
	phase_button.anchor_right = 0.935
	phase_button.anchor_bottom = 0.57
	phase_button.add_theme_font_size_override("font_size", 20)
	phase_button.add_theme_stylebox_override("normal", _round_button_style("#142531", "#7d8d98"))
	phase_button.add_theme_stylebox_override("hover", _round_button_style("#173f57", "#a9e2ff"))
	phase_button.add_theme_stylebox_override("pressed", _round_button_style("#10202b", "#ffffff"))
	phase_button.pressed.connect(_on_phase_pressed)
	add_child(phase_button)


func _build_system_tools() -> void:
	var tools := HBoxContainer.new()
	tools.name = "SystemTools"
	tools.z_index = 9
	tools.anchor_left = 0.84
	tools.anchor_top = 0.92
	tools.anchor_right = 0.985
	tools.anchor_bottom = 0.985
	tools.alignment = BoxContainer.ALIGNMENT_END
	tools.add_theme_constant_override("separation", 12)
	add_child(tools)
	tools.add_child(_make_tool_button("↻", "重新开局", _request_restart))
	tools.add_child(_make_tool_button("i", "诊断信息", _toggle_debug))
	tools.add_child(_make_tool_button("×", "退出游戏", _request_exit))


func _make_tool_button(
		label_text: String,
		tooltip: String,
		callback: Callable
) -> Button:
	var button := Button.new()
	button.custom_minimum_size = Vector2(58, 58)
	button.text = label_text
	button.tooltip_text = tooltip
	button.add_theme_font_size_override("font_size", 24)
	button.add_theme_stylebox_override("normal", _round_button_style("#14212b", "#78909f"))
	button.add_theme_stylebox_override("hover", _round_button_style("#183b50", "#c6efff"))
	button.pressed.connect(callback)
	return button


func _build_status_toast() -> void:
	status_label = Label.new()
	status_label.name = "StatusToast"
	status_label.z_index = 14
	status_label.anchor_left = 0.35
	status_label.anchor_top = 0.025
	status_label.anchor_right = 0.65
	status_label.anchor_bottom = 0.075
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status_label.add_theme_font_size_override("font_size", 18)
	status_label.text = "正在初始化……"
	add_child(status_label)


func _build_confirmation_overlay() -> void:
	confirmation_overlay = PanelContainer.new()
	confirmation_overlay.name = "ConfirmationOverlay"
	confirmation_overlay.visible = false
	confirmation_overlay.z_index = 18
	confirmation_overlay.anchor_left = 0.72
	confirmation_overlay.anchor_top = 0.62
	confirmation_overlay.anchor_right = 0.94
	confirmation_overlay.anchor_bottom = 0.76
	confirmation_overlay.add_theme_stylebox_override("panel", _panel_style(Color("#10161dee")))
	add_child(confirmation_overlay)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	confirmation_overlay.add_child(content)
	confirmation_label = Label.new()
	confirmation_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	confirmation_label.add_theme_font_size_override("font_size", 20)
	content.add_child(confirmation_label)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 10)
	content.add_child(buttons)
	var confirm := Button.new()
	confirm.text = "确认"
	confirm.pressed.connect(_confirm_pending_action)
	buttons.add_child(confirm)
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.pressed.connect(_close_confirmation)
	buttons.add_child(cancel)


func _build_debug_overlay() -> void:
	debug_overlay = Label.new()
	debug_overlay.name = "DebugOverlay"
	debug_overlay.visible = false
	debug_overlay.z_index = 20
	debug_overlay.anchor_left = 0.27
	debug_overlay.anchor_top = 0.1
	debug_overlay.anchor_right = 0.73
	debug_overlay.anchor_bottom = 0.18
	debug_overlay.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	debug_overlay.add_theme_color_override("font_color", Color.WHITE)
	debug_overlay.add_theme_color_override("font_shadow_color", Color.BLACK)
	debug_overlay.add_theme_constant_override("shadow_offset_x", 2)
	debug_overlay.add_theme_constant_override("shadow_offset_y", 2)
	add_child(debug_overlay)


func render_snapshot(snapshot: Dictionary) -> void:
	current_actions = snapshot.get("idle_actions", [])
	_local_player_turn = bool(snapshot.get("local_player_turn", false))
	_can_end_turn = bool(snapshot.get("can_end_turn", false))
	_clear_selection()
	player_hand.render_cards(snapshot.get("player_hand", []), false)
	var opponent_cards: Array = []
	for index in range(int(snapshot.get("opponent_hand_count", 0))):
		opponent_cards.append({"sequence": index})
	opponent_hand.render_cards(opponent_cards, true)
	turn_label.text = str(snapshot.get("turn_text", "等待玩家操作"))
	phase_button.text = str(snapshot.get("turn_text", "等待阶段数据")).replace(" · ", "\n")
	phase_button.disabled = !_local_player_turn or !_can_end_turn
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
		_clear_selection()
		return
	selected_card = card_data
	_show_card_detail(card_data)
	_rebuild_action_buttons()


func _preview_card(card_data: Dictionary) -> void:
	_show_card_detail(card_data)


func _on_card_unhovered(_card_data: Dictionary) -> void:
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
			idle_action_requested.emit.bind(kind, int(action.get("index", 0)), selected_card)
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
		_:
			return ""


func _clear_selection() -> void:
	selected_card = {}
	if player_hand != null:
		player_hand.clear_selection()
	for child in action_box.get_children():
		child.queue_free()
	action_box.visible = false
	_hide_card_detail()


func _on_phase_pressed() -> void:
	if _local_player_turn and _can_end_turn:
		_open_confirmation("end_turn", "确定结束当前回合？")


func _request_restart() -> void:
	_open_confirmation("restart", "确定使用新种子重新开局？")


func _request_exit() -> void:
	_open_confirmation("exit", "确定退出游戏？")


func _open_confirmation(kind: String, message: String) -> void:
	_confirmation_kind = kind
	confirmation_label.text = message
	confirmation_overlay.visible = true


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


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F1:
		_toggle_debug()
		get_viewport().set_input_as_handled()


func _panel_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = Color("#778692")
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	return style


func _round_button_style(background_color: String, border_color: String) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(background_color)
	style.border_color = Color(border_color)
	style.set_border_width_all(2)
	style.set_corner_radius_all(48)
	return style
