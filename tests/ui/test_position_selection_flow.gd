extends SceneTree

const MAIN_SCENE = preload("res://src/main/main.tscn")


class FakeBridge:
	extends RefCounted

	var pending := {
		"kind": "select_position",
		"player": 0,
		"message_type": 19,
		"selection_card_id": 89631139,
		"position_options": [1, 4, 8],
	}
	var calls: Array[Dictionary] = []
	var fail_next := false
	var reject_next := false

	func initialize_card_database(_root: String) -> Dictionary:
		return {"ok": true}

	func get_scripted_card_ids() -> PackedInt64Array:
		var ids := PackedInt64Array()
		for card_id in range(100001, 100041):
			ids.append(card_id)
		return ids

	func setup_duel(
		_deck1: PackedInt64Array,
		_deck2: PackedInt64Array,
		_seed: int
	) -> Dictionary:
		return {"ok": true}

	func is_duel_active() -> bool:
		return true

	func destroy_duel() -> void:
		pass

	func get_pending_action() -> Dictionary:
		return pending.duplicate(true)

	func get_duel_state() -> Dictionary:
		var empty_player := {
			"lp": 8000,
			"deck": 35,
			"hand": 5,
			"extra": 0,
			"graveyard": 0,
			"banished": 0,
			"hand_cards": [],
			"monster_cards": [],
			"spell_trap_cards": [],
		}
		return {
			"ok": true,
			"game_over": false,
			"winner": -1,
			"players": {
				"p1": empty_player,
				"p2": empty_player.duplicate(true),
			},
		}

	func submit_position(position: int) -> Dictionary:
		calls.append({"position": position})
		if fail_next:
			fail_next = false
			return {
				"ok": false,
				"response_rejected": false,
				"message": "测试位置提交失败",
				"pending_action": pending.duplicate(true),
			}
		if reject_next:
			reject_next = false
			return {
				"ok": true,
				"response_rejected": true,
				"message": "OCGCore 拒绝测试位置响应",
				"pending_action": pending.duplicate(true),
			}
		pending = {
			"kind": "idle",
			"player": 0,
			"message_type": 11,
			"can_end_turn": true,
			"idle_actions": [],
		}
		return {
			"ok": true,
			"response_rejected": false,
			"message": "位置已提交",
			"pending_action": pending.duplicate(true),
		}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var fake := FakeBridge.new()
	var main = MAIN_SCENE.instantiate()
	main.bridge = fake
	root.add_child(main)
	await process_frame
	await process_frame
	var board: DuelBoard = main.board
	var buttons := _button_texts(board.confirmation_buttons)
	if !board.confirmation_overlay.visible or buttons != [
		"表侧攻击", "表侧守备", "里侧守备",
	]:
		_fail("SelectPosition 必须只按核心候选显示中文原生按钮")
		return

	# 本地失败和 MSG_RETRY 都不能关闭入口；重复信号也只能在当前快照仍有效时提交。
	fake.fail_next = true
	board.confirmation_buttons.get_child(0).pressed.emit()
	await process_frame
	if !board.confirmation_overlay.visible or fake.calls.size() != 1:
		_fail("表示形式本地失败后必须保留当前按钮供重试")
		return
	fake.reject_next = true
	board.confirmation_buttons.get_child(0).pressed.emit()
	await process_frame
	if (
		!board.confirmation_overlay.visible
		or fake.calls.size() != 2
		or "重新选择" not in board.status_label.text
	):
		_fail("MSG_RETRY 后必须恢复同一表示形式入口和中文提示")
		return

	var stale_button: Button = board.confirmation_buttons.get_child(2)
	stale_button.pressed.emit()
	if fake.calls.size() != 3 or int(fake.calls.back().position) != 8:
		_fail("合法按钮必须提交 C++ 候选中的稳定单值")
		return
	# 同步刷新已替换规则快照，但旧节点要到帧末才真正释放；在同一调用栈
	# 再发一次信号可准确覆盖双击/重入门禁。
	stale_button.pressed.emit()
	await process_frame
	if fake.calls.size() != 3 or board.confirmation_overlay.visible:
		_fail("成功后的旧按钮信号不得重复提交新快照")
		return

	main.queue_free()
	await process_frame
	print("表示形式选择流程测试通过")
	quit(0)


func _button_texts(container: Control) -> Array[String]:
	var texts: Array[String] = []
	for child in container.get_children():
		if child is Button:
			texts.append(child.text)
	return texts


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
