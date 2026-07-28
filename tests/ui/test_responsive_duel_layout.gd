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
const SCENARIO_DIRECT_ATTACK := "直击 LP 与怪兽预览"
const SCENARIO_FIVE_TARGETS := "五个合法怪兽目标"
const SCENARIO_GENERIC_YES_NO := "通用 YesNo 确认"
const SCENARIO_CANCELABLE_TARGETS := "可取消目标选择"

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
		# 同一场景依次消费四份规则快照，既覆盖每种满载布局，也验证新快照能清除
		# 上一状态的高亮和浮层。物理窗口只在外层切换，保持真实 Stretch 路径。
		for scenario in _responsive_scenarios():
			board.render_snapshot(scenario.snapshot)
			await _wait_for_stable_layout(board)
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

	var five_targets := _maximum_snapshot()
	five_targets["decision_kind"] = "select_card"
	five_targets["selection_min"] = 1
	five_targets["selection_max"] = 1
	five_targets["selection_cancelable"] = false
	five_targets["card_options"] = _five_opponent_monster_options()

	var generic_yes_no := _maximum_snapshot()
	generic_yes_no["decision_kind"] = "yes_no"
	generic_yes_no["decision_description"] = 99

	var cancelable_targets := _maximum_snapshot()
	cancelable_targets["decision_kind"] = "select_card"
	cancelable_targets["selection_min"] = 1
	cancelable_targets["selection_max"] = 1
	cancelable_targets["selection_cancelable"] = true
	cancelable_targets["card_options"] = _five_opponent_monster_options()

	return [
		{"name": SCENARIO_DIRECT_ATTACK, "snapshot": direct_attack},
		{"name": SCENARIO_FIVE_TARGETS, "snapshot": five_targets},
		{"name": SCENARIO_GENERIC_YES_NO, "snapshot": generic_yes_no},
		{"name": SCENARIO_CANCELABLE_TARGETS, "snapshot": cancelable_targets},
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


func _wait_for_stable_layout(board: Control) -> void:
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
	_fail("决斗布局在限定帧数内未连续稳定：" + str(root.size))


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
	var safe_area: Control = board.find_child("SafeArea", true, false)
	var safe_rect := safe_area.get_global_rect()
	var key_control_names := [
		"SafeArea",
		"Battlefield",
		"PlayerHand",
		"OpponentHand",
		"StatusToast",
		"SystemTools",
		"PhaseButton",
		"OpponentStatusSurface",
	]
	for node_name in key_control_names:
		var control: Control = board.find_child(node_name, true, false)
		if (
			control == null
			or !control.is_visible_in_tree()
			or control.size.x <= 0.0
			or control.size.y <= 0.0
			or !logical_rect.encloses(control.get_global_rect())
		):
			_fail(
				"关键控件未完整留在逻辑画布：%s，窗口 %s，状态 %s，矩形 %s"
				% [
					node_name,
					physical_size,
					scenario_name,
					control.get_global_rect() if control != null else Rect2(),
				]
			)
			return
		if node_name != "SafeArea" and !safe_rect.encloses(control.get_global_rect()):
			_fail(
				"关键控件离开安全区域：%s，窗口 %s，状态 %s，矩形 %s"
				% [node_name, physical_size, scenario_name, control.get_global_rect()]
			)
			return
	var action_bar: HBoxContainer = board.action_box
	var player_hand: HandView = board.player_hand
	var status: Label = board.status_label
	var opponent_hand: HandView = board.opponent_hand
	var tools: HBoxContainer = board.find_child("SystemTools", true, false)
	var phase: Button = board.phase_button
	var lp_surface: Control = board.opponent_status_surface
	for themed_control in [
		{"control": phase, "variation": &"PhaseButton", "name": "阶段球"},
		{"control": action_bar, "variation": &"ContextActionBarLayout", "name": "动作条"},
		{"control": tools, "variation": &"SystemToolsLayout", "name": "系统工具"},
	]:
		var control: Control = themed_control.control
		if control.theme_type_variation != themed_control.variation:
			_fail(
				"%s 未继承约定 Theme：窗口 %s，状态 %s"
				% [themed_control.name, physical_size, scenario_name]
			)
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
	if (
		board.player_hand.get_child_count() != 6
		or board.opponent_hand.get_child_count() != 6
	):
		_fail("满载案例必须显示双方各六张手牌：窗口 %s，状态 %s" % [
			physical_size,
			scenario_name,
		])
		return
	for zone in (
		board.player_monster_zones
		+ board.player_spell_zones
		+ board.opponent_monster_zones
		+ board.opponent_spell_zones
	):
		if zone.card_container.get_child_count() != 1:
			_fail("满载怪兽/魔陷卡位必须全部填充：窗口 %s，状态 %s" % [
				physical_size,
				scenario_name,
			])
			return
	for pair in [
		{"a": lp_surface, "b": phase, "name": "LP 点击面与阶段球"},
		{"a": lp_surface, "b": tools, "name": "LP 点击面与系统工具"},
		{"a": phase, "b": player_hand, "name": "阶段球与玩家手牌"},
		{"a": phase, "b": opponent_hand, "name": "阶段球与对手手牌"},
		{"a": phase, "b": tools, "name": "阶段球与系统工具"},
		{"a": player_hand, "b": tools, "name": "玩家手牌与系统工具"},
	]:
		if pair.a.get_global_rect().intersects(pair.b.get_global_rect()):
			_fail(
				"%s 发生重叠：窗口 %s，状态 %s"
				% [pair.name, physical_size, scenario_name]
			)
			return
	_assert_scenario_layout(board, logical_rect, safe_rect, physical_size, scenario_name)


func _assert_scenario_layout(
	board: DuelBoard,
	logical_rect: Rect2,
	safe_rect: Rect2,
	physical_size: Vector2i,
	scenario_name: String
) -> void:
	if scenario_name == SCENARIO_DIRECT_ATTACK:
		if (
			!board.direct_attack_highlight.visible
			or board.direct_attack_highlight.theme_type_variation != &"DirectAttackTarget"
			or board.direct_attack_highlight.get_global_rect()
				!= board.opponent_status_surface.get_global_rect()
		):
			_fail("直击 LP 高亮未完整覆盖点击面：窗口 " + str(physical_size))
			return
		for zone in board.opponent_monster_zones:
			if (
				!zone.target_highlight.visible
				or zone.target_highlight.theme_type_variation != &"AttackTargetPreview"
			):
				_fail("五个对手怪兽必须全部显示攻击预览：窗口 " + str(physical_size))
				return
		if board.action_box.visible or board.confirmation_overlay.visible:
			_fail("直击选择不得残留动作条或确认层：窗口 " + str(physical_size))
			return
	elif scenario_name == SCENARIO_FIVE_TARGETS:
		_assert_five_target_highlights(board, physical_size, scenario_name)
		if board.action_box.visible or board.confirmation_overlay.visible:
			_fail("不可取消目标选择不得显示动作条或确认层：窗口 " + str(physical_size))
			return
	elif scenario_name == SCENARIO_GENERIC_YES_NO:
		var button_texts: Array[String] = []
		for child in board.confirmation_buttons.get_children():
			if child is Button:
				button_texts.append(str(child.text))
		if (
			!board.confirmation_overlay.visible
			or board.confirmation_overlay.theme_type_variation != &"OverlayPanel"
			or button_texts != ["是", "否"]
		):
			_fail("通用 YesNo 必须显示原生“是/否”确认层：窗口 " + str(physical_size))
			return
		if (
			board.direct_attack_highlight.visible
			or board.action_box.visible
			or _visible_target_highlight_count(board) != 0
		):
			_fail("通用 YesNo 不得残留攻击目标表现：窗口 " + str(physical_size))
			return
		_assert_optional_overlay_layout(
			board.confirmation_overlay,
			board,
			logical_rect,
			safe_rect,
			physical_size,
			scenario_name,
			"确认层"
		)
	elif scenario_name == SCENARIO_CANCELABLE_TARGETS:
		_assert_five_target_highlights(board, physical_size, scenario_name)
		if (
			!board.action_box.visible
			or board.action_box.get_child_count() != 1
			or !(board.action_box.get_child(0) is Button)
			or board.action_box.get_child(0).text != "取消攻击"
			or board.confirmation_overlay.visible
		):
			_fail("可取消目标选择必须只显示“取消攻击”动作：窗口 " + str(physical_size))
			return
		_assert_optional_overlay_layout(
			board.action_box,
			board,
			logical_rect,
			safe_rect,
			physical_size,
			scenario_name,
			"动作条"
		)


func _assert_five_target_highlights(
	board: DuelBoard,
	physical_size: Vector2i,
	scenario_name: String
) -> void:
	if board.direct_attack_highlight.visible:
		_fail("SelectCard 不得保留 LP 高亮：窗口 %s，状态 %s" % [
			physical_size,
			scenario_name,
		])
		return
	for zone in board.opponent_monster_zones:
		if (
			!zone.target_highlight.visible
			or zone.target_highlight.theme_type_variation != &"TargetHighlight"
		):
			_fail("五个合法目标必须全部使用 TargetHighlight：窗口 %s，状态 %s" % [
				physical_size,
				scenario_name,
			])
			return


func _visible_target_highlight_count(board: DuelBoard) -> int:
	var count := 0
	for zone in board.opponent_monster_zones:
		if zone.target_highlight.visible:
			count += 1
	return count


func _assert_optional_overlay_layout(
	overlay: Control,
	board: DuelBoard,
	logical_rect: Rect2,
	safe_rect: Rect2,
	physical_size: Vector2i,
	scenario_name: String,
	control_name: String
) -> void:
	var rect := overlay.get_global_rect()
	if (
		!overlay.is_visible_in_tree()
		or overlay.size.x <= 0.0
		or overlay.size.y <= 0.0
		or !logical_rect.encloses(rect)
		or !safe_rect.encloses(rect)
	):
		_fail("%s 离开安全区域：窗口 %s，状态 %s，矩形 %s" % [
			control_name,
			physical_size,
			scenario_name,
			rect,
		])
		return
	for other in [
		board.player_hand,
		board.opponent_hand,
		board.phase_button,
		board.find_child("SystemTools", true, false),
	]:
		if rect.intersects(other.get_global_rect()):
			_fail("%s 覆盖手牌、阶段球或系统按钮：窗口 %s，状态 %s" % [
				control_name,
				physical_size,
				scenario_name,
			])
			return
	for child in overlay.find_children("*", "Button", true, false):
		var button := child as Button
		if (
			!button.is_visible_in_tree()
			or button.disabled
			or button.size.x <= 0.0
			or button.size.y <= 0.0
			or !safe_rect.encloses(button.get_global_rect())
		):
			_fail("%s 的动态按钮不可用：窗口 %s，状态 %s" % [
				control_name,
				physical_size,
				scenario_name,
			])
			return


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	push_error(message)
	quit(1)
