extends SceneTree

const HAND_VIEW_SCRIPT = preload("res://src/ui/hand_view.gd")

var _selected_events: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var hand = HAND_VIEW_SCRIPT.new()
	root.add_child(hand)
	await process_frame

	if !hand.has_signal("card_unhovered"):
		_fail("HandView 必须向决斗界面转发 card_unhovered 信号")
		return

	hand.card_selected.connect(func(card_data: Dictionary) -> void:
		_selected_events.append(card_data)
	)
	var card := {
		"card_id": 89631139,
		"sequence": 2,
		"location": 2,
	}
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

	print("情境式决斗界面交互契约通过")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
