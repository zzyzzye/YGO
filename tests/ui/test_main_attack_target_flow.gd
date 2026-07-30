extends SceneTree

const MAIN_SCENE = preload("res://src/main/main.tscn")

var _input_viewport: SubViewport


# FakeBridge 只隔离原生 OCGCore 边界；Main、DuelBoard、ZoneView 场景和输入
# 路由均使用生产实现。响应夹具完整携带 pending_action，覆盖 Retry 与正常推进。
class FakeBridge:
	extends RefCounted

	var active := false
	var game_over := false
	var winner := -1
	var place_submissions: Array = []
	var pending: Dictionary = _place_pending([
		{"controller": 0, "location": 4, "sequence": 0},
		{"controller": 1, "location": 8, "sequence": 3},
	])
	var setup_pending: Dictionary = pending.duplicate(true)
	var next_pending: Dictionary = {
		"kind": "idle",
		"player": 0,
		"message_type": 11,
		"can_end_turn": true,
		"idle_actions": [],
	}
	var next_result: Dictionary = {
		"ok": true,
		"response_rejected": false,
		"message": "区域已提交",
	}
	var pending_after_failure: Dictionary = {}
	var reentrant_submission := Callable()

	func initialize_card_database(_root: String) -> Dictionary:
		return {"ok": true, "message": "测试卡库已初始化"}

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
		active = true
		game_over = false
		winner = -1
		pending = setup_pending.duplicate(true)
		return {"ok": true, "message": "测试决斗已建立"}

	func is_duel_active() -> bool:
		return active

	func destroy_duel() -> Dictionary:
		active = false
		return {"ok": true, "message": "测试决斗已销毁"}

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
			"game_over": game_over,
			"winner": winner,
			"players": {
				"p1": empty_player,
				"p2": empty_player.duplicate(true),
			},
		}

	func submit_place(controller: int, location: int, sequence: int) -> Dictionary:
		place_submissions.append([controller, location, sequence])
		# 同步 Bridge 调用中的重入模拟双击/重复信号。Main 必须在调用前持锁，
		# 因而该回调不能产生第二次 submit_place。
		var callback := reentrant_submission
		reentrant_submission = Callable()
		if callback.is_valid():
			callback.call()
		var response := next_result.duplicate(true)
		if !bool(response.get("ok", false)) and !pending_after_failure.is_empty():
			# 本地失败没有 Retry 的 pending_action 恢复语义；该状态只通过随后
			# get_pending_action 暴露，用来验证 Main 是否真正重新读取 Bridge。
			pending = pending_after_failure.duplicate(true)
			pending_after_failure.clear()
		elif bool(response.get("ok", false)):
			if bool(response.get("response_rejected", false)):
				response["pending_action"] = pending.duplicate(true)
			else:
				pending = next_pending.duplicate(true)
				response["pending_action"] = pending.duplicate(true)
		return response

	func _place_pending(options: Array) -> Dictionary:
		return {
			"kind": "select_place",
			"player": 0,
			"message_type": 18,
			"place_options": options.duplicate(true),
		}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var fake := FakeBridge.new()
	var main = MAIN_SCENE.instantiate()
	main.bridge = fake
	# 独立 SubViewport 在 headless DisplayServer 下仍执行真实 GUI picking，
	# 避免根 Window 没有系统鼠标泵时退回直接 emit 控件信号。
	_input_viewport = SubViewport.new()
	_input_viewport.size = Vector2i(1920, 1080)
	_input_viewport.gui_disable_input = false
	_input_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_input_viewport)
	_input_viewport.add_child(main)
	await process_frame
	await process_frame
	var board: DuelBoard = main.board
	var initial_generation: int = board._rule_decision_generation
	if (
		board._rule_decision_kind != "select_place"
		or !board.player_monster_zones[0].target_highlight.visible
		or !board.opponent_spell_zones[3].target_highlight.visible
	):
		_fail("Main 必须把 select_place 候选写入原生 DuelBoard")
		return

	# 本地 ok=false 不具备 OCGCore Retry 语义：Main 必须重新读取 Bridge 当前
	# pending 并推进代次，不能强制恢复提交前候选或保留旧代次。
	fake.next_result = {
		"ok": false,
		"response_rejected": false,
		"message": "测试区域本地提交失败",
	}
	fake.pending_after_failure = fake._place_pending([
		{"controller": 0, "location": 8, "sequence": 2},
	])
	await _viewport_click(board.player_monster_zones[0])
	var failure_generation: int = board._rule_decision_generation
	if (
		fake.place_submissions != [[0, 4, 0]]
		or failure_generation != initial_generation + 1
		or board.player_monster_zones[0].target_highlight.visible
		or !board.player_spell_zones[2].target_highlight.visible
		or str(main._current_pending_action.get("kind", "none")) != "select_place"
		or main._current_pending_action.get("place_options", []) != [
			{"controller": 0, "location": 8, "sequence": 2},
		]
		or "本地提交失败" not in board.status_label.text
	):
		_fail("区域本地失败必须重新读取当前 pending 并推进决策代次")
		return

	# Retry 前先在 Bridge 内重入同一 Main 信号，验证锁在原生调用之前生效；
	# 返回后候选恢复且代次不变，与上面的本地失败形成明确对照。
	fake.next_result = {
		"ok": true,
		"response_rejected": true,
		"message": "OCGCore 拒绝测试区域响应",
	}
	fake.reentrant_submission = func() -> void:
		board.place_requested.emit(0, 8, 2, failure_generation)
	await _viewport_click(board.player_spell_zones[2])
	if (
		fake.place_submissions != [[0, 4, 0], [0, 8, 2]]
		or board._rule_decision_generation != failure_generation
		or !board.player_spell_zones[2].target_highlight.visible
		or board.status_label.text != "OCGCore 拒绝了响应，请重新选择放置区域"
	):
		_fail("区域 Retry 必须锁住重入、保留代次、重建候选并显示重新选区提示")
		return

	# 正常响应进入下一份 SelectPlace，必须推进代次；同一调用栈保留的旧代次
	# 与任意伪造三元组都不能绕过 Main 的当前 pending 门禁。
	fake.next_result = {
		"ok": true,
		"response_rejected": false,
		"message": "区域已提交",
	}
	fake.next_pending = fake._place_pending([
		{"controller": 1, "location": 4, "sequence": 4},
	])
	await _viewport_click(board.player_spell_zones[2])
	var current_generation: int = board._rule_decision_generation
	if (
		fake.place_submissions != [[0, 4, 0], [0, 8, 2], [0, 8, 2]]
		or current_generation != failure_generation + 1
		or !board.opponent_monster_zones[4].target_highlight.visible
	):
		_fail("正常区域响应必须刷新下一决策并推进代次")
		return
	board.place_requested.emit(0, 4, 0, initial_generation)
	board.place_requested.emit(1, 8, 3, current_generation)
	main._submission_in_progress = true
	board.place_requested.emit(1, 4, 4, current_generation)
	main._submission_in_progress = false
	if fake.place_submissions.size() != 3:
		_fail("旧代次、非当前候选与提交锁定态不得触碰 Bridge")
		return

	# 重开使用 idle 初始决策，确保旧 ZoneView 高亮与待决快照都被清空；终局
	# 即使 Bridge 残留 select_place，也只能展示场面，不能保留可提交入口。
	fake.setup_pending = {
		"kind": "idle",
		"player": 0,
		"message_type": 11,
		"can_end_turn": true,
		"idle_actions": [],
	}
	board.restart_requested.emit()
	await process_frame
	if (
		board._rule_decision_kind != "none"
		or _has_place_highlight(board)
		or str(main._current_pending_action.get("kind", "none")) != "idle"
	):
		_fail("重新开局必须清除旧区域高亮与提交入口")
		return
	fake.pending = fake._place_pending([
		{"controller": 0, "location": 8, "sequence": 2},
	])
	fake.game_over = true
	fake.winner = 0
	main._refresh_board("终局测试")
	if (
		_has_place_highlight(board)
		or !main._current_pending_action.is_empty()
	):
		_fail("终局快照必须清除区域高亮并退休 Main 待决入口")
		return

	main.queue_free()
	_input_viewport.queue_free()
	await process_frame
	print("Main 区域选择与代次安全测试通过")
	quit(0)


func _has_place_highlight(board: DuelBoard) -> bool:
	for zone in (
		board.player_monster_zones
		+ board.player_spell_zones
		+ board.opponent_monster_zones
		+ board.opponent_spell_zones
	):
		if (
			zone.target_highlight.visible
			and zone.target_highlight.theme_type_variation == &"PlaceCandidate"
		):
			return true
	return false


func _viewport_click(control: Control, double_click := false) -> void:
	await _viewport_click_position(
		control.get_global_rect().get_center(),
		double_click
	)


func _viewport_click_position(position: Vector2, double_click := false) -> void:
	# SubViewport.push_input 进入真实 GUI 命中链；按下与释放分帧，既覆盖
	# ZoneView 的 gui_input，也覆盖 BaseButton 在释放时发布 pressed。
	var motion := InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	_input_viewport.push_input(motion)
	await process_frame
	var press := InputEventMouseButton.new()
	press.position = position
	press.global_position = position
	press.button_index = MOUSE_BUTTON_LEFT
	press.button_mask = MOUSE_BUTTON_MASK_LEFT
	press.pressed = true
	press.double_click = double_click
	_input_viewport.push_input(press)
	await process_frame
	var release := InputEventMouseButton.new()
	release.position = position
	release.global_position = position
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.double_click = double_click
	_input_viewport.push_input(release)
	await process_frame


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
