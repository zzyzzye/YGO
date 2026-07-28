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
		_populate_maximum_prototype(board)
		await _wait_for_stable_layout(board)
		if _failed:
			return
		_assert_stretch_contract(physical_size)
		_assert_populated_layout(board, physical_size)
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


func _populate_maximum_prototype(board: DuelBoard) -> void:
	var player_hand_cards: Array = []
	for sequence in range(6):
		player_hand_cards.append({
			"card_id": 50000 + sequence,
			"sequence": sequence,
			"location": 2,
			"controller": 0,
			"cn_name": "响应式测试手牌 %s" % [sequence + 1],
		})
	var selected_card: Dictionary = player_hand_cards[0]
	var exact_actions := [
		{
			"card_id": selected_card.card_id,
			"sequence": selected_card.sequence,
			"location": selected_card.location,
			"controller": selected_card.controller,
			"action_kind": "normal_summon",
			"index": 0,
		},
		{
			"card_id": selected_card.card_id,
			"sequence": selected_card.sequence,
			"location": selected_card.location,
			"controller": selected_card.controller,
			"action_kind": "monster_set",
			"index": 1,
		},
		{
			"card_id": selected_card.card_id,
			"sequence": selected_card.sequence,
			"location": selected_card.location,
			"controller": selected_card.controller,
			"action_kind": "activate",
			"index": 2,
		},
	]
	board.render_snapshot({
		"player_hand": player_hand_cards,
		"opponent_hand_count": 6,
		"player_monsters": [
			{"card_id": 51001, "sequence": 0, "location": 4, "controller": 0},
			{"card_id": 51005, "sequence": 4, "location": 4, "controller": 0},
		],
		"player_spells": [
			{"card_id": 52001, "sequence": 0, "location": 8, "controller": 0},
			{"card_id": 52005, "sequence": 4, "location": 8, "controller": 0},
		],
		"opponent_monsters": [
			{"card_id": 53001, "sequence": 0, "location": 4, "controller": 1},
			{"card_id": 53005, "sequence": 4, "location": 4, "controller": 1},
		],
		"opponent_spells": [
			{"card_id": 54001, "sequence": 0, "location": 8, "controller": 1},
			{"card_id": 54005, "sequence": 4, "location": 8, "controller": 1},
		],
		"idle_actions": exact_actions,
		"local_player_turn": true,
		"phase_kind": "idle",
		"can_enter_battle": true,
		"can_end_turn": true,
		"turn_text": "玩家1 · 主要阶段",
		"status_text": LONG_STATUS,
		"player_stats": "玩家1  LP 8000  手牌 6  卡组 34",
		"opponent_stats": "玩家2  LP 8000  手牌 6  卡组 34",
	})
	board._on_card_selected(selected_card)
	board._open_phase_options([
		{"kind": "enter_battle", "text": "进入战斗阶段"},
		{"kind": "end_turn", "text": "结束回合"},
	])


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


func _assert_populated_layout(board: DuelBoard, physical_size: Vector2i) -> void:
	var logical_rect := Rect2(Vector2.ZERO, Vector2(LOGICAL_SIZE))
	var key_control_names := [
		"SafeArea",
		"Battlefield",
		"PlayerHand",
		"OpponentHand",
		"ContextActionBar",
		"StatusToast",
		"SystemTools",
		"PhaseButton",
		"CardDetailOverlay",
		"ConfirmationOverlay",
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
				"关键控件未完整留在逻辑画布：%s，窗口 %s，矩形 %s"
				% [
					node_name,
					physical_size,
					control.get_global_rect() if control != null else Rect2(),
				]
			)
			return
	var action_bar: HBoxContainer = board.action_box
	var player_hand: HandView = board.player_hand
	var status: Label = board.status_label
	var opponent_hand: HandView = board.opponent_hand
	var tools: HBoxContainer = board.find_child("SystemTools", true, false)
	if action_bar.get_child_count() != 4:
		_fail("满载动作条必须包含三个真实动作和取消按钮：" + str(physical_size))
		return
	if action_bar.get_global_rect().intersects(player_hand.get_global_rect()):
		_fail("满载动作条覆盖玩家手牌：" + str(physical_size))
		return
	if status.get_global_rect().intersects(opponent_hand.get_global_rect()):
		_fail("长中文状态覆盖对手手牌：" + str(physical_size))
		return
	var status_hand_gap := opponent_hand.get_global_rect().position.x - status.get_global_rect().end.x
	if status_hand_gap < STATUS_HAND_SAFE_GAP:
		_fail(
			"长状态与对手手牌安全间距不足：%s，仅 %.2f 像素"
			% [physical_size, status_hand_gap]
		)
		return
	if !logical_rect.encloses(tools.get_global_rect()):
		_fail("系统工具离开安全区域：" + str(physical_size))
		return
	if (
		board.player_hand.get_child_count() != 6
		or board.opponent_hand.get_child_count() != 6
	):
		_fail("满载案例必须显示双方各六张手牌：" + str(physical_size))
		return
	for zone in [
		board.player_monster_zones[0],
		board.player_monster_zones[4],
		board.player_spell_zones[0],
		board.player_spell_zones[4],
		board.opponent_monster_zones[0],
		board.opponent_monster_zones[4],
		board.opponent_spell_zones[0],
		board.opponent_spell_zones[4],
	]:
		if zone.card_container.get_child_count() != 1:
			_fail("首尾怪兽/魔陷卡位必须全部填充：" + str(physical_size))
			return
	if (
		!board.confirmation_overlay.visible
		or board.confirmation_buttons.get_child_count() != 3
	):
		_fail("确认浮层必须显示两个阶段按钮和取消按钮：" + str(physical_size))
		return
	for container in [board.action_box, board.confirmation_buttons]:
		for child in container.get_children():
			if (
				!(child is Button)
				or !child.is_visible_in_tree()
				or child.disabled
				or child.size.x <= 0.0
				or child.size.y <= 0.0
				or !logical_rect.encloses(child.get_global_rect())
			):
				_fail("动态动作或确认按钮不可用：" + str(physical_size))
				return


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	push_error(message)
	quit(1)
