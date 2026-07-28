extends SceneTree

const BOARD_SCENE = preload("res://src/duel/duel_board.tscn")
const SIZES := [
	Vector2i(1920, 1080),
	Vector2i(3840, 2160),
	Vector2i(1920, 1200),
]
const STATUS_HAND_SAFE_GAP := 24.0
const LAYOUT_STABILITY_FRAMES := 8

var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for viewport_size in SIZES:
		await _configure_test_viewport(viewport_size)
		if _failed:
			return
		var board: DuelBoard = BOARD_SCENE.instantiate()
		root.add_child(board)
		await _wait_for_stable_layout(board)
		if _failed:
			return
		_assert_layout(board, viewport_size)
		if _failed:
			return
		# 每种尺寸使用独立实例，避免 Container 的排序队列或脚本状态污染下一轮。
		board.queue_free()
		await process_frame
		await process_frame
	print("多分辨率决斗布局契约通过")
	quit(0)


func _configure_test_viewport(viewport_size: Vector2i) -> void:
	# 项目使用 canvas_items：只修改 root.size 改到的是物理窗口像素，逻辑画布仍会
	# 固定在项目基准 1920×1080。测试把窗口与 content_scale_size 同时设成目标值，
	# 建立 1:1 的逻辑坐标，确保下方矩形断言实际覆盖三种尺寸。
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_size = viewport_size
	root.size = viewport_size
	await process_frame
	await process_frame
	var logical_size := Vector2(root.get_visible_rect().size)
	if !logical_size.is_equal_approx(Vector2(viewport_size)):
		_fail(
			"逻辑视口尺寸错误：窗口 %s，逻辑画布 %s"
			% [viewport_size, logical_size]
		)


func _wait_for_stable_layout(board: Control) -> void:
	# Container 会延迟排序；只有关键矩形连续两帧不变才开始断言，避免用固定一帧
	# 等待掩盖不同机器上的布局时序差异。
	var previous_rects: Array[Rect2] = []
	for _frame_index in range(LAYOUT_STABILITY_FRAMES):
		await process_frame
		var current_rects := _collect_key_rects(board)
		if current_rects == previous_rects:
			return
		previous_rects = current_rects
	_fail("决斗布局在限定帧数内未稳定：" + str(root.content_scale_size))


func _collect_key_rects(board: Control) -> Array[Rect2]:
	var rects: Array[Rect2] = [board.get_global_rect()]
	for node_name in [
		"Battlefield",
		"PlayerHand",
		"ContextActionBar",
		"OpponentHand",
		"StatusToast",
		"SystemTools",
	]:
		var node: Control = board.find_child(node_name, true, false)
		if node == null:
			_fail("响应式布局缺少关键节点：" + node_name)
			return rects
		rects.append(node.get_global_rect())
	return rects


func _assert_layout(board: Control, viewport_size: Vector2i) -> void:
	var viewport_rect := Rect2(Vector2.ZERO, Vector2(viewport_size))
	var action_bar: Control = board.find_child("ContextActionBar", true, false)
	var player_hand: Control = board.find_child("PlayerHand", true, false)
	var status: Control = board.find_child("StatusToast", true, false)
	var opponent_hand: Control = board.find_child("OpponentHand", true, false)
	var tools: Control = board.find_child("SystemTools", true, false)
	if action_bar.get_global_rect().intersects(player_hand.get_global_rect()):
		_fail("动作条覆盖玩家手牌：" + str(viewport_size))
		return
	if status.get_global_rect().intersects(opponent_hand.get_global_rect()):
		_fail("状态提示覆盖对手手牌：" + str(viewport_size))
		return
	var status_hand_gap := opponent_hand.get_global_rect().position.x - status.get_global_rect().end.x
	if status_hand_gap < STATUS_HAND_SAFE_GAP:
		_fail(
			"状态提示与对手手牌安全间距不足：%s，仅 %.2f 像素"
			% [viewport_size, status_hand_gap]
		)
		return
	if !viewport_rect.encloses(tools.get_global_rect()):
		_fail("系统工具离开安全视口：" + str(viewport_size))
		return
	if board.player_monster_zones.size() != 5:
		_fail("玩家怪兽区数量错误：" + str(viewport_size))


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	push_error(message)
	quit(1)
