extends SceneTree

const BOARD_SCENE = preload("res://src/duel/duel_board.tscn")

var _events: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var board: DuelBoard = BOARD_SCENE.instantiate()
	root.add_child(board)
	board.effect_yes_no_requested.connect(
		func(accepted: bool, generation: int) -> void:
			_events.append([accepted, generation])
	)
	await process_frame

	# 卡号为 0 表示 C++ 因隐藏信息没有发布身份；界面仍须提供完整规则响应，
	# 但只能使用通用文案，不能猜测或显示对手里侧卡名。
	var hidden_source := {
		"decision_kind": "effect_yes_no",
		"local_player_turn": true,
		"effect_card_id": 0,
		"effect_card_name": "",
		"effect_controller": 1,
		"effect_location": 4,
		"effect_sequence": 2,
		"effect_position": 8,
	}
	board.render_snapshot(hidden_source)
	var generation: int = board._rule_decision_generation
	if (
		board.confirmation_label.text != "是否发动该卡的效果？"
		or board.confirmation_buttons.get_child_count() != 2
	):
		_fail("隐藏效果来源必须使用通用文案并保留发动选择")
		return
	board.confirmation_buttons.get_child(1).pressed.emit()
	if _events != [[false, generation]]:
		_fail("不发动按钮必须提交 false 和当前决策代次")
		return

	board.render_snapshot(hidden_source, true)
	if board._rule_decision_generation != generation:
		_fail("EffectYesNo Retry 必须保留同一决策代次")
		return
	board.confirmation_buttons.get_child(0).pressed.emit()
	if _events != [[false, generation], [true, generation]]:
		_fail("Retry 重建后必须允许同代重新选择发动")
		return

	board.render_snapshot({
		"decision_kind": "effect_yes_no",
		"local_player_turn": false,
		"effect_card_id": 89631139,
		"effect_card_name": "不得显示的对手卡",
	})
	if board.confirmation_overlay.visible:
		_fail("非本地 EffectYesNo 不得暴露任何可提交入口")
		return

	print("EffectYesNo 情境交互测试通过")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
