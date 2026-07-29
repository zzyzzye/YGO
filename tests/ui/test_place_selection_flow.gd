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
	var pending_before_non_candidate: Dictionary = main.bridge.get_pending_action()
	var place_highlight_count := _place_highlight_count(board)

	# 通常召唤只允许怪兽区，因此玩家魔陷区是核心候选外的真实可视节点。点击
	# 必须完整经过 SubViewport GUI picking；不能直接构造 place_requested 信号
	# 来伪装用户输入。非候选点击后核心 pending、代次和合法高亮均保持不变。
	var non_candidate_zone: ZoneView = board.player_spell_zones[0]
	await _viewport_click(non_candidate_zone)
	if (
		main.bridge.get_pending_action() != pending_before_non_candidate
		or board._rule_decision_generation != decision_generation
		or !selected_zone.target_highlight.visible
		or non_candidate_zone.target_highlight.visible
		or _place_highlight_count(board) != place_highlight_count
	):
		_fail("真实非候选点击不得改变核心决策、代次或合法区域高亮")
		return

	# 系统完整双击由一次普通按下/释放和第二次 double_click=true 按下/释放组成。
	# 第一击提交后入口立即退休；第二击仍从同一物理坐标进入真实命中链，但不得
	# 再提交或推进第二次代次。
	var selected_position := selected_zone.get_global_rect().get_center()
	await _viewport_click_position(selected_position)
	await _viewport_click_position(selected_position, true)
	await process_frame
	if board._rule_decision_generation != decision_generation + 1:
		_fail("完整双击只能提交一次并推进一次决策代次")
		return
	var state_after_place: Dictionary = main.bridge.get_duel_state()
	# 先验证 Bridge 返回结构再读取嵌套字段，避免失败响应因点访问产生脚本错误，
	# 从而把协议缺陷误报成测试运行器异常。
	if !bool(state_after_place.get("ok", false)):
		_fail("区域提交后读取真实决斗状态失败")
		return
	var players_value: Variant = state_after_place.get("players", {})
	if !(players_value is Dictionary):
		_fail("真实决斗状态缺少 players 字典")
		return
	var players := players_value as Dictionary
	var player_value: Variant = players.get("p1", {})
	if !(player_value is Dictionary):
		_fail("真实决斗状态缺少玩家1字典")
		return
	var player_state := player_value as Dictionary
	var placed_cards_value: Variant = player_state.get("monster_cards", [])
	if !(placed_cards_value is Array):
		_fail("玩家1状态缺少 monster_cards 数组")
		return
	var placed_cards := placed_cards_value as Array
	var placed_card := _find_card_at_sequence(
		placed_cards,
		int(selected_option.sequence)
	)
	if (
		placed_cards.size() != 1
		or placed_card.is_empty()
		or int(placed_card.get("card_id", 0)) != summoned_card_id
		# DuelCardSnapshot 的公开 Godot 字典不重复暴露 controller；本地玩家
		# 归属由 players.p1 容器表达，location/sequence 则必须与候选精确一致。
		or int(selected_option.get("controller", -1)) != 0
		or int(placed_card.get("location", 0))
			!= int(selected_option.get("location", -1))
		or int(placed_card.get("sequence", -1))
			!= int(selected_option.get("sequence", -2))
		or board.player_hand.get_child_count() != opening_hand_count - 1
		or _has_place_highlight(board)
		or str(main.bridge.get_pending_action().get("kind", "none")) != "idle"
		or board.status_label.text != "放置区域已提交，场面已由 OCGCore 更新"
	):
		_fail("完整双击后真实核心只能留下所选区域的一张卡和一次成功状态")
		return

	# 重开也必须走真实系统按钮、确认按钮与 Main 生命周期；新 DuelSession
	# 建立后旧高亮必须全部清除。旧代次门禁由 Task 4 的 Main 边界测试验证，
	# 此处不直接构造生产场景不可能由真实输入产生的过期信号。
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
	return _place_highlight_count(board) > 0


func _place_highlight_count(board: DuelBoard) -> int:
	var count := 0
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
			count += 1
	return count


func _viewport_click(control: Control, double_click := false) -> void:
	await _viewport_click_position(
		control.get_global_rect().get_center(),
		double_click
	)


func _viewport_click_position(position: Vector2, double_click := false) -> void:
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
