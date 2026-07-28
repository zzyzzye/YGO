extends SceneTree

const MAIN_SCENE = preload("res://src/main/main.tscn")


# FakeBridge 只替换真实 OCGCore 边界；Main、DuelBoard、手牌、场区和按钮都使用
# 入树的生产节点。候选字段完整镜像 GDExtension 契约，测试不会自行解释原始消息。
class FakeBridge:
	extends RefCounted

	var active := false
	var game_over := false
	var winner := -1
	var forced := false
	var pending: Dictionary = {}
	var calls: Array[Dictionary] = []
	var fail_next_method := ""
	var reject_next_method := ""
	var continue_with_same_shape := false
	var reentrant_request := Callable()
	var setup_pending_kind := "select_chain"
	var options: Array = []

	func _init() -> void:
		options = _all_location_options()
		pending = _chain_pending(options, false)

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
		game_over = false
		winner = -1
		pending = (
			_chain_pending(options, forced)
			if setup_pending_kind == "select_chain"
			else _idle_pending()
		)
		return {"ok": true, "message": "测试决斗已建立"}

	func is_duel_active() -> bool:
		return active

	func destroy_duel() -> Dictionary:
		active = false
		return {"ok": true, "message": "测试决斗已销毁"}

	func get_pending_action() -> Dictionary:
		return pending.duplicate(true)

	func get_duel_state() -> Dictionary:
		return {
			"ok": true,
			"game_over": game_over,
			"winner": winner,
			"players": {
				"p1": {
					"lp": 8000,
					"deck": 34,
					"hand": 2,
					"extra": 0,
					"graveyard": 0,
					"banished": 0,
					"hand_cards": [
						_card(110001, 2, 0, "测试手牌甲"),
						_card(110002, 2, 1, "测试手牌乙"),
					],
					"monster_cards": [_card(120001, 4, 0, "己方怪兽")],
					"spell_trap_cards": [_card(130001, 8, 1, "己方魔陷")],
				},
				"p2": {
					"lp": 8000,
					"deck": 35,
					"hand": 5,
					"extra": 0,
					"graveyard": 0,
					"banished": 0,
					"hand_cards": [],
					"monster_cards": [_card(220001, 4, 2, "对手怪兽")],
					# 对手里侧魔陷的真实身份不会进入 Godot；公开位置仍足以映射候选。
					"spell_trap_cards": [{"sequence": 3}],
				},
			},
		}

	func submit_chain(index: int) -> Dictionary:
		calls.append({"method": "submit_chain", "index": index})
		var callback := reentrant_request
		reentrant_request = Callable()
		if callback.is_valid():
			callback.call()
		if _consume_failure("submit_chain"):
			return _failure("测试连锁提交失败")
		if _consume_rejection("submit_chain"):
			return _rejection("OCGCore 拒绝测试连锁响应")
		if continue_with_same_shape:
			continue_with_same_shape = false
			var next_options := [
				_chain_option(70, 110001, 0, 2, 0, 7070),
			]
			options = next_options
			pending = _chain_pending(next_options, false)
		else:
			pending = _idle_pending()
		return _success("连锁已提交")

	func pass_chain() -> Dictionary:
		calls.append({"method": "pass_chain"})
		if _consume_failure("pass_chain"):
			return _failure("测试不连锁提交失败")
		if _consume_rejection("pass_chain"):
			return _rejection("OCGCore 拒绝测试不连锁响应")
		pending = _idle_pending()
		return _success("已选择不连锁")

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

	func _consume_rejection(method_name: String) -> bool:
		if reject_next_method != method_name:
			return false
		reject_next_method = ""
		return true

	func _success(message: String) -> Dictionary:
		return {
			"ok": true,
			"response_rejected": false,
			"message": message,
			"pending_action": pending.duplicate(true),
		}

	func _rejection(message: String) -> Dictionary:
		return {
			"ok": true,
			"response_rejected": true,
			"message": message,
			"pending_action": pending.duplicate(true),
		}

	func _failure(message: String) -> Dictionary:
		return {
			"ok": false,
			"response_rejected": false,
			"message": message,
			"pending_action": pending.duplicate(true),
		}

	func _chain_pending(chain_options: Array, chain_forced: bool) -> Dictionary:
		return {
			"kind": "select_chain",
			"player": 0,
			"message_type": 16,
			"chain_forced": chain_forced,
			"chain_options": chain_options.duplicate(true),
		}

	func _idle_pending() -> Dictionary:
		return {
			"kind": "idle",
			"player": 0,
			"message_type": 11,
			"can_end_turn": true,
			"idle_actions": [],
		}

	func _all_location_options() -> Array:
		return [
			_chain_option(7, 110001, 0, 2, 0, 1001),
			_chain_option(8, 110001, 0, 2, 0, 1002),
			_chain_option(9, 120001, 0, 4, 0, 2001),
			_chain_option(10, 130001, 0, 8, 1, 3001),
			_chain_option(11, 220001, 1, 4, 2, 4001),
			{
				"index": 12,
				"controller": 1,
				"location": 8,
				"sequence": 3,
				"position": 8,
				"description": 5001,
				"client_mode": 0,
			},
		]

	func _chain_option(
		index: int,
		card_id: int,
		controller: int,
		location: int,
		sequence: int,
		description: int
	) -> Dictionary:
		return {
			"index": index,
			"card_id": card_id,
			"controller": controller,
			"location": location,
			"sequence": sequence,
			"position": 1,
			"description": description,
			"client_mode": 0,
		}

	func _card(
		card_id: int,
		location: int,
		sequence: int,
		card_name: String
	) -> Dictionary:
		return {
			"card_id": card_id,
			"location": location,
			"sequence": sequence,
			"cn_name": card_name,
		}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if !await _test_all_locations_and_same_card_effects():
		return
	if !await _test_forced_window_has_no_pass():
		return
	if !await _test_incomplete_mapping_rejects_entire_ui():
		return
	if !await _test_stale_field_nodes_do_not_reenter():
		return
	if !await _test_failure_retry_and_stale_generation():
		return
	if !await _test_pass_failure_retry_and_forced_gate():
		return
	if !await _test_game_over_and_restart_cleanup():
		return
	print("连锁候选情境交互测试通过")
	quit(0)


func _test_all_locations_and_same_card_effects() -> bool:
	var fake := FakeBridge.new()
	var main = await _mount_main(fake)
	var board: DuelBoard = main.board
	var candidate_hand_card: CardView = board.player_hand.get_child(0)
	var non_candidate_hand_card: CardView = board.player_hand.get_child(1)
	if !_check(
		board._rule_decision_kind == "select_chain"
			and _is_hand_chainable(board.player_hand, 0)
			and !_is_hand_chainable(board.player_hand, 1)
			and !candidate_hand_card.card_data.has("controller")
			and candidate_hand_card.self_modulate.is_equal_approx(
				candidate_hand_card.get_theme_color(
					&"candidate_modulate",
					&"ChainCandidateHand"
				)
			)
			and non_candidate_hand_card.self_modulate.is_equal_approx(
				non_candidate_hand_card.get_theme_color(
					&"non_candidate_modulate",
					&"ChainCandidateHand"
				)
			)
			and !candidate_hand_card.self_modulate.is_equal_approx(
				non_candidate_hand_card.self_modulate
			)
			and _is_zone_chainable(board.player_monster_zones[0])
			and _is_zone_chainable(board.player_spell_zones[1])
			and _is_zone_chainable(board.opponent_monster_zones[2])
			and _is_zone_chainable(board.opponent_spell_zones[3])
			and _button_texts(board.action_box) == ["不连锁"],
		"真实无 controller 手牌必须可映射，且候选/非候选 CardView 必须呈现不同明暗"
	):
		return false

	var hand_card: CardView = candidate_hand_card
	hand_card.pressed.emit()
	if !_check(
		_button_texts(board.action_box) == [
			"发动效果 1（描述 1001）",
			"发动效果 2（描述 1002）",
			"不连锁",
		],
		"同一卡片多个连锁候选必须生成彼此独立且可区分的效果按钮"
	):
		return false

	# HandView 会先处理自身选择态再把卡数据交给 DuelBoard。点击非候选手牌时
	# 必须同步撤销旧效果按钮，避免视觉选中乙却仍能提交甲的连锁效果。
	var non_candidate_card: CardView = board.player_hand.get_child(1)
	non_candidate_card.pressed.emit()
	if !_check(
		_button_texts(board.action_box) == ["不连锁"]
			and !non_candidate_card.selection_frame.visible
			and board.selected_card.is_empty(),
		"点击非候选手牌必须清除旧候选选择，只保留当前窗口的不连锁入口"
	):
		return false
	hand_card.pressed.emit()
	if !_check(
		_button_texts(board.action_box).size() == 3,
		"非候选手牌清理后必须仍可重新选择合法候选"
	):
		return false
	board.action_box.get_child(1).pressed.emit()
	if !_check(
		fake.method_calls("submit_chain") == [{"method": "submit_chain", "index": 8}]
			and board._rule_decision_kind == "none"
			and !_is_hand_chainable(board.player_hand, 0),
		"效果按钮必须提交对应稳定索引，并在成功快照后清除全部连锁表现"
	):
		return false
	await _unmount_main(main)

	# 每一种场区都通过真实卡节点进入同一情境按钮路径；对手里侧卡仅使用公开位置。
	for entry in [
		{"row": "player_monster", "sequence": 0, "index": 9},
		{"row": "player_spell", "sequence": 1, "index": 10},
		{"row": "opponent_monster", "sequence": 2, "index": 11},
		{"row": "opponent_spell", "sequence": 3, "index": 12},
	]:
		var zone_fake := FakeBridge.new()
		var zone_main = await _mount_main(zone_fake)
		var zone_board: DuelBoard = zone_main.board
		var zone: ZoneView = _zone_for_entry(zone_board, entry)
		var card: CardView = zone.card_container.get_child(0)
		card.pressed.emit()
		if !_check(
			_button_texts(zone_board.action_box) == [
				"发动效果 1（描述 %s）" % _description_for_index(int(entry.index)),
				"不连锁",
			],
			"%s 候选必须通过真实卡节点打开情境按钮" % entry.row
		):
			return false
		zone_board.action_box.get_child(0).pressed.emit()
		if !_check(
			int(zone_fake.method_calls("submit_chain")[0].index) == int(entry.index),
			"%s 情境按钮必须提交自身候选索引" % entry.row
		):
			return false
		await _unmount_main(zone_main)
	return true


func _test_forced_window_has_no_pass() -> bool:
	var fake := FakeBridge.new()
	fake.forced = true
	fake.pending = fake._chain_pending(fake.options, true)
	var main = await _mount_main(fake)
	var board: DuelBoard = main.board
	if !_check(
		_button_texts(board.action_box).is_empty()
			and !board.action_box.visible
			and board.status_label.text == "必须选择一个连锁效果",
		"强制连锁必须显示中文门禁提示且不创建跳过按钮"
	):
		return false
	var generation: int = board._rule_decision_generation
	board.chain_pass_requested.emit(generation)
	if !_check(
		fake.method_calls("pass_chain").is_empty(),
		"强制窗口即使收到人工残留信号也不得调用 Bridge 跳过"
	):
		return false
	await _unmount_main(main)
	return true


func _test_incomplete_mapping_rejects_entire_ui() -> bool:
	var fake := FakeBridge.new()
	fake.options.append(fake._chain_option(13, 999999, 0, 4, 4, 6001))
	fake.pending = fake._chain_pending(fake.options, false)
	var main = await _mount_main(fake)
	var board: DuelBoard = main.board
	var hand_card: CardView = board.player_hand.get_child(0)
	hand_card.pressed.emit()
	if !_check(
		board._rule_decision_kind == "select_chain_unmapped"
			and !_is_hand_chainable(board.player_hand, 0)
			and !_is_zone_chainable(board.player_monster_zones[0])
			and !_is_zone_chainable(board.player_spell_zones[1])
			and !_is_zone_chainable(board.opponent_monster_zones[2])
			and !_is_zone_chainable(board.opponent_spell_zones[3])
			and board.action_box.get_child_count() == 0
			and !board.action_box.visible
			and board.status_label.text
				== "连锁候选无法完整映射到当前场面，请等待状态刷新",
		"任一候选不可映射时必须整组拒绝，不能留下部分高亮或可提交按钮"
	):
		return false
	board.chain_requested.emit(7, board._rule_decision_generation)
	board.chain_pass_requested.emit(board._rule_decision_generation)
	if !_check(
		fake.method_calls("submit_chain").is_empty()
			and fake.method_calls("pass_chain").is_empty()
			and str(main._current_pending_action.kind) == "select_chain",
		"整组不可映射时必须保留核心 pending，人工信号也不得触碰 Bridge"
	):
		return false
	await _unmount_main(main)
	return true


func _test_stale_field_nodes_do_not_reenter() -> bool:
	var fake := FakeBridge.new()
	var main = await _mount_main(fake)
	var board: DuelBoard = main.board
	var stale_player_monster: CardView = (
		board.player_monster_zones[0].card_container.get_child(0)
	)
	var stale_opponent_monster: CardView = (
		board.opponent_monster_zones[2].card_container.get_child(0)
	)
	var stale_hidden_spell: CardView = (
		board.opponent_spell_zones[3].card_container.get_child(0)
	)
	main._refresh_board("测试同形连锁重绘")
	# 三类旧场区卡分别经过 ZoneView 转发、公开对手路由和隐藏卡额外 pressed
	# 路由；刷新后它们都已退休，不能重新打开新代次中的合法效果按钮。
	stale_player_monster.pressed.emit()
	stale_opponent_monster.pressed.emit()
	stale_hidden_spell.pressed.emit()
	if !_check(
		_button_texts(board.action_box) == ["不连锁"]
			and fake.method_calls("submit_chain").is_empty(),
		"旧己方场卡、旧公开对手卡和旧里侧对手卡均不得重入新代次"
	):
		return false
	await _unmount_main(main)
	return true


func _test_failure_retry_and_stale_generation() -> bool:
	var fake := FakeBridge.new()
	fake.options = [fake._chain_option(7, 110001, 0, 2, 0, 1001)]
	fake.pending = fake._chain_pending(fake.options, false)
	var main = await _mount_main(fake)
	var board: DuelBoard = main.board
	var stale_card: CardView = board.player_hand.get_child(0)
	stale_card.pressed.emit()
	var stale_button: Button = board.action_box.get_child(0)
	var stale_generation: int = board._rule_decision_generation

	fake.fail_next_method = "submit_chain"
	stale_button.pressed.emit()
	if !_check(
		fake.method_calls("submit_chain").size() == 1
			and board.action_box.visible
			and _button_texts(board.action_box)[0] == "发动效果 1（描述 1001）"
			and "测试连锁提交失败" in board.status_label.text,
		"Bridge 本地失败必须释放提交锁并保留当前高亮和效果入口"
	):
		return false

	fake.reject_next_method = "submit_chain"
	stale_button.pressed.emit()
	if !_check(
		fake.method_calls("submit_chain").size() == 2
			and _is_hand_chainable(board.player_hand, 0)
			and board._rule_decision_generation == stale_generation
			and "OCGCore 拒绝了响应，请重新选择" in board.status_label.text,
		"MSG_RETRY 必须按同一 pending 和同一决策代次恢复完整连锁入口"
	):
		return false

	var current_card: CardView = board.player_hand.get_child(0)
	current_card.pressed.emit()
	var current_button: Button = board.action_box.get_child(0)
	var current_generation: int = board._rule_decision_generation
	fake.continue_with_same_shape = true
	fake.reentrant_request = func() -> void:
		# 模拟用户在同步 Bridge 调用尚未返回时再次点击同一个真实动态按钮。
		# 第二次 pressed 会完整经过 DuelBoard 信号转发，必须被 Main 提交锁拦截。
		current_button.pressed.emit()
	current_button.pressed.emit()
	if !_check(
		fake.method_calls("submit_chain").size() == 3
			and str(fake.pending.kind) == "select_chain"
			and int(fake.pending.chain_options[0].index) == 70
			and board._rule_decision_generation == current_generation + 1,
		"重复点击同一真实效果按钮只能提交一次，下一份同形决策必须使用新代次"
	):
		return false

	# 旧卡、旧按钮与旧代次人工信号都可能在 queue_free 前重入；三条路径均不得
	# 把上一份 index 提交给新的同形决策。
	stale_card.pressed.emit()
	stale_button.pressed.emit()
	current_button.pressed.emit()
	board.chain_requested.emit(70, stale_generation)
	board.chain_requested.emit(7, current_generation)
	if !_check(
		fake.method_calls("submit_chain").size() == 3,
		"旧卡、旧按钮和旧代次信号不得提交下一份同形连锁决策"
	):
		return false
	await _unmount_main(main)
	return true


func _test_pass_failure_retry_and_forced_gate() -> bool:
	var fake := FakeBridge.new()
	fake.options = [fake._chain_option(7, 110001, 0, 2, 0, 1001)]
	fake.pending = fake._chain_pending(fake.options, false)
	var main = await _mount_main(fake)
	var board: DuelBoard = main.board
	var background_click := InputEventMouseButton.new()
	background_click.button_index = MOUSE_BUTTON_LEFT
	background_click.pressed = true
	board.player_hand.get_child(0).pressed.emit()
	board._on_background_input(background_click)
	board.phase_button.pressed.emit()
	board.restart_button.pressed.emit()
	board.exit_button.pressed.emit()
	if !_check(
		_button_texts(board.action_box) == ["不连锁"]
			and !board.confirmation_overlay.visible
			and str(fake.pending.kind) == "select_chain",
		"背景、阶段、重开和退出入口不得覆盖活动连锁决策"
	):
		return false
	fake.fail_next_method = "pass_chain"
	board.action_box.get_child(0).pressed.emit()
	if !_check(
		fake.method_calls("pass_chain").size() == 1
			and board.action_box.visible
			and "测试不连锁提交失败" in board.status_label.text,
		"不连锁本地失败必须保留当前入口供重试"
	):
		return false
	fake.reject_next_method = "pass_chain"
	board.action_box.get_child(0).pressed.emit()
	await process_frame
	if !_check(
		fake.method_calls("pass_chain").size() == 2
			and _button_texts(board.action_box) == ["不连锁"]
			and "OCGCore 拒绝了响应，请重新选择" in board.status_label.text,
		"不连锁收到 MSG_RETRY 后必须恢复同一可选窗口"
	):
		return false
	board.action_box.get_child(0).pressed.emit()
	if !_check(
		fake.method_calls("pass_chain").size() == 3
			and board._rule_decision_kind == "none",
		"不连锁成功后必须刷新场面并清除旧入口"
	):
		return false
	await _unmount_main(main)
	return true


func _test_game_over_and_restart_cleanup() -> bool:
	var fake := FakeBridge.new()
	var main = await _mount_main(fake)
	var board: DuelBoard = main.board
	var stale_generation: int = board._rule_decision_generation
	fake.game_over = true
	fake.winner = 0
	main._refresh_board("测试终局")
	board.chain_requested.emit(7, stale_generation)
	board.chain_pass_requested.emit(stale_generation)
	if !_check(
		main._current_pending_action.is_empty()
			and board._rule_decision_kind == "none"
			and !_is_hand_chainable(board.player_hand, 0)
			and !board.action_box.visible
			and fake.method_calls("submit_chain").is_empty()
			and fake.method_calls("pass_chain").is_empty(),
		"终局必须清除 pending 的本地副本、连锁高亮和全部过期输入"
	):
		return false

	fake.game_over = false
	fake.setup_pending_kind = "idle"
	fake.pending = fake._chain_pending(fake.options, false)
	main._refresh_board("重开前恢复连锁")
	if !_check(board._rule_decision_kind == "select_chain", "重开验收必须从活动连锁入口开始"):
		return false
	board.restart_requested.emit()
	if !_check(
		str(fake.pending.kind) == "idle"
			and board._rule_decision_kind == "none"
			and !_is_hand_chainable(board.player_hand, 0)
			and !board.action_box.visible,
		"重新开局必须采用新快照并清除上一局全部连锁表现"
	):
		return false
	await _unmount_main(main)
	return true


func _mount_main(fake: FakeBridge):
	var main = MAIN_SCENE.instantiate()
	main.bridge = fake
	root.add_child(main)
	await process_frame
	await process_frame
	return main


func _unmount_main(main) -> void:
	main.queue_free()
	await process_frame
	await process_frame


func _is_hand_chainable(hand: HandView, sequence: int) -> bool:
	for child in hand.get_children():
		if child is CardView and int(child.card_data.get("sequence", -1)) == sequence:
			return (
				hand._chain_candidate_sequences.has(sequence)
				and child.self_modulate.is_equal_approx(
					child.get_theme_color(
						&"candidate_modulate",
						&"ChainCandidateHand"
					)
				)
			)
	return false


func _is_zone_chainable(zone: ZoneView) -> bool:
	return (
		zone.target_highlight.visible
		and zone.target_highlight.theme_type_variation == &"ChainCandidateHighlight"
	)


func _zone_for_entry(board: DuelBoard, entry: Dictionary) -> ZoneView:
	match str(entry.row):
		"player_monster":
			return board.player_monster_zones[int(entry.sequence)]
		"player_spell":
			return board.player_spell_zones[int(entry.sequence)]
		"opponent_monster":
			return board.opponent_monster_zones[int(entry.sequence)]
		_:
			return board.opponent_spell_zones[int(entry.sequence)]


func _description_for_index(index: int) -> int:
	return {
		9: 2001,
		10: 3001,
		11: 4001,
		12: 5001,
	}.get(index, -1)


func _button_texts(container: Control) -> Array[String]:
	var texts: Array[String] = []
	for child in container.get_children():
		if child is Button:
			texts.append(child.text)
	return texts


func _check(condition: bool, message: String) -> bool:
	if condition:
		return true
	push_error(message)
	quit(1)
	return false
