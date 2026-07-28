class_name ZoneView
extends PanelContainer

# ZoneView 与 HandView 共用 CardView 原生场景，避免创建缺少固定视觉节点的裸脚本实例。
const CARD_VIEW_SCENE = preload("res://src/ui/card_view.tscn")

signal card_selected(card_data: Dictionary)
signal card_hovered(card_data: Dictionary)
signal card_unhovered(card_data: Dictionary)

var zone_label := ""
# 这些固定节点由 zone_view.tscn 持有；脚本只绑定节点，避免运行时拼装稳定界面。
@onready var card_container: CenterContainer = %CardContainer
@onready var title_label: Label = %TitleLabel


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
