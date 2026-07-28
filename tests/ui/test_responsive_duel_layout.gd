extends SceneTree

const BOARD_SCENE = preload("res://src/duel/duel_board.tscn")
const LOGICAL_SIZE := Vector2i(1920, 1080)
const PHYSICAL_WINDOW_SIZES := [
	Vector2i(1920, 1080),
	Vector2i(3840, 2160),
	Vector2i(1920, 1200),
]
const LONG_STATUS := (
	"决斗响应失败：OCGCore 返回的候选动作已失效，"
	+ "请等待下一份决斗快照后重试；当前状态不会由界面预先修改。"
)
const STATUS_HAND_SAFE_GAP := 24.0
const LAYOUT_STABILITY_LIMIT := 12
const EXPECTED_ZONE_COUNT := 5
const EXPECTED_TOTAL_ZONE_COUNT := 20
const EXPECTED_SYSTEM_BUTTON_COUNT := 3
const SCENARIO_DIRECT_ATTACK := "直击 LP 与怪兽预览"
const SCENARIO_FIVE_TARGETS := "五个合法怪兽目标"
const SCENARIO_GENERIC_YES_NO := "通用 YesNo 确认"
const SCENARIO_CANCELABLE_TARGETS := "可取消目标选择"
const SCENARIO_SELECT_POSITION := "四种表示形式"
const SCENARIO_SELECT_CHAIN := "手牌连锁多效果"

var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# 正常响应式案例必须沿用项目真实 Stretch：固定 1920×1080 逻辑画布，
	# 每轮只修改物理窗口。若测试自行改写 content_scale_size，就无法覆盖真实 4K 缩放。
	if root.content_scale_mode != Window.CONTENT_SCALE_MODE_CANVAS_ITEMS:
		_fail("项目必须使用 canvas_items Stretch")
		return
	if root.content_scale_size != LOGICAL_SIZE:
		_fail(
			"项目逻辑视口必须固定为 1920×1080，实际为 " + str(root.content_scale_size)
		)
		return
	for physical_size in PHYSICAL_WINDOW_SIZES:
		await _configure_physical_window(physical_size)
		if _failed:
			return
		var board: DuelBoard = BOARD_SCENE.instantiate()
		root.add_child(board)
		_assert_stretch_contract(physical_size)
		if _failed:
			return
		# 同一场景依次消费六份规则快照，既覆盖每种满载布局，也验证新快照能清除
		# 上一状态的高亮和浮层。物理窗口只在外层切换，保持真实 Stretch 路径。
		for scenario in _responsive_scenarios():
			board.render_snapshot(scenario.snapshot)
			if str(scenario.name) == SCENARIO_SELECT_CHAIN:
				# 连锁效果按钮只有点击真实候选 CardView 后才出现；在布局稳定前
				# 走生产 pressed 信号，避免只验证初始“不连锁”按钮而漏掉最宽状态。
				# 选中反馈是 0.1 秒 AnimationPlayer 动画；必须等待真实动画完成，
				# 不能把 headless 帧数误当成经过时间后检查尚在缩放的中间矩形。
				var candidate_card := board.player_hand.get_child(0) as CardView
				candidate_card.pressed.emit()
				if candidate_card.animator.is_playing():
					await candidate_card.animator.animation_finished
			await _wait_for_stable_layout(board, str(scenario.name))
			if _failed:
				return
			_assert_populated_layout(board, physical_size, str(scenario.name))
			if _failed:
				return
		board.queue_free()
		await process_frame
		await process_frame
	print("真实 Stretch 多分辨率决斗布局契约通过")
	quit(0)


func _configure_physical_window(physical_size: Vector2i) -> void:
	root.size = physical_size
	await process_frame
	await process_frame
	if root.size != physical_size:
		_fail(
			"物理窗口尺寸错误：请求 %s，实际 %s"
			% [physical_size, root.size]
		)
		return
	if (
		root.content_scale_mode != Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		or root.content_scale_size != LOGICAL_SIZE
	):
		_fail(
			"调整物理窗口时不得改写项目 Stretch：窗口 %s，逻辑画布 %s"
			% [physical_size, root.content_scale_size]
		)


func _responsive_scenarios() -> Array[Dictionary]:
	var direct_attack := _maximum_snapshot()
	direct_attack["decision_kind"] = "yes_no"
	direct_attack["decision_description"] = 31
	direct_attack["attack_target_context_supported"] = true

	var five_targets := _maximum_snapshot()
	five_targets["decision_kind"] = "select_card"
	five_targets["attack_target_context_supported"] = true
	five_targets["selection_min"] = 1
	five_targets["selection_max"] = 1
	five_targets["selection_cancelable"] = false
	five_targets["card_options"] = _five_opponent_monster_options()

	var generic_yes_no := _maximum_snapshot()
	generic_yes_no["decision_kind"] = "yes_no"
	generic_yes_no["decision_description"] = 99

	var cancelable_targets := _maximum_snapshot()
	cancelable_targets["decision_kind"] = "select_card"
	cancelable_targets["attack_target_context_supported"] = true
	cancelable_targets["selection_min"] = 1
	cancelable_targets["selection_max"] = 1
	cancelable_targets["selection_cancelable"] = true
	cancelable_targets["card_options"] = _five_opponent_monster_options()

	var select_position := _maximum_snapshot()
	select_position["decision_kind"] = "select_position"
	select_position["selection_card_id"] = 89631139
	select_position["position_options"] = [1, 2, 4, 8]

	var select_chain := _maximum_snapshot()
	select_chain["decision_kind"] = "select_chain"
	select_chain["chain_forced"] = false
	select_chain["chain_options"] = [
		{
			"index": 17,
			"card_id": 50000,
			"controller": 0,
			"location": 2,
			"sequence": 0,
			"position": 1,
			"description": 145581271,
			"client_mode": 0,
		},
		{
			"index": 42,
			"card_id": 50000,
			"controller": 0,
			"location": 2,
			"sequence": 0,
			"position": 1,
			"description": 145581272,
			"client_mode": 1,
		},
	]

	return [
		{"name": SCENARIO_DIRECT_ATTACK, "snapshot": direct_attack},
		{"name": SCENARIO_FIVE_TARGETS, "snapshot": five_targets},
		{"name": SCENARIO_GENERIC_YES_NO, "snapshot": generic_yes_no},
		{"name": SCENARIO_CANCELABLE_TARGETS, "snapshot": cancelable_targets},
		{"name": SCENARIO_SELECT_POSITION, "snapshot": select_position},
		{"name": SCENARIO_SELECT_CHAIN, "snapshot": select_chain},
	]


func _maximum_snapshot() -> Dictionary:
	var player_hand_cards: Array = []
	for sequence in range(6):
		player_hand_cards.append({
			"card_id": 50000 + sequence,
			"sequence": sequence,
			"location": 2,
			"controller": 0,
			"cn_name": "响应式测试手牌 %s" % [sequence + 1],
		})
	var player_monsters: Array = []
	var player_spells: Array = []
	var opponent_monsters: Array = []
	var opponent_spells: Array = []
	for sequence in range(5):
		player_monsters.append({
			"card_id": 51001 + sequence,
			"sequence": sequence,
			"location": 4,
			"controller": 0,
			"cn_name": "玩家怪兽 %s" % [sequence + 1],
		})
		player_spells.append({
			"card_id": 52001 + sequence,
			"sequence": sequence,
			"location": 8,
			"controller": 0,
			"cn_name": "玩家魔陷 %s" % [sequence + 1],
		})
		opponent_monsters.append({
			"card_id": 53001 + sequence,
			"sequence": sequence,
			"location": 4,
			"controller": 1,
			"cn_name": "对手怪兽 %s" % [sequence + 1],
		})
		opponent_spells.append({
			"card_id": 54001 + sequence,
			"sequence": sequence,
			"location": 8,
			"controller": 1,
			"cn_name": "对手魔陷 %s" % [sequence + 1],
		})
	return {
		"player_hand": player_hand_cards,
		"opponent_hand_count": 6,
		"player_monsters": player_monsters,
		"player_spells": player_spells,
		"opponent_monsters": opponent_monsters,
		"opponent_spells": opponent_spells,
		"idle_actions": [],
		"local_player_turn": true,
		"phase_kind": "battle",
		"can_enter_main2": true,
		"can_end_battle": true,
		"turn_text": "玩家1 · 战斗阶段",
		"status_text": LONG_STATUS,
		"player_stats": "玩家1  LP 8000  手牌 6  卡组 34",
		"opponent_stats": "玩家2  LP 8000  手牌 6  卡组 34",
	}


func _five_opponent_monster_options() -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	for sequence in range(5):
		options.append({
			"index": 40 + sequence,
			"controller": 1,
			"location": 4,
			"sequence": sequence,
			"position": 1,
		})
	return options


func _wait_for_stable_layout(board: Control, scenario_name: String) -> void:
	# Container、Theme 和动态按钮都会延迟重排。连续两个采样间隔均完全一致后
	# 才断言，避免把尚在变化的中间矩形误判为稳定布局。
	var previous_rects: Array[Rect2] = []
	var stable_intervals := 0
	for _frame_index in range(LAYOUT_STABILITY_LIMIT):
		await process_frame
		var current_rects := _collect_visible_control_rects(board)
		if current_rects == previous_rects:
			stable_intervals += 1
			if stable_intervals >= 2:
				return
		else:
			stable_intervals = 0
		previous_rects = current_rects
	_fail(
		"决斗布局在限定帧数内未连续稳定：窗口 %s，状态 %s"
		% [root.size, scenario_name]
	)


func _collect_visible_control_rects(board: Control) -> Array[Rect2]:
	var rects: Array[Rect2] = [board.get_global_rect()]
	for node in board.find_children("*", "Control", true, false):
		var control := node as Control
		if control != null and control.is_visible_in_tree():
			rects.append(control.get_global_rect())
	return rects


func _assert_stretch_contract(physical_size: Vector2i) -> void:
	var expected_transform := _expected_stretch_transform(physical_size)
	var actual_transform := root.get_stretch_transform()
	if !actual_transform.is_equal_approx(expected_transform):
		_fail(
			"Stretch 变换错误：窗口 %s，期望 %s，实际 %s"
			% [physical_size, expected_transform, actual_transform]
		)
		return
	var visible_rect := root.get_visible_rect()
	if (
		!visible_rect.position.is_equal_approx(Vector2.ZERO)
		or !visible_rect.size.is_equal_approx(Vector2(LOGICAL_SIZE))
	):
		_fail(
			"逻辑画布错误：窗口 %s，期望 %s，实际 %s"
			% [physical_size, Rect2(Vector2.ZERO, Vector2(LOGICAL_SIZE)), visible_rect]
		)
		return
	var expected_final_transform := _expected_final_transform(physical_size)
	var actual_final_transform := root.get_final_transform()
	if !actual_final_transform.is_equal_approx(expected_final_transform):
		_fail(
			"最终画布变换错误：窗口 %s，期望 %s，实际 %s"
			% [physical_size, expected_final_transform, actual_final_transform]
		)
		return
	var physical_content_rect := Rect2(
		expected_final_transform.origin,
		expected_final_transform.get_scale() * Vector2(LOGICAL_SIZE)
	)
	if !Rect2(Vector2.ZERO, Vector2(physical_size)).encloses(physical_content_rect):
		_fail("Stretch 后的逻辑画布离开物理窗口：" + str(physical_size))


func _expected_stretch_transform(physical_size: Vector2i) -> Transform2D:
	var axis_scale := Vector2(physical_size) / Vector2(LOGICAL_SIZE)
	if root.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_IGNORE:
		return Transform2D(Vector2(axis_scale.x, 0.0), Vector2(0.0, axis_scale.y), Vector2.ZERO)
	if root.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP:
		var uniform_scale := minf(axis_scale.x, axis_scale.y)
		return Transform2D(
			Vector2(uniform_scale, 0.0),
			Vector2(0.0, uniform_scale),
			Vector2.ZERO
		)
	_fail("测试暂不支持项目当前的 Stretch Aspect：" + str(root.content_scale_aspect))
	return Transform2D.IDENTITY


func _expected_final_transform(physical_size: Vector2i) -> Transform2D:
	var stretch_transform := _expected_stretch_transform(physical_size)
	if root.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP:
		var rendered_size := Vector2(LOGICAL_SIZE) * stretch_transform.get_scale()
		stretch_transform.origin = (Vector2(physical_size) - rendered_size) / 2.0
	return stretch_transform


func _assert_populated_layout(
	board: DuelBoard,
	physical_size: Vector2i,
	scenario_name: String
) -> void:
	var logical_rect := Rect2(Vector2.ZERO, Vector2(LOGICAL_SIZE))
	var safe_area_node := board.find_child("SafeArea", true, false)
	if !(safe_area_node is Control):
		_fail("决斗场景缺少 SafeArea：窗口 %s，状态 %s" % [
			physical_size,
			scenario_name,
		])
		return
	var safe_area := safe_area_node as Control
	if !_assert_control_geometry(
		safe_area,
		logical_rect,
		logical_rect,
		physical_size,
		scenario_name,
		"SafeArea"
	):
		return
	var safe_rect := safe_area.get_global_rect()
	var key_control_names := [
		"Battlefield",
		"PlayerHand",
		"OpponentHand",
		"StatusToast",
		"SystemTools",
		"PhaseButton",
		"OpponentStatusSurface",
	]
	for node_name in key_control_names:
		if !_assert_control_geometry(
			board.find_child(node_name, true, false),
			logical_rect,
			safe_rect,
			physical_size,
			scenario_name,
			node_name
		):
			return
	var action_bar := board.action_box
	var player_hand := board.player_hand
	var status := board.status_label
	var opponent_hand := board.opponent_hand
	var tools_node := board.find_child("SystemTools", true, false)
	if !(tools_node is HBoxContainer):
		_fail("决斗场景缺少系统工具容器：窗口 %s，状态 %s" % [
			physical_size,
			scenario_name,
		])
		return
	var tools := tools_node as HBoxContainer
	if tools.get_child_count() != EXPECTED_SYSTEM_BUTTON_COUNT:
		_fail("系统工具必须恰好包含三个 BaseButton：窗口 %s，状态 %s，实际 %s 个" % [
			physical_size,
			scenario_name,
			tools.get_child_count(),
		])
		return
	var phase := board.phase_button
	for themed_control in [
		{"control": phase, "variation": &"PhaseButton", "name": "阶段球"},
		{"control": action_bar, "variation": &"ContextActionBarLayout", "name": "动作条"},
		{"control": tools, "variation": &"SystemToolsLayout", "name": "系统工具"},
	]:
		var control := themed_control.control as Control
		if control.theme_type_variation != themed_control.variation:
			_fail(
				"%s 未继承约定 Theme：窗口 %s，状态 %s"
				% [themed_control.name, physical_size, scenario_name]
			)
			return
	for child_index in range(EXPECTED_SYSTEM_BUTTON_COUNT):
		var tool_button := tools.get_child(child_index)
		if !(tool_button is BaseButton):
			_fail("系统工具第 %s 项不是 BaseButton：窗口 %s，状态 %s" % [
				child_index + 1,
				physical_size,
				scenario_name,
			])
			return
		if !_assert_control_geometry(
			tool_button,
			logical_rect,
			safe_rect,
			physical_size,
			scenario_name,
			"系统按钮 %s" % [child_index + 1]
		):
			return
	if status.get_global_rect().intersects(opponent_hand.get_global_rect()):
		_fail("状态文字覆盖对手手牌：窗口 %s，状态 %s" % [physical_size, scenario_name])
		return
	var status_hand_gap := opponent_hand.get_global_rect().position.x - status.get_global_rect().end.x
	if status_hand_gap < STATUS_HAND_SAFE_GAP:
		_fail(
			"状态与对手手牌安全间距不足：窗口 %s，状态 %s，仅 %.2f 像素"
			% [physical_size, scenario_name, status_hand_gap]
		)
		return
	var player_hand_result := _assert_hand_cards(
		player_hand,
		6,
		logical_rect,
		safe_rect,
		physical_size,
		scenario_name,
		"玩家手牌"
	)
	if !bool(player_hand_result.ok):
		return
	var opponent_hand_result := _assert_hand_cards(
		opponent_hand,
		6,
		logical_rect,
		safe_rect,
		physical_size,
		scenario_name,
		"对手手牌"
	)
	if !bool(opponent_hand_result.ok):
		return
	if !_assert_fixed_zone_cardinality(board, physical_size, scenario_name):
		return
	var all_zones := (
		board.player_monster_zones
		+ board.player_spell_zones
		+ board.opponent_monster_zones
		+ board.opponent_spell_zones
	)
	for zone_index in range(all_zones.size()):
		if !_assert_full_zone(
			all_zones[zone_index],
			logical_rect,
			safe_rect,
			physical_size,
			scenario_name,
			"满载卡位 %s" % [zone_index + 1]
		):
			return
	_assert_scenario_layout(board, logical_rect, safe_rect, physical_size, scenario_name)
	if _failed:
		return
	_assert_non_overlapping_layout(
		board,
		player_hand_result.rect,
		opponent_hand_result.rect,
		physical_size,
		scenario_name
	)


func _assert_fixed_zone_cardinality(
	board: DuelBoard,
	physical_size: Vector2i,
	scenario_name: String
) -> bool:
	# 四组卡位是稳定场景契约。先锁定每组与总数，再按固定下标检查内容，
	# 避免场景误删节点后循环随数组缩短而产生假绿。
	var zone_groups := [
		{"name": "玩家怪兽区", "zones": board.player_monster_zones},
		{"name": "玩家魔陷区", "zones": board.player_spell_zones},
		{"name": "对手怪兽区", "zones": board.opponent_monster_zones},
		{"name": "对手魔陷区", "zones": board.opponent_spell_zones},
	]
	var total_zone_count := 0
	for group in zone_groups:
		var zones: Array = group.zones
		if zones.size() != EXPECTED_ZONE_COUNT:
			_fail("%s 必须恰好包含五个卡位：窗口 %s，状态 %s，实际 %s 个" % [
				group.name,
				physical_size,
				scenario_name,
				zones.size(),
			])
			return false
		total_zone_count += zones.size()
	if total_zone_count != EXPECTED_TOTAL_ZONE_COUNT:
		_fail("四组固定卡位合计必须恰好二十个：窗口 %s，状态 %s，实际 %s 个" % [
			physical_size,
			scenario_name,
			total_zone_count,
		])
		return false
	if board.opponent_monster_zones.size() != EXPECTED_ZONE_COUNT:
		_fail("对手怪兽目标卡位必须恰好包含五个：窗口 %s，状态 %s，实际 %s 个" % [
			physical_size,
			scenario_name,
			board.opponent_monster_zones.size(),
		])
		return false
	return true


func _assert_control_geometry(
	control_value: Variant,
	logical_rect: Rect2,
	safe_rect: Rect2,
	physical_size: Vector2i,
	scenario_name: String,
	control_name: String
) -> bool:
	# 必须先验证运行时类型，再读取可见性和矩形；缺节点、错误类型、隐藏父节点
	# 或零尺寸都应成为受控测试失败，不能以空引用中断整个契约。
	if !(control_value is Control):
		_fail("%s 不是有效 Control：窗口 %s，状态 %s" % [
			control_name,
			physical_size,
			scenario_name,
		])
		return false
	var control := control_value as Control
	var rect := control.get_global_rect()
	if (
		!control.is_visible_in_tree()
		or rect.size.x <= 0.0
		or rect.size.y <= 0.0
		or !logical_rect.encloses(rect)
		or !safe_rect.encloses(rect)
	):
		_fail("%s 未完整显示在安全区域：窗口 %s，状态 %s，矩形 %s" % [
			control_name,
			physical_size,
			scenario_name,
			rect,
		])
		return false
	return true


func _assert_hand_cards(
	hand_value: Variant,
	expected_count: int,
	logical_rect: Rect2,
	safe_rect: Rect2,
	physical_size: Vector2i,
	scenario_name: String,
	hand_name: String
) -> Dictionary:
	if !(hand_value is HandView):
		_fail("%s 缺少真实 HandView：窗口 %s，状态 %s" % [
			hand_name,
			physical_size,
			scenario_name,
		])
		return {"ok": false, "rect": Rect2()}
	var hand := hand_value as HandView
	if hand.get_child_count() != expected_count:
		_fail("%s 必须显示 %s 张卡：窗口 %s，状态 %s" % [
			hand_name,
			expected_count,
			physical_size,
			scenario_name,
		])
		return {"ok": false, "rect": Rect2()}
	var content_rect := Rect2()
	for card_index in range(expected_count):
		var card := hand.get_child(card_index)
		if !(card is CardView):
			_fail("%s 第 %s 项不是 CardView：窗口 %s，状态 %s" % [
				hand_name,
				card_index + 1,
				physical_size,
				scenario_name,
			])
			return {"ok": false, "rect": Rect2()}
		if !_assert_control_geometry(
			card,
			logical_rect,
			safe_rect,
			physical_size,
			scenario_name,
			"%s CardView %s" % [hand_name, card_index + 1]
		):
			return {"ok": false, "rect": Rect2()}
		var card_rect := (card as Control).get_global_rect()
		content_rect = card_rect if card_index == 0 else content_rect.merge(card_rect)
	return {"ok": true, "rect": content_rect}


func _assert_full_zone(
	zone_value: Variant,
	logical_rect: Rect2,
	safe_rect: Rect2,
	physical_size: Vector2i,
	scenario_name: String,
	zone_name: String
) -> bool:
	if !(zone_value is ZoneView):
		_fail("%s 不是有效 ZoneView：窗口 %s，状态 %s" % [
			zone_name,
			physical_size,
			scenario_name,
		])
		return false
	var zone := zone_value as ZoneView
	if !_assert_control_geometry(
		zone,
		logical_rect,
		safe_rect,
		physical_size,
		scenario_name,
		zone_name
	):
		return false
	if !_assert_control_geometry(
		zone.card_container,
		logical_rect,
		safe_rect,
		physical_size,
		scenario_name,
		zone_name + " CardContainer"
	):
		return false
	if zone.card_container.get_child_count() != 1:
		_fail("%s 必须恰好显示一张卡：窗口 %s，状态 %s" % [
			zone_name,
			physical_size,
			scenario_name,
		])
		return false
	var card := zone.card_container.get_child(0)
	if !(card is CardView):
		_fail("%s 的内容不是 CardView：窗口 %s，状态 %s" % [
			zone_name,
			physical_size,
			scenario_name,
		])
		return false
	return _assert_control_geometry(
		card,
		logical_rect,
		safe_rect,
		physical_size,
		scenario_name,
		zone_name + " CardView"
	)


func _assert_scenario_layout(
	board: DuelBoard,
	logical_rect: Rect2,
	safe_rect: Rect2,
	physical_size: Vector2i,
	scenario_name: String
) -> void:
	if scenario_name == SCENARIO_DIRECT_ATTACK:
		if !_assert_control_geometry(
			board.direct_attack_highlight,
			logical_rect,
			safe_rect,
			physical_size,
			scenario_name,
			"直击 LP 高亮"
		):
			return
		if (
			board.direct_attack_highlight.theme_type_variation != &"DirectAttackTarget"
			or board.direct_attack_highlight.get_global_rect()
				!= board.opponent_status_surface.get_global_rect()
		):
			_fail("直击 LP 高亮未完整覆盖点击面：窗口 " + str(physical_size))
			return
		var preview_highlight_count := 0
		for zone_index in range(EXPECTED_ZONE_COUNT):
			var zone: ZoneView = board.opponent_monster_zones[zone_index]
			if (
				!_assert_control_geometry(
					zone.target_highlight,
					logical_rect,
					safe_rect,
					physical_size,
					scenario_name,
					"攻击预览高亮 %s" % [zone_index + 1]
				)
			):
				return
			if zone.target_highlight.theme_type_variation != &"AttackTargetPreview":
				_fail("五个对手怪兽必须全部显示攻击预览：窗口 " + str(physical_size))
				return
			preview_highlight_count += 1
		if preview_highlight_count != EXPECTED_ZONE_COUNT:
			_fail("直击状态必须恰好显示五个攻击预览高亮：窗口 %s，实际 %s 个" % [
				physical_size,
				preview_highlight_count,
			])
			return
		if (
			board.action_box.is_visible_in_tree()
			or board.confirmation_overlay.is_visible_in_tree()
		):
			_fail("直击选择不得残留动作条或确认层：窗口 " + str(physical_size))
			return
	elif scenario_name == SCENARIO_FIVE_TARGETS:
		if !_assert_five_target_highlights(
			board,
			logical_rect,
			safe_rect,
			physical_size,
			scenario_name
		):
			return
		if (
			board.action_box.is_visible_in_tree()
			or board.confirmation_overlay.is_visible_in_tree()
		):
			_fail("不可取消目标选择不得显示动作条或确认层：窗口 " + str(physical_size))
			return
	elif scenario_name == SCENARIO_GENERIC_YES_NO:
		var button_texts: Array[String] = []
		for child in board.confirmation_buttons.get_children():
			if child is Button:
				button_texts.append(str(child.text))
		if (
			!board.confirmation_overlay.is_visible_in_tree()
			or board.confirmation_overlay.theme_type_variation != &"OverlayPanel"
			or button_texts != ["是", "否"]
		):
			_fail("通用 YesNo 必须显示原生“是/否”确认层：窗口 " + str(physical_size))
			return
		if (
			board.direct_attack_highlight.is_visible_in_tree()
			or board.action_box.is_visible_in_tree()
			or _visible_target_highlight_count(board) != 0
		):
			_fail("通用 YesNo 不得残留攻击目标表现：窗口 " + str(physical_size))
			return
		_assert_optional_overlay_layout(
			board.confirmation_overlay,
			logical_rect,
			safe_rect,
			physical_size,
			scenario_name,
			"确认层"
		)
	elif scenario_name == SCENARIO_CANCELABLE_TARGETS:
		if !_assert_five_target_highlights(
			board,
			logical_rect,
			safe_rect,
			physical_size,
			scenario_name
		):
			return
		if (
			!board.action_box.is_visible_in_tree()
			or board.action_box.get_child_count() != 1
			or !(board.action_box.get_child(0) is Button)
			or board.action_box.get_child(0).text != "取消攻击"
			or board.confirmation_overlay.is_visible_in_tree()
		):
			_fail("可取消目标选择必须只显示“取消攻击”动作：窗口 " + str(physical_size))
			return
		_assert_optional_overlay_layout(
			board.action_box,
			logical_rect,
			safe_rect,
			physical_size,
			scenario_name,
			"动作条"
		)
	elif scenario_name == SCENARIO_SELECT_POSITION:
		var position_texts: Array[String] = []
		for child in board.confirmation_buttons.get_children():
			if child is Button:
				position_texts.append(str(child.text))
		if (
			!board.confirmation_overlay.is_visible_in_tree()
			or position_texts != [
				"表侧攻击", "里侧攻击", "表侧守备", "里侧守备",
			]
			or board.action_box.is_visible_in_tree()
			or board.direct_attack_highlight.is_visible_in_tree()
			or _visible_target_highlight_count(board) != 0
		):
			_fail("表示形式必须显示四个原生按钮且无攻击残留：窗口 " + str(physical_size))
			return
		_assert_optional_overlay_layout(
			board.confirmation_overlay,
			logical_rect,
			safe_rect,
			physical_size,
			scenario_name,
			"表示形式确认层"
		)
	elif scenario_name == SCENARIO_SELECT_CHAIN:
		var chain_button_texts: Array[String] = []
		for child in board.action_box.get_children():
			if child is Button:
				chain_button_texts.append(str(child.text))
		var candidate_card := board.player_hand.get_child(0) as CardView
		var non_candidate_card := board.player_hand.get_child(1) as CardView
		if (
			!board.action_box.is_visible_in_tree()
			or chain_button_texts != [
				"发动效果 1（描述 145581271）",
				"发动效果 2（描述 145581272）",
				"不连锁",
			]
			or board.confirmation_overlay.is_visible_in_tree()
			or !candidate_card.self_modulate.is_equal_approx(
				candidate_card.get_theme_color(
					&"candidate_modulate",
					&"ChainCandidateHand"
				)
			)
			or !non_candidate_card.self_modulate.is_equal_approx(
				non_candidate_card.get_theme_color(
					&"non_candidate_modulate",
					&"ChainCandidateHand"
				)
			)
		):
			_fail("连锁候选必须显示两项真实效果按钮、不连锁入口和独立手牌高亮：窗口 "
				+ str(physical_size))
			return
		_assert_optional_overlay_layout(
			board.action_box,
			logical_rect,
			safe_rect,
			physical_size,
			scenario_name,
			"连锁动作条"
		)


func _assert_five_target_highlights(
	board: DuelBoard,
	logical_rect: Rect2,
	safe_rect: Rect2,
	physical_size: Vector2i,
	scenario_name: String
) -> bool:
	if board.direct_attack_highlight.is_visible_in_tree():
		_fail("SelectCard 不得保留 LP 高亮：窗口 %s，状态 %s" % [
			physical_size,
			scenario_name,
		])
		return false
	var target_highlight_count := 0
	for zone_index in range(EXPECTED_ZONE_COUNT):
		var zone: ZoneView = board.opponent_monster_zones[zone_index]
		if !_assert_control_geometry(
			zone.target_highlight,
			logical_rect,
			safe_rect,
			physical_size,
			scenario_name,
			"合法目标高亮 %s" % [zone_index + 1]
		):
			return false
		if zone.target_highlight.theme_type_variation != &"TargetHighlight":
			_fail("五个合法目标必须全部使用 TargetHighlight：窗口 %s，状态 %s" % [
				physical_size,
				scenario_name,
			])
			return false
		target_highlight_count += 1
	if target_highlight_count != EXPECTED_ZONE_COUNT:
		_fail("目标选择状态必须恰好显示五个合法目标高亮：窗口 %s，状态 %s，实际 %s 个" % [
			physical_size,
			scenario_name,
			target_highlight_count,
		])
		return false
	return true


func _visible_target_highlight_count(board: DuelBoard) -> int:
	var count := 0
	for zone_index in range(EXPECTED_ZONE_COUNT):
		var zone: ZoneView = board.opponent_monster_zones[zone_index]
		if zone.target_highlight.is_visible_in_tree():
			count += 1
	return count


func _assert_optional_overlay_layout(
	overlay: Control,
	logical_rect: Rect2,
	safe_rect: Rect2,
	physical_size: Vector2i,
	scenario_name: String,
	control_name: String
) -> void:
	if !_assert_control_geometry(
		overlay,
		logical_rect,
		safe_rect,
		physical_size,
		scenario_name,
		control_name
	):
		return
	for child in overlay.find_children("*", "Button", true, false):
		if !(child is Button):
			_fail("%s 包含非按钮动态控件：窗口 %s，状态 %s" % [
				control_name,
				physical_size,
				scenario_name,
			])
			return
		var button := child as Button
		if button.disabled or !_assert_control_geometry(
			button,
			logical_rect,
			safe_rect,
			physical_size,
			scenario_name,
			"%s 按钮“%s”" % [control_name, button.text]
		):
			_fail("%s 的动态按钮不可用：窗口 %s，状态 %s" % [
				control_name,
				physical_size,
				scenario_name,
			])
			return


func _assert_non_overlapping_layout(
	board: DuelBoard,
	player_hand_content_rect: Rect2,
	opponent_hand_content_rect: Rect2,
	physical_size: Vector2i,
	scenario_name: String
) -> void:
	# HandView 本身横跨战场布局通道，其中大量空白用于 Container 居中排牌；
	# 可点击安全关系必须锁定实际 CardView 内容包围盒，而不是把空白通道与右上角
	# LP 面板的结构性交叠误报为遮挡。除此之外不豁免任何可见关键控件组合。
	var items: Array[Dictionary] = [
		{"name": "LP 点击面", "rect": board.opponent_status_surface.get_global_rect()},
		{"name": "阶段球", "rect": board.phase_button.get_global_rect()},
		{"name": "玩家手牌内容", "rect": player_hand_content_rect},
		{"name": "对手手牌内容", "rect": opponent_hand_content_rect},
		{
			"name": "系统工具",
			"rect": (board.find_child("SystemTools", true, false) as Control).get_global_rect(),
		},
	]
	if board.action_box.is_visible_in_tree():
		items.append({"name": "动作条", "rect": board.action_box.get_global_rect()})
	if board.confirmation_overlay.is_visible_in_tree():
		items.append({
			"name": "确认层",
			"rect": board.confirmation_overlay.get_global_rect(),
		})
	# 逐一生成完整无序对：LP 与双方手牌、动作条/确认层与 LP、对手手牌与系统
	# 工具等关系都由同一矩阵覆盖，后续新增项目不会再依赖人工枚举而漏项。
	for left_index in range(items.size()):
		for right_index in range(left_index + 1, items.size()):
			var left := items[left_index]
			var right := items[right_index]
			if (left.rect as Rect2).intersects(right.rect as Rect2):
				_fail("%s 与 %s 发生重叠：窗口 %s，状态 %s，矩形 %s / %s" % [
					left.name,
					right.name,
					physical_size,
					scenario_name,
					left.rect,
					right.rect,
				])
				return


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	push_error(message)
	quit(1)
