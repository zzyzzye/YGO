class_name HandView
extends HBoxContainer

# HandView 必须实例化完整场景，CardView 的原生子节点和 AnimationPlayer 才会随卡牌一同进入树。
const CARD_VIEW_SCENE = preload("res://src/ui/card_view.tscn")

signal card_selected(card_data: Dictionary)
signal card_hovered(card_data: Dictionary)
signal card_unhovered(card_data: Dictionary)

var _selected_key := ""


func render_cards(cards: Array, show_backs := false) -> void:
	for child in get_children():
		_retire_card(child)
	for card_data in cards:
		var card: CardView = CARD_VIEW_SCENE.instantiate()
		add_child(card)
		card.configure(card_data, show_backs)
		card.set_selected(_card_key(card_data) == _selected_key)
		card.card_selected.connect(_on_card_selected)
		card.card_hovered.connect(_forward_card_hovered)
		card.card_unhovered.connect(_forward_card_unhovered)


func clear_selection() -> void:
	_selected_key = ""
	for child in get_children():
		if child is CardView:
			child.set_selected(false)


func _on_card_selected(card_data: Dictionary) -> void:
	var clicked_key := _card_key(card_data)
	# 重复点击同一张牌等价于取消锁定，使鼠标和手柄都能在不寻找额外
	# 关闭按钮的情况下回到纯战场视图。
	_selected_key = "" if clicked_key == _selected_key else clicked_key
	for child in get_children():
		if child is CardView:
			child.set_selected(_card_key(child.card_data) == _selected_key)
	card_selected.emit({} if _selected_key.is_empty() else card_data)


func _forward_card_hovered(card_data: Dictionary) -> void:
	card_hovered.emit(card_data)


func _forward_card_unhovered(card_data: Dictionary) -> void:
	card_unhovered.emit(card_data)


func _retire_card(child: Node) -> void:
	# queue_free() 到帧末才销毁。旧卡必须先停止输入并只断开 HandView 自己的
	# 三条转发；卡牌上的诊断、测试或未来外部观察连接仍归其创建者所有。
	if child is CardView:
		child.disabled = true
		child.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if child.card_selected.is_connected(_on_card_selected):
			child.card_selected.disconnect(_on_card_selected)
		if child.card_hovered.is_connected(_forward_card_hovered):
			child.card_hovered.disconnect(_forward_card_hovered)
		if child.card_unhovered.is_connected(_forward_card_unhovered):
			child.card_unhovered.disconnect(_forward_card_unhovered)
	remove_child(child)
	child.queue_free()


func _card_key(card_data: Dictionary) -> String:
	return "%s:%s" % [card_data.get("card_id", 0), card_data.get("sequence", -1)]
