extends SceneTree

const MAIN_SCENE = preload("res://src/main/main.tscn")
const VIEWPORT_SIZE := Vector2i(1920, 1080)

var _input_viewport: SubViewport


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# 本测试不替换规则桥接：Main 会按生产路径实例化 YgoCoreBridge、建立固定种子
	# 决斗并读取真实 OCGCore 快照。SubViewport 只提供可重复的 GUI 命中环境。
	if !ClassDB.class_exists("YgoCoreBridge"):
		_fail("缺少生产 YgoCoreBridge，无法执行真实区域选择流程")
		return
	_input_viewport = SubViewport.new()
	_input_viewport.size = VIEWPORT_SIZE
	_input_viewport.gui_disable_input = false
	_input_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_input_viewport)
	var main = MAIN_SCENE.instantiate()
	_input_viewport.add_child(main)
	await process_frame
	await process_frame

	var board: DuelBoard = main.board
	if main.bridge == null or main.bridge.get_class() != "YgoCoreBridge":
		_fail("Main 必须使用生产 YgoCoreBridge，不能以测试替身绕过真实核心")
		return
	if str(main._current_pending_action.get("kind", "none")) != "idle":
		_fail("固定种子真实决斗必须从本地玩家 Idle 决策开始")
		return

	# 从真实手牌与 OCGCore IdleAction 的交集选择通常召唤；不依赖手牌下标，
	# 避免牌库顺序调整后点击到另一张视觉卡片。
	var summon_action := _find_action(board.current_actions, "normal_summon")
	if summon_action.is_empty():
		_fail("固定种子真实决斗缺少通常召唤候选")
		return
	var summon_card := _find_hand_card(board.player_hand, summon_action)
	if summon_card == null:
		_fail("通常召唤候选没有对应的生产 CardView")
		return
	var summoned_card_id := int(summon_card.card_data.get("card_id", 0))
	var opening_hand_count := board.player_hand.get_child_count()
	await _viewport_click(summon_card)
	var summon_button := _find_button(board.action_box, "通常召唤")
	if summon_button == null:
		_fail("点击真实手牌后没有出现通常召唤按钮")
		return
	await _viewport_click(summon_button)
	if (
		board._rule_decision_kind != "select_place"
		or str(main._current_pending_action.get("kind", "none")) != "select_place"
	):
		_fail("真实通常召唤必须进入 SelectPlace 并显示原生卡位候选")
		return

	var place_options: Array = main._current_pending_action.get("place_options", [])
	if place_options.size() < 2:
		_fail("真实 SelectPlace 至少需要两个候选，才能验证非首项提交")
		return
	var selected_option: Dictionary = place_options.back().duplicate(true)
	if selected_option == place_options.front():
		_fail("非首项区域候选不得退化为候选表首项")
		return
	var selected_zone := _zone_for_option(board, selected_option)
	if selected_zone == null:
		_fail("非首项真实候选没有映射到生产 ZoneView")
		return
	var decision_generation: int = board._rule_decision_generation
	var pending_before_invalid: Dictionary = main.bridge.get_pending_action()

	# 伪造三元组和旧代次都直接经过 Main 的生产信号入口；它们不得触碰
	# YgoCoreBridge，也不得让真实 OCGCore pending 或候选高亮发生变化。
	board.place_requested.emit(0, 4, 5, decision_generation)
	board.place_requested.emit(
		int(selected_option.controller),
		int(selected_option.location),
		int(selected_option.sequence),
		decision_generation - 1
	)
	await process_frame
	if (
		main.bridge.get_pending_action() != pending_before_invalid
		or board._rule_decision_generation != decision_generation
		or !selected_zone.target_highlight.visible
	):
		_fail("伪造区域或旧代次不得改变真实核心决策与候选高亮")
		return

	# ZoneView 明确忽略 double_click 标记；这能阻止系统生成的第二次按下把同一
	# 候选重复提交。忽略后真实 pending 与高亮必须仍可供一次正常单击使用。
	await _viewport_click(selected_zone, true)
	if (
		main.bridge.get_pending_action() != pending_before_invalid
		or !selected_zone.target_highlight.visible
		or board._rule_decision_generation != decision_generation
	):
		_fail("区域双击不得提交或退休当前真实候选")
		return

	# OCGCore 对合法候选不会主动产生 Retry；这里复用真实 Bridge 当前 pending，
	# 经 Main 的结构化拒绝恢复入口重建已经退休的原生 ZoneView。核心状态没有被
	# 测试伪造，且 UI 必须保留同一代次，随后仍向生产 Bridge 提交。
	board._retire_place_candidates()
	if !main._restore_rejected_response({
		"response_rejected": true,
		"pending_action": pending_before_invalid,
	}):
		_fail("Main 必须识别结构化 Retry 并恢复区域候选")
		return
	if (
		board._rule_decision_generation != decision_generation
		or !selected_zone.target_highlight.visible
		or main.bridge.get_pending_action() != pending_before_invalid
	):
		_fail("Retry 必须保留代次、重建高亮且不改写真实核心 pending")
		return

	await _viewport_click(selected_zone)
	await process_frame
	if board._rule_decision_generation == decision_generation:
		_fail("真实区域提交成功后必须推进决策代次")
		return
	var state_after_place: Dictionary = main.bridge.get_duel_state()
	var placed_cards: Array = state_after_place.players.p1.monster_cards
	var placed_card := _find_card_at_sequence(
		placed_cards,
		int(selected_option.sequence)
	)
	if (
		!bool(state_after_place.get("ok", false))
		or placed_card.is_empty()
		or int(placed_card.get("card_id", 0)) != summoned_card_id
		or board.player_hand.get_child_count() != opening_hand_count - 1
	):
		_fail("真实 OCGCore 必须把所选卡放入非首项 sequence，并刷新生产场景")
		return

	# 重开也必须走真实系统按钮、确认按钮与 Main 生命周期。旧代次信号在新
	# DuelSession 建立后仍不得影响 pending，且旧高亮必须全部清除。
	if board._rule_decision_kind != "none":
		_fail("区域提交结算后应回到可重开的普通决策界面")
		return
	await _viewport_click(board.restart_button)
	var confirm_button := _find_button(board.confirmation_buttons, "确认")
	if confirm_button == null:
		_fail("真实重开按钮必须显示生产确认浮层")
		return
	await _viewport_click(confirm_button)
	await process_frame
	var pending_after_restart: Dictionary = main.bridge.get_pending_action()
	if (
		str(pending_after_restart.get("kind", "none")) != "idle"
		or _has_place_highlight(board)
		or board.player_hand.get_child_count() != opening_hand_count
	):
		_fail("真实重开必须清除区域高亮并恢复新局初始手牌")
		return
	board.place_requested.emit(
		int(selected_option.controller),
		int(selected_option.location),
		int(selected_option.sequence),
		decision_generation
	)
	await process_frame
	if main.bridge.get_pending_action() != pending_after_restart:
		_fail("重开后的旧区域代次不得触碰新 DuelSession")
		return

	main.queue_free()
	_input_viewport.queue_free()
	await process_frame
	print("真实 OCGCore 区域选择流程通过")
	quit(0)


func _find_action(actions: Array, action_kind: String) -> Dictionary:
	for action in actions:
		if str(action.get("action_kind", "")) == action_kind:
			return action
	return {}


func _find_hand_card(hand: HandView, action: Dictionary) -> CardView:
	for child in hand.get_children():
		if (
			child is CardView
			and int(child.card_data.get("card_id", 0))
				== int(action.get("card_id", -1))
			and int(child.card_data.get("location", -1))
				== int(action.get("location", -2))
			and int(child.card_data.get("sequence", -1))
				== int(action.get("sequence", -2))
		):
			return child
	return null


func _find_button(container: Container, expected_text: String) -> Button:
	for child in container.get_children():
		if child is Button and child.text == expected_text:
			return child
	return null


func _zone_for_option(board: DuelBoard, option: Dictionary) -> ZoneView:
	var controller := int(option.get("controller", -1))
	var location := int(option.get("location", -1))
	var sequence := int(option.get("sequence", -1))
	var zones: Array = []
	if controller == 0 and location == 4:
		zones = board.player_monster_zones
	elif controller == 0 and location == 8:
		zones = board.player_spell_zones
	elif controller == 1 and location == 4:
		zones = board.opponent_monster_zones
	elif controller == 1 and location == 8:
		zones = board.opponent_spell_zones
	if sequence < 0 or sequence >= zones.size():
		return null
	return zones[sequence]


func _find_card_at_sequence(cards: Array, sequence: int) -> Dictionary:
	for card in cards:
		if int(card.get("sequence", -1)) == sequence:
			return card
	return {}


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
	var position := control.get_global_rect().get_center()
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
