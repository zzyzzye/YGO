extends SceneTree

const CARD_SCENE_PATH := "res://src/ui/card_view.tscn"
const THEME_PATH := "res://src/ui/themes/duel_theme.tres"
const ZONE_SCENE_PATH := "res://src/ui/zone_view.tscn"
const HAND_SCENE_PATH := "res://src/ui/hand_view.tscn"


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
	for scene_path in [ZONE_SCENE_PATH, HAND_SCENE_PATH]:
		if !ResourceLoader.exists(scene_path):
			_fail("缺少原生子场景：" + scene_path)
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
