extends Control

const DUEL_SEED = 0x59474f
const STARTING_DECK_SIZE = 40
const DUEL_BOARD_SCRIPT = preload("res://src/duel/duel_board.gd")

var bridge: Object
var board


func _ready() -> void:
	assert(ClassDB.class_exists("YgoCoreBridge"))
	bridge = ClassDB.instantiate("YgoCoreBridge")
	board = DUEL_BOARD_SCRIPT.new()
	add_child(board)
	board.idle_action_requested.connect(_on_idle_action_requested)
	board.battle_action_requested.connect(_on_battle_action_requested)
	board.end_turn_requested.connect(_on_end_turn_requested)
	board.enter_battle_requested.connect(_on_enter_battle_requested)
	board.enter_main2_requested.connect(_on_enter_main2_requested)
	board.end_battle_requested.connect(_on_end_battle_requested)
	board.restart_requested.connect(_on_restart_requested)
	board.exit_requested.connect(_on_exit_requested)

	var initialized: Dictionary = bridge.call(
		"initialize_card_database",
		ProjectSettings.globalize_path("res://")
	)
	assert(initialized.ok)
	_start_duel(DUEL_SEED)


func _start_duel(duel_seed: int) -> void:
	var source_ids: PackedInt64Array = bridge.call("get_scripted_card_ids")
	if source_ids.size() < STARTING_DECK_SIZE:
		board.show_status("可用演示卡不足 40 张，无法建局")
		return
	var deck1 := _build_deck_ids(source_ids, duel_seed)
	var deck2 := _build_deck_ids(source_ids, duel_seed ^ 0x123456)
	var setup: Dictionary = bridge.call("setup_duel", deck1, deck2, duel_seed)
	if !setup.ok:
		board.show_status("建局失败：" + str(setup.message))
		return
	_refresh_board("黑白功能场已连接真实 OCGCore")


func _build_deck_ids(source_ids: PackedInt64Array, duel_seed: int) -> PackedInt64Array:
	var ids: Array = Array(source_ids)
	var rng := RandomNumberGenerator.new()
	rng.seed = duel_seed
	for index in range(ids.size() - 1, 0, -1):
		var other := rng.randi_range(0, index)
		var temporary = ids[index]
		ids[index] = ids[other]
		ids[other] = temporary
	var deck := PackedInt64Array()
	for index in range(STARTING_DECK_SIZE):
		deck.append(ids[index])
	return deck


func _refresh_board(status_text: String) -> void:
	var state: Dictionary = bridge.call("get_duel_state")
	var pending: Dictionary = bridge.call("get_pending_action")
	if !state.ok:
		board.show_status("读取决斗状态失败：" + str(state.message))
		return

	var game_over := bool(state.get("game_over", false))
	var actions: Array = []
	if !game_over and int(pending.player) == 0:
		actions = (
			pending.get("battle_actions", [])
			if str(pending.kind) == "battle"
			else pending.get("idle_actions", [])
		)
	var player_state: Dictionary = state.players.p1
	var opponent_state: Dictionary = state.players.p2
	var effective_status := status_text
	if game_over:
		var winner := int(state.get("winner", -1))
		effective_status = (
			"对局结束：玩家%s获胜" % [winner + 1]
			if winner in [0, 1]
			else "对局结束：平局"
		)
	var snapshot := {
		"player_hand": player_state.get("hand_cards", []),
		"opponent_hand_count": int(opponent_state.hand),
		"player_monsters": player_state.get("monster_cards", []),
		"player_spells": player_state.get("spell_trap_cards", []),
		"opponent_monsters": opponent_state.get("monster_cards", []),
		"opponent_spells": opponent_state.get("spell_trap_cards", []),
		"player_stats": "LP %s　卡组 %s　额外 %s　墓地 %s　除外 %s" % [
			player_state.get("lp", 8000),
			player_state.deck, player_state.extra, player_state.graveyard, player_state.banished,
		],
		"opponent_stats": "LP %s　卡组 %s　额外 %s　墓地 %s　除外 %s" % [
			opponent_state.get("lp", 8000),
			opponent_state.deck, opponent_state.extra, opponent_state.graveyard, opponent_state.banished,
		],
		# MSG_WIN 后 OCGCore 可能仍保留最后一个决策快照；终局标志必须优先
		# 关闭本地动作，避免玩家在已经结束的决斗上继续提交阶段响应。
		"local_player_turn": !game_over
			and pending.kind in ["idle", "battle"]
			and int(pending.player) == 0,
		"phase_kind": str(pending.kind),
		"can_enter_battle": bool(pending.get("can_enter_battle", false)),
		"can_enter_main2": bool(pending.get("can_enter_main2", false)),
		"can_end_battle": bool(pending.get("can_end_battle", false)),
		"can_end_turn": pending.kind == "idle"
			and !game_over
			and int(pending.player) == 0
			and bool(pending.can_end_turn),
		"idle_actions": actions,
		"turn_text": _turn_text(pending),
		"status_text": effective_status,
		"debug_text": "OCGCore 11.0 · 消息 %s · 玩家1 卡组/手牌 %s/%s · 玩家2 卡组/手牌 %s/%s" % [
			pending.message_type,
			player_state.deck,
			player_state.hand,
			opponent_state.deck,
			opponent_state.hand,
		],
	}
	board.render_snapshot(snapshot)


func _on_idle_action_requested(
		action_kind: String,
		index: int,
		_card_data: Dictionary
) -> void:
	var response: Dictionary = bridge.call("submit_idle_action", action_kind, index)
	if !response.ok:
		board.show_status("动作失败：" + str(response.message))
		return
	board._clear_selection()
	_refresh_board("%s成功，场面已由 OCGCore 更新" % _action_text(action_kind))


func _on_end_turn_requested() -> void:
	var response: Dictionary = bridge.call("submit_end_turn")
	if !response.ok:
		board.show_status("结束回合失败：" + str(response.message))
		return
	_refresh_board("对手已自动结束回合，玩家1进入下一回合")

func _on_enter_battle_requested() -> void:
	_submit_phase_action("submit_enter_battle", "已进入战斗阶段")


func _on_enter_main2_requested() -> void:
	_submit_phase_action("submit_enter_main2", "已进入主要阶段二")


func _on_end_battle_requested() -> void:
	_submit_phase_action("submit_end_battle", "战斗阶段结束")


func _submit_phase_action(method_name: String, success_text: String) -> void:
	var response: Dictionary = bridge.call(method_name)
	if !response.ok:
		board.show_status("阶段切换失败：" + str(response.message))
		return
	_refresh_board(success_text)


func _on_battle_action_requested(
		action_kind: String,
		index: int,
		_card_data: Dictionary
) -> void:
	var response: Dictionary = bridge.call("submit_battle_action", action_kind, index)
	if !response.ok:
		board.show_status("战斗动作失败：" + str(response.message))
		return
	board._clear_selection()
	_refresh_board("战斗动作已提交，场面已由 OCGCore 更新")


func _turn_text(pending: Dictionary) -> String:
	if str(pending.kind) == "idle":
		return "玩家%s · 主阶段" % [int(pending.player) + 1]
	if str(pending.kind) == "battle":
		return "玩家%s · 战斗阶段" % [int(pending.player) + 1]
	return "规则处理中"


func _on_restart_requested() -> void:
	var new_seed := int(Time.get_unix_time_from_system()) & 0x7fffffff
	_start_duel(new_seed if new_seed > 0 else DUEL_SEED)


func _on_exit_requested() -> void:
	# 退出树时会进入 _exit_tree() 并销毁活动 DuelSession，避免全屏窗口
	# 直接消失后仍让 OCGCore 持有卡库或脚本加载器的借用指针。
	get_tree().quit()


func _action_text(action_kind: String) -> String:
	match action_kind:
		"normal_summon":
			return "通常召唤"
		"monster_set":
			return "怪兽盖放"
		"spell_trap_set":
			return "魔陷盖放"
		"activate":
			return "发动效果"
		_:
			return "动作"


func _exit_tree() -> void:
	if bridge != null and bridge.call("is_duel_active"):
		bridge.call("destroy_duel")
