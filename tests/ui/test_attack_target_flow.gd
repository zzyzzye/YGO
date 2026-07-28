extends SceneTree

const MAIN_SCENE = preload("res://src/main/main.tscn")


# FakeBridge 只替代真实 OCGCore 边界，完整保留 Main、DuelBoard、场景树和输入
# 路由。每个提交方法都先记录语义参数，再以新的 pending/state 模拟核心响应，
# 因而测试能同时约束“提交了什么”和“何时才允许界面采用新快照”。
class FakeBridge:
	extends RefCounted

	var active := false
	var player_lp := 8000
	var opponent_lp := 4200
	var game_over := false
	var winner := -1
	var pending: Dictionary = {}
	var calls: Array[Dictionary] = []
	var select_options: Array = [
		{
			"index": 17,
			"controller": 1,
			"location": 4,
			"sequence": 2,
		},
	]
	var select_player := 0
	var select_min := 1
	var select_max := 1
	var select_cancelable := true
	var fail_next_method := ""
	var reentrant_direct_request := Callable()

	func _init() -> void:
		pending = _battle_pending()

	func initialize_card_database(_project_root: String) -> Dictionary:
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
		player_lp = 8000
		opponent_lp = 4200
		game_over = false
		winner = -1
		pending = _battle_pending()
		return {"ok": true, "message": "测试决斗已建立"}

	func is_duel_active() -> bool:
		return active

	func destroy_duel() -> Dictionary:
		active = false
		return {"ok": true, "message": "测试决斗已销毁"}

	func get_duel_state() -> Dictionary:
		return {
			"ok": true,
			"game_over": game_over,
			"winner": winner,
			"win_reason": 1 if game_over else -1,
			"players": {
				"p1": {
					"lp": player_lp,
					"deck": 35,
					"hand": 5,
					"extra": 0,
					"graveyard": 0,
					"banished": 0,
					"hand_cards": [],
					"monster_cards": [_player_attacker()],
					"spell_trap_cards": [],
				},
				"p2": {
					"lp": opponent_lp,
					"deck": 35,
					"hand": 5,
					"extra": 0,
					"graveyard": 0,
					"banished": 0,
					"monster_cards": [_opponent_monster(0), _opponent_monster(2)],
					"spell_trap_cards": [],
				},
			},
		}

	func get_pending_action() -> Dictionary:
		return pending.duplicate(true)

	func submit_battle_action(action_kind: String, index: int) -> Dictionary:
		calls.append({"method": "submit_battle_action", "kind": action_kind, "index": index})
		if _consume_failure("submit_battle_action"):
			return _failure("测试战斗动作失败")
		pending = _yes_no_pending(31)
		return _success("等待攻击路线")

	func submit_yes_no(accepted: bool) -> Dictionary:
		calls.append({"method": "submit_yes_no", "accepted": accepted})
		# 在 Bridge 尚未返回时重入同一个 LP 请求，模拟同帧双击。Main 必须在
		# 第一次调用前持有本地锁，否则这里会递归产生第二次规则响应。
		var callback := reentrant_direct_request
		reentrant_direct_request = Callable()
		if callback.is_valid():
			callback.call()
		if _consume_failure("submit_yes_no"):
			return _failure("测试是/否提交失败")
		if accepted:
			opponent_lp = 3600
			pending = _battle_pending()
		else:
			pending = _select_card_pending(select_options)
		return _success("是/否已提交")

	func submit_card_selection(index: int) -> Dictionary:
		calls.append({"method": "submit_card_selection", "index": index})
		if _consume_failure("submit_card_selection"):
			return _failure("测试目标提交失败")
		pending = _battle_pending()
		return _success("攻击目标已提交")

	func cancel_card_selection() -> Dictionary:
		calls.append({"method": "cancel_card_selection"})
		if _consume_failure("cancel_card_selection"):
			return _failure("测试取消失败")
		pending = _battle_pending()
		return _success("目标选择已取消")

	func method_calls(method_name: String) -> Array[Dictionary]:
		var matched: Array[Dictionary] = []
		for entry in calls:
			if str(entry.get("method", "")) == method_name:
				matched.append(entry)
		return matched

	func _consume_failure(method_name: String) -> bool:
		if fail_next_method != method_name:
			return false
		fail_next_method = ""
		return true

	func _success(message: String) -> Dictionary:
		return {"ok": true, "message": message, "pending_action": pending.duplicate(true)}

	func _failure(message: String) -> Dictionary:
		return {"ok": false, "message": message, "pending_action": pending.duplicate(true)}

	func _battle_pending() -> Dictionary:
		return {
			"kind": "battle",
			"player": 0,
			"message_type": 10,
			"can_enter_main2": true,
			"can_end_battle": true,
			"battle_actions": [
				{
					"card_id": 200001,
					"controller": 0,
					"location": 4,
					"sequence": 0,
					"action_kind": "attack",
					"index": 5,
				},
			],
		}

	func _yes_no_pending(description: int) -> Dictionary:
		return {
			"kind": "yes_no",
			"player": 0,
			"message_type": 13,
			"description": description,
		}

	func _select_card_pending(options: Array) -> Dictionary:
		return {
			"kind": "select_card",
			"player": select_player,
			"message_type": 15,
			"cancelable": select_cancelable,
			"min_select": select_min,
			"max_select": select_max,
			"card_options": options.duplicate(true),
		}

	func _player_attacker() -> Dictionary:
		return {
			"card_id": 200001,
			"controller": 0,
			"location": 4,
			"sequence": 0,
			"cn_name": "测试攻击怪兽",
		}

	func _opponent_monster(sequence: int) -> Dictionary:
		return {
			"card_id": 300001 + sequence,
			"controller": 1,
			"location": 4,
			"sequence": sequence,
			"cn_name": "测试目标怪兽%s" % sequence,
		}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if !await _test_direct_attack_and_submission_lock():
		return
	if !await _test_exact_preview_auto_submission():
		return
	if !await _test_invalid_preview_falls_back_to_real_candidate():
		return
	if !await _test_failed_submission_unlocks_without_losing_target():
		return
	if !await _test_illegal_pending_never_touches_bridge():
		return
	if !await _test_yes_no_and_cancel_failures_keep_current_snapshot():
		return
	if !await _test_cancel_generic_yes_no_restart_and_game_over_cleanup():
		return
	print("攻击目标 Main 编排端到端契约通过")
	quit(0)


func _test_direct_attack_and_submission_lock() -> bool:
	var fake := FakeBridge.new()
	var main = await _mount_main(fake)
	if !_check(main.bridge == fake, "Main 入树时必须保留预先注入的 FakeBridge"):
		main.queue_free()
		return false
	if !_request_attack(main):
		return false
	var board: DuelBoard = main.board
	var opponent_stats_before := board.opponent_stats_label.text
	if !_check(
		"LP 4200" in opponent_stats_before
			and str(fake.pending.kind) == "yes_no"
			and int(fake.pending.description) == 31,
		"攻击动作只能进入 YesNo(31)，不能提前改写 LP"
	):
		return false
	fake.reentrant_direct_request = func() -> void:
		board.direct_attack_requested.emit()
	_click_opponent_lp(board)
	var yes_no_calls := fake.method_calls("submit_yes_no")
	if !_check(
		yes_no_calls.size() == 1
			and bool(yes_no_calls[0].accepted)
			and "LP 3600" in board.opponent_stats_label.text,
		"直击必须只提交一次 true，并只在 Bridge 成功后刷新 LP"
	):
		return false
	await _unmount_main(main)
	return true


func _test_exact_preview_auto_submission() -> bool:
	var fake := FakeBridge.new()
	var main = await _mount_main(fake)
	if !_request_attack(main):
		return false
	var board: DuelBoard = main.board
	board.opponent_monster_zones[2].card_selected.emit(fake._opponent_monster(2))
	var yes_no_calls := fake.method_calls("submit_yes_no")
	var selection_calls := fake.method_calls("submit_card_selection")
	if !_check(
		yes_no_calls.size() == 1
			and !bool(yes_no_calls[0].accepted)
			and selection_calls.size() == 1
			and int(selection_calls[0].index) == 17,
		"预选目标必须以 false 进入 SelectCard，并按完整规则位置自动提交一次"
	):
		return false
	board.attack_target_requested.emit(17)
	if !_check(
		fake.method_calls("submit_card_selection").size() == 1,
		"快照变化后旧候选索引不得再次提交"
	):
		return false
	await _unmount_main(main)
	return true


func _test_invalid_preview_falls_back_to_real_candidate() -> bool:
	var fake := FakeBridge.new()
	fake.select_options = [
		{
			"index": 21,
			"controller": 0,
			"location": 4,
			"sequence": 2,
		},
		{
			"index": 22,
			"controller": 1,
			"location": 8,
			"sequence": 2,
		},
		{
			"index": 23,
			"controller": 1,
			"location": 4,
			"sequence": 0,
		},
	]
	var main = await _mount_main(fake)
	if !_request_attack(main):
		return false
	var board: DuelBoard = main.board
	board.opponent_monster_zones[2].card_selected.emit(fake._opponent_monster(2))
	if !_check(
		fake.method_calls("submit_card_selection").is_empty()
			and board.opponent_monster_zones[0].target_highlight.visible
			and !board.opponent_monster_zones[2].target_highlight.visible,
		"非法预选不得提交索引，必须保留真实候选高亮"
	):
		return false
	board.opponent_monster_zones[0].card_selected.emit(fake._opponent_monster(0))
	var selection_calls := fake.method_calls("submit_card_selection")
	if !_check(
		selection_calls.size() == 1 and int(selection_calls[0].index) == 23,
		"合法候选点击必须提交当前快照的候选索引"
	):
		return false
	await _unmount_main(main)
	return true


func _test_failed_submission_unlocks_without_losing_target() -> bool:
	var fake := FakeBridge.new()
	fake.select_options = [
		{
			"index": 29,
			"controller": 1,
			"location": 4,
			"sequence": 0,
		},
	]
	var main = await _mount_main(fake)
	if !_request_attack(main):
		return false
	var board: DuelBoard = main.board
	board.opponent_monster_zones[2].card_selected.emit(fake._opponent_monster(2))
	fake.fail_next_method = "submit_card_selection"
	board.opponent_monster_zones[0].card_selected.emit(fake._opponent_monster(0))
	if !_check(
		fake.method_calls("submit_card_selection").size() == 1
			and board.opponent_monster_zones[0].target_highlight.visible
			and "测试目标提交失败" in board.status_label.text,
		"Bridge 失败必须保留当前目标快照并显示中文诊断"
	):
		return false
	board.opponent_monster_zones[0].card_selected.emit(fake._opponent_monster(0))
	if !_check(
		fake.method_calls("submit_card_selection").size() == 2,
		"Bridge 失败后必须解除本地提交锁以允许重试"
	):
		return false
	await _unmount_main(main)
	return true


func _test_illegal_pending_never_touches_bridge() -> bool:
	var fake := FakeBridge.new()
	var main = await _mount_main(fake)
	var board: DuelBoard = main.board
	var matching_options := [
		{
			"index": 41,
			"controller": 1,
			"location": 4,
			"sequence": 2,
		},
	]
	for invalid_shape in [
		{"player": 1, "min": 1, "max": 1},
		{"player": 0, "min": 2, "max": 2},
	]:
		main._pending_attack_target_preview = {
			"controller": 1,
			"location": 4,
			"sequence": 2,
		}
		fake.select_player = int(invalid_shape.player)
		fake.select_min = int(invalid_shape.min)
		fake.select_max = int(invalid_shape.max)
		fake.pending = fake._select_card_pending(matching_options)
		main._refresh_board("测试非法选择决策门禁")
		board.attack_target_requested.emit(41)
		board.card_selection_cancel_requested.emit()
	if !_check(
		fake.method_calls("submit_card_selection").is_empty()
			and fake.method_calls("cancel_card_selection").is_empty()
			and main._pending_attack_target_preview.is_empty(),
		"对手或非单选 SelectCard 不得自动提交，也不得接受残留目标/取消信号"
	):
		return false

	fake.select_player = 0
	fake.select_min = 1
	fake.select_max = 1
	fake.select_cancelable = false
	fake.pending = fake._select_card_pending(matching_options)
	main._refresh_board("测试不可取消决策门禁")
	board.card_selection_cancel_requested.emit()
	if !_check(
		fake.method_calls("cancel_card_selection").is_empty(),
		"不可取消的 SelectCard 不得把残留取消信号提交给 Bridge"
	):
		return false

	fake.pending = fake._yes_no_pending(99)
	fake.pending.player = 1
	main._refresh_board("测试对手确认门禁")
	board.yes_no_requested.emit(true)
	if !_check(
		fake.method_calls("submit_yes_no").is_empty(),
		"对手 YesNo 不得把残留确认信号提交给 Bridge"
	):
		return false
	await _unmount_main(main)
	return true


func _test_yes_no_and_cancel_failures_keep_current_snapshot() -> bool:
	var yes_no_fake := FakeBridge.new()
	var yes_no_main = await _mount_main(yes_no_fake)
	if !_request_attack(yes_no_main):
		return false
	var yes_no_board: DuelBoard = yes_no_main.board
	yes_no_fake.fail_next_method = "submit_yes_no"
	yes_no_board.opponent_monster_zones[2].card_selected.emit(
		yes_no_fake._opponent_monster(2)
	)
	if !_check(
		yes_no_fake.method_calls("submit_yes_no").size() == 1
			and str(yes_no_fake.pending.kind) == "yes_no"
			and yes_no_board.direct_attack_highlight.visible
			and "测试是/否提交失败" in yes_no_board.status_label.text,
		"YesNo 失败必须保留攻击路线快照和入口"
	):
		return false
	yes_no_board.opponent_monster_zones[2].card_selected.emit(
		yes_no_fake._opponent_monster(2)
	)
	if !_check(
		yes_no_fake.method_calls("submit_yes_no").size() == 2
			and yes_no_fake.method_calls("submit_card_selection").size() == 1,
		"YesNo 失败后必须解除提交锁并允许完整重试"
	):
		return false
	await _unmount_main(yes_no_main)

	var cancel_fake := FakeBridge.new()
	cancel_fake.select_options = [
		{
			"index": 43,
			"controller": 1,
			"location": 4,
			"sequence": 0,
		},
	]
	var cancel_main = await _mount_main(cancel_fake)
	if !_request_attack(cancel_main):
		return false
	var cancel_board: DuelBoard = cancel_main.board
	cancel_board.opponent_monster_zones[2].card_selected.emit(
		cancel_fake._opponent_monster(2)
	)
	cancel_fake.fail_next_method = "cancel_card_selection"
	cancel_board.action_box.get_child(0).pressed.emit()
	if !_check(
		cancel_fake.method_calls("cancel_card_selection").size() == 1
			and cancel_board.opponent_monster_zones[0].target_highlight.visible
			and cancel_board.action_box.visible
			and "测试取消失败" in cancel_board.status_label.text,
		"取消失败必须保留 SelectCard 快照、合法目标和取消入口"
	):
		return false
	cancel_board.action_box.get_child(0).pressed.emit()
	if !_check(
		cancel_fake.method_calls("cancel_card_selection").size() == 2,
		"取消失败后必须解除提交锁并允许重试"
	):
		return false
	await _unmount_main(cancel_main)
	return true


func _test_cancel_generic_yes_no_restart_and_game_over_cleanup() -> bool:
	var fake := FakeBridge.new()
	fake.select_options = [
		{
			"index": 31,
			"controller": 1,
			"location": 4,
			"sequence": 0,
		},
	]
	var main = await _mount_main(fake)
	if !_request_attack(main):
		return false
	var board: DuelBoard = main.board
	board.opponent_monster_zones[2].card_selected.emit(fake._opponent_monster(2))
	if !_check(
		main._pending_attack_target_preview.is_empty(),
		"预选与真实候选不匹配时必须立即清除旧规则位置"
	):
		return false
	main._pending_attack_target_preview = {
		"controller": 1,
		"location": 4,
		"sequence": 2,
	}
	board.action_box.get_child(0).pressed.emit()
	if !_check(
		fake.method_calls("cancel_card_selection").size() == 1
			and main._pending_attack_target_preview.is_empty(),
		"显式取消必须提交 Bridge 并清除攻击目标预选"
	):
		return false

	main._pending_attack_target_preview = {
		"controller": 1,
		"location": 4,
		"sequence": 2,
	}
	fake.pending = fake._yes_no_pending(99)
	main._refresh_board("测试通用确认")
	if !_check(
		main._pending_attack_target_preview.is_empty()
			and board.confirmation_overlay.visible,
		"非攻击 YesNo 快照必须清除预选并保留通用确认"
	):
		return false
	var yes_no_count_before := fake.method_calls("submit_yes_no").size()
	board.confirmation_buttons.get_child(1).pressed.emit()
	var yes_no_calls := fake.method_calls("submit_yes_no")
	if !_check(
		yes_no_calls.size() == yes_no_count_before + 1
			and !bool(yes_no_calls.back().accepted),
		"通用 YesNo 必须原样提交用户选择"
	):
		return false

	main._pending_attack_target_preview = {
		"controller": 1,
		"location": 4,
		"sequence": 2,
	}
	fake.pending = fake._battle_pending()
	main._refresh_board("测试重新开局")
	board.restart_button.pressed.emit()
	board.confirmation_buttons.get_child(0).pressed.emit()
	if !_check(
		main._pending_attack_target_preview.is_empty()
			and str(fake.pending.kind) == "battle"
			and fake.opponent_lp == 4200,
		"真实重开按钮路径必须清除预选并采用新决斗初始快照"
	):
		return false

	main._pending_attack_target_preview = {
		"controller": 1,
		"location": 4,
		"sequence": 0,
	}
	fake.game_over = true
	fake.winner = 0
	fake.pending = fake._select_card_pending(fake.select_options)
	main._refresh_board("测试终局清理")
	var terminal_selection_count := fake.method_calls("submit_card_selection").size()
	var terminal_cancel_count := fake.method_calls("cancel_card_selection").size()
	board.attack_target_requested.emit(31)
	board.card_selection_cancel_requested.emit()
	if !_check(
		main._pending_attack_target_preview.is_empty()
			and !board.opponent_monster_zones[0].target_highlight.visible
			and !board.action_box.visible
			and fake.method_calls("submit_card_selection").size() == terminal_selection_count
			and fake.method_calls("cancel_card_selection").size() == terminal_cancel_count,
		"终局快照必须清除预选和高亮，并拒绝残留候选或取消信号"
	):
		return false
	await _unmount_main(main)
	return true


func _mount_main(fake: FakeBridge):
	var main = MAIN_SCENE.instantiate()
	# 注入必须发生在入树前；真实运行 bridge 为空，Main 仍自行构造原生 Bridge。
	main.bridge = fake
	root.add_child(main)
	await process_frame
	return main


func _unmount_main(main) -> void:
	main.queue_free()
	await process_frame
	await process_frame


func _request_attack(main) -> bool:
	var board: DuelBoard = main.board
	var attacker: Dictionary = main.bridge._player_attacker()
	board.player_monster_zones[0].card_selected.emit(attacker)
	for child in board.action_box.get_children():
		if child is Button and str(child.text) == "攻击":
			child.pressed.emit()
			return _check(
				str(main.bridge.pending.kind) == "yes_no"
					and int(main.bridge.pending.description) == 31,
				"攻击按钮必须通过 Main 把真实战斗动作提交给 Bridge"
			)
	return _check(false, "真实 DuelBoard 未生成攻击动作按钮")


func _click_opponent_lp(board: DuelBoard) -> void:
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	board.opponent_status_surface.gui_input.emit(click)


func _check(condition: bool, message: String) -> bool:
	if condition:
		return true
	push_error(message)
	quit(1)
	return false
