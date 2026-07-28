class_name ZoneView
extends PanelContainer

# ZoneView 与 HandView 共用 CardView 原生场景，避免创建缺少固定视觉节点的裸脚本实例。
const CARD_VIEW_SCENE = preload("res://src/ui/card_view.tscn")

signal card_selected(card_data: Dictionary)
signal card_hovered(card_data: Dictionary)
signal card_unhovered(card_data: Dictionary)

var zone_label := ""
var card_container: CenterContainer
var title_label: Label


func _ready() -> void:
	custom_minimum_size = Vector2(105, 132)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#202020")
	style.border_color = Color("#777777")
	style.set_border_width_all(1)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	add_theme_stylebox_override("panel", style)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 2)
	add_child(stack)
	card_container = CenterContainer.new()
	card_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.add_child(card_container)
	title_label = Label.new()
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", 15)
	title_label.modulate = Color("#cfcfcf")
	stack.add_child(title_label)


func configure(label_text: String) -> void:
	zone_label = label_text
	if title_label:
		title_label.text = label_text


func show_card(card_data: Dictionary, show_back := false) -> void:
	for child in card_container.get_children():
		child.queue_free()
	var card: CardView = CARD_VIEW_SCENE.instantiate()
	card_container.add_child(card)
	# CardView 在 _ready() 中建立手牌默认尺寸，因此必须在进入树后覆盖，
	# 才能让场区卡保持紧凑并避免两行区域挤压手牌。
	card.custom_minimum_size = Vector2(72, 105)
	card.configure(card_data, show_back)
	card.card_selected.connect(card_selected.emit)
	card.card_hovered.connect(card_hovered.emit)
	card.card_unhovered.connect(card_unhovered.emit)


func clear_card() -> void:
	for child in card_container.get_children():
		child.queue_free()
