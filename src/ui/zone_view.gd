class_name ZoneView
extends PanelContainer

# ZoneView 与 HandView 共用 CardView 原生场景，避免创建缺少固定视觉节点的裸脚本实例。
const CARD_VIEW_SCENE = preload("res://src/ui/card_view.tscn")

signal card_selected(card_data: Dictionary)
signal card_hovered(card_data: Dictionary)
signal card_unhovered(card_data: Dictionary)

var zone_label := ""
var _targetable := false
var _target_selected := false
var _card_selected := false
# 这些固定节点由 zone_view.tscn 持有；脚本只绑定节点，避免运行时拼装稳定界面。
@onready var card_container: CenterContainer = %CardContainer
@onready var title_label: Label = %TitleLabel
@onready var target_highlight: Panel = %TargetHighlight


func _ready() -> void:
	# DuelBoard 会在区域加入场景树前设置标题；原生节点就绪后需回填缓存值，
	# 才不会因 @onready 尚未绑定 Label 而丢失首帧区域名称。
	title_label.text = zone_label


func configure(label_text: String) -> void:
	zone_label = label_text
	if title_label:
		title_label.text = label_text


func set_targetable(value: bool) -> void:
	# 已选目标必然来自合法目标集合；一旦候选失效，同时清除选中态，避免旧快照
	# 留下更强的高亮却已不能提交。
	_targetable = value
	if !value:
		_target_selected = false
	_refresh_target_highlight()


func set_target_selected(value: bool) -> void:
	_target_selected = value and _targetable
	_refresh_target_highlight()


func set_card_selected(value: bool) -> void:
	# DuelBoard 只传递展示状态，真正的规则选择仍由 OCGCore 候选动作决定。
	_card_selected = value
	for child in card_container.get_children():
		if child is CardView:
			child.set_selected(value)


func show_card(card_data: Dictionary, show_back := false) -> void:
	for child in card_container.get_children():
		_retire_card(child)
	var card: CardView = CARD_VIEW_SCENE.instantiate()
	card_container.add_child(card)
	# CardView 在 _ready() 中建立手牌默认尺寸，因此必须在进入树后覆盖，
	# 才能让场区卡保持紧凑并避免两行区域挤压手牌。
	card.custom_minimum_size = Vector2(72, 105)
	card.configure(card_data, show_back)
	card.set_selected(_card_selected)
	card.card_selected.connect(_forward_card_selected)
	card.card_hovered.connect(_forward_card_hovered)
	card.card_unhovered.connect(_forward_card_unhovered)


func clear_card() -> void:
	_card_selected = false
	for child in card_container.get_children():
		_retire_card(child)


func _refresh_target_highlight() -> void:
	target_highlight.visible = _targetable
	target_highlight.theme_type_variation = (
		&"TargetSelectedHighlight" if _target_selected else &"TargetHighlight"
	)


func _forward_card_selected(card_data: Dictionary) -> void:
	card_selected.emit(card_data)


func _forward_card_hovered(card_data: Dictionary) -> void:
	card_hovered.emit(card_data)


func _forward_card_unhovered(card_data: Dictionary) -> void:
	card_unhovered.emit(card_data)


func _retire_card(child: Node) -> void:
	# 旧实例在帧末前仍可能被外部持有；只撤销 ZoneView 建立的转发，既阻止
	# 过期选择进入决斗板，也不破坏卡牌自身的其他观察者。
	if child is CardView:
		child.disabled = true
		child.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if child.card_selected.is_connected(_forward_card_selected):
			child.card_selected.disconnect(_forward_card_selected)
		if child.card_hovered.is_connected(_forward_card_hovered):
			child.card_hovered.disconnect(_forward_card_hovered)
		if child.card_unhovered.is_connected(_forward_card_unhovered):
			child.card_unhovered.disconnect(_forward_card_unhovered)
	card_container.remove_child(child)
	child.queue_free()
