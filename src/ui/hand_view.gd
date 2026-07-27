class_name HandView
extends HBoxContainer

const CARD_VIEW_SCRIPT = preload("res://src/ui/card_view.gd")

signal card_selected(card_data: Dictionary)
signal card_hovered(card_data: Dictionary)

var _selected_key := ""


func _ready() -> void:
	alignment = BoxContainer.ALIGNMENT_CENTER
	add_theme_constant_override("separation", 8)


func render_cards(cards: Array, show_backs := false) -> void:
	for child in get_children():
		child.queue_free()
	for card_data in cards:
		var card = CARD_VIEW_SCRIPT.new()
		add_child(card)
		card.configure(card_data, show_backs)
		card.set_selected(_card_key(card_data) == _selected_key)
		card.card_selected.connect(_on_card_selected)
		card.card_hovered.connect(card_hovered.emit)


func clear_selection() -> void:
	_selected_key = ""
	for child in get_children():
		if child.get_script() == CARD_VIEW_SCRIPT:
			child.set_selected(false)


func _on_card_selected(card_data: Dictionary) -> void:
	_selected_key = _card_key(card_data)
	for child in get_children():
		if child.get_script() == CARD_VIEW_SCRIPT:
			child.set_selected(_card_key(child.card_data) == _selected_key)
	card_selected.emit(card_data)


func _card_key(card_data: Dictionary) -> String:
	return "%s:%s" % [card_data.get("card_id", 0), card_data.get("sequence", -1)]
