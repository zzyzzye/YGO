extends Control

const DUEL_SEED = 0x59474f
const STARTING_DECK_SIZE = 40
const ATTACK_CONTEXT_NONE := 0
const ATTACK_CONTEXT_SUBMITTING_ACTION := 1
const ATTACK_CONTEXT_ROUTE := 2
const ATTACK_CONTEXT_AWAITING_TARGET := 3
const ATTACK_CONTEXT_TARGET := 4

var bridge: Object
# DuelBoard 由 Main 场景直接实例化，唯一节点既是编辑器内可见的布局，也是运行时
# 快照渲染的唯一目标；测试仍可在未入树的 Main 脚本实例上替换该成员进行注入。
@onready var board: DuelBoard = %DuelBoard
# 怪兽预选只能保存 OCGCore 的稳定规则位置，不能缓存卡号或界面节点。后续
# SelectCard 快照到达后必须以 controller/location/sequence 三字段重新匹配。
var _pending_attack_target_preview: Dictionary = {}
# Bridge 调用是同步的，但输入信号可能在同一调用栈内重入（例如双击或测试转发）。
# 锁只覆盖一次 Bridge 调用；返回失败后立即释放，以保留当前快照并允许用户重试。
var _submission_in_progress := false
# Main 只接受当前已渲染快照中的候选索引。成功提交并刷新后，这份快照会被替换，
# 因此旧节点或延迟信号不能重复使用上一帧 index。
var _current_pending_action: Dictionary = {}
# 攻击目标只能来自本地提交的 attack 动作，不能仅凭 SelectCard 的形状猜测。
# 状态机跨越同步 Bridge 调用保存来源；其他规则决策、终局或重开都会清零。
var _attack_target_context_state := ATTACK_CONTEXT_NONE
# 该值对应当前已经渲染的快照。攻击目标与取消处理器必须再次检查它，防止
# 已清理节点或人工残留信号绕过 DuelBoard 的表现门禁。
var _current_attack_target_context_supported := false


func _ready() -> void:
	var owns_bridge := bridge == null
	if owns_bridge:
		assert(ClassDB.class_exists("YgoCoreBridge"))
		bridge = ClassDB.instantiate("YgoCoreBridge")
	_connect_board_signals()

	# 测试可在入树前注入与真实接口一致的 FakeBridge；正式运行 bridge 为空，
	# 仍严格执行原生类构造和卡库初始化，不改变生产生命周期。
	if owns_bridge:
		var initialized: Dictionary = bridge.call(
			"initialize_card_database",
			ProjectSettings.globalize_path("res://")
		)
		assert(initialized.ok)
	_start_duel(DUEL_SEED)


func _connect_board_signals() -> void:
	# 所有界面意图都先经由 DuelBoard 信号转交 Bridge；集中绑定可保证场景实例
	# 与测试注入对象使用相同的规则入口，界面不会自行改写决斗快照。
	board.idle_action_requested.connect(_on_idle_action_requested)
	board.battle_action_requested.connect(_on_battle_action_requested)
	board.end_turn_requested.connect(_on_end_turn_requested)
	board.enter_battle_requested.connect(_on_enter_battle_requested)
	board.enter_main2_requested.connect(_on_enter_main2_requested)
	board.end_battle_requested.connect(_on_end_battle_requested)
	board.direct_attack_requested.connect(_on_direct_attack_requested)
	board.attack_target_preview_requested.connect(_on_attack_target_preview_requested)
	board.attack_target_requested.connect(_on_attack_target_requested)
	board.card_selection_cancel_requested.connect(_on_card_selection_cancel_requested)
	board.yes_no_requested.connect(_on_yes_no_requested)
	board.position_requested.connect(_on_position_requested)
	board.chain_requested.connect(_on_chain_requested)
	board.chain_pass_requested.connect(_on_chain_pass_requested)
	board.restart_requested.connect(_on_restart_requested)
	board.exit_requested.connect(_on_exit_requested)


func _start_duel(duel_seed: int) -> void:
	_clear_attack_target_preview()
	_clear_attack_target_context()
	_current_pending_action.clear()
	_submission_in_progress = false
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


func _refresh_board(status_text: String, pending_override: Dictionary = {}) -> void:
	var state: Dictionary = bridge.call("get_duel_state")
	# Retry 响应已经携带 Session 恢复后的决策，优先采用同一次调用的返回值，
	# 避免额外查询与后续自动推进之间出现观察时序差异。
	var pending: Dictionary = (
		pending_override.duplicate(true)
		if !pending_override.is_empty()
		else bridge.call("get_pending_action")
	)
	if !state.ok:
		board.show_status("读取决斗状态失败：" + str(state.message))
		return

	var game_over := bool(state.get("game_over", false))
	_update_attack_target_context(pending, game_over)
	var player_state: Dictionary = state.players.p1
	var opponent_state: Dictionary = state.players.p2
	# 终局快照可能仍带核心最后一个 SelectCard；它只用于调试展示，不能继续
	# 作为 Main 的可提交快照，否则延迟到达的旧候选信号仍会触碰 Bridge。
	_current_pending_action = {} if game_over else pending.duplicate(true)
	_current_attack_target_context_supported = (
		!game_over
		and (
			(
				_attack_target_context_state == ATTACK_CONTEXT_ROUTE
				and _is_local_attack_route_pending(pending)
			)
			or (
				_attack_target_context_state == ATTACK_CONTEXT_TARGET
				and _is_complete_attack_target_selection(
					pending,
					opponent_state.get("monster_cards", [])
				)
			)
		)
	)
	# 预选只允许跨越攻击路线 YesNo→SelectCard 这一条规则边。其他决策、
	# 重新开局和终局都不能继承旧位置，否则可能命中另一帧恰好同序号的卡。
	if (
		game_over
		or _attack_target_context_state != ATTACK_CONTEXT_TARGET
		or !_current_attack_target_context_supported
	):
		_clear_attack_target_preview()
	var actions: Array = []
	if !game_over and int(pending.get("player", -1)) == 0:
		actions = (
			pending.get("battle_actions", [])
			if str(pending.get("kind", "none")) == "battle"
			else pending.get("idle_actions", [])
		)
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
			and pending.get("kind", "none") in [
				"idle", "battle", "yes_no", "select_card", "select_position",
				"select_chain",
			]
			and int(pending.get("player", -1)) == 0,
		"phase_kind": str(pending.get("kind", "none")),
		# C++ 只公开已经校验的决策语义；Main 负责提交候选并在成功后重取快照，
		# DuelBoard 只渲染和转发意图，任何一层都不得提前改写规则状态。
		"decision_kind": str(pending.get("kind", "none")),
		"decision_description": int(pending.get("description", 0)),
		"selection_cancelable": bool(pending.get("cancelable", false)),
		"selection_min": int(pending.get("min_select", 0)),
		"selection_max": int(pending.get("max_select", 0)),
		"card_options": pending.get("card_options", []),
		"selection_card_id": int(pending.get("selection_card_id", 0)),
		"position_options": pending.get("position_options", []),
		"chain_forced": bool(pending.get("chain_forced", false)),
		"chain_options": pending.get("chain_options", []),
		# DuelBoard 只能在 Main 已证明决策来源属于当前攻击流程时解释目标；
		# false 的 SelectCard 仍保留在 Bridge pending 中，但不会获得攻击入口。
		"attack_target_context_supported": _current_attack_target_context_supported,
		"can_enter_battle": bool(pending.get("can_enter_battle", false)),
		"can_enter_main2": bool(pending.get("can_enter_main2", false)),
		"can_end_battle": bool(pending.get("can_end_battle", false)),
		"can_end_turn": pending.get("kind", "none") == "idle"
			and !game_over
			and int(pending.get("player", -1)) == 0
			and bool(pending.get("can_end_turn", false)),
		"idle_actions": actions,
		"turn_text": _turn_text(pending),
		"status_text": effective_status,
		"debug_text": "OCGCore 11.0 · 消息 %s · 玩家1 卡组/手牌 %s/%s · 玩家2 卡组/手牌 %s/%s" % [
			pending.get("message_type", 0),
			player_state.deck,
			player_state.hand,
			opponent_state.deck,
			opponent_state.hand,
		],
	}
	board.render_snapshot(snapshot)
	if (
		!game_over
		and _current_attack_target_context_supported
		and _attack_target_context_state == ATTACK_CONTEXT_TARGET
	):
		_submit_previewed_attack_target(pending)


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
	if _submission_in_progress:
		return
	_clear_attack_target_preview()
	_clear_attack_target_context()
	if action_kind == "attack":
		# 必须在调用 Bridge 前进入临时状态；同步返回的新 pending 只有在这条
		# 已成功提交的本地攻击路径上，才有资格被提升为路线或目标上下文。
		_attack_target_context_state = ATTACK_CONTEXT_SUBMITTING_ACTION
	_submission_in_progress = true
	var response: Dictionary = bridge.call("submit_battle_action", action_kind, index)
	_submission_in_progress = false
	if !response.ok:
		_clear_attack_target_context()
		board.show_status("战斗动作失败：" + str(response.message))
		return
	board._clear_selection()
	_refresh_board("战斗动作已提交，场面已由 OCGCore 更新")


func _on_direct_attack_requested() -> void:
	if _submission_in_progress:
		return
	if !_is_attack_route_pending():
		return
	_clear_attack_target_preview()
	_submit_yes_no_response(true, "直击路线已提交")


func _on_attack_target_preview_requested(location: Dictionary) -> void:
	if _submission_in_progress or !_is_attack_route_pending():
		return
	_pending_attack_target_preview = _rule_location(location)
	_submit_yes_no_response(false, "已进入攻击目标选择")


func _on_attack_target_requested(option_index: int) -> void:
	if (
		_submission_in_progress
		or !_current_attack_target_context_supported
		or _attack_target_context_state != ATTACK_CONTEXT_TARGET
		or !_current_pending_has_option(option_index)
	):
		return
	_submission_in_progress = true
	var response: Dictionary = bridge.call("submit_card_selection", option_index)
	_submission_in_progress = false
	if !bool(response.get("ok", false)):
		board.show_status("攻击目标提交失败：" + str(response.get("message", "未知错误")))
		return
	if _restore_rejected_response(response):
		return
	_clear_attack_target_preview()
	_clear_attack_target_context()
	_refresh_board("攻击目标已提交，场面已由 OCGCore 更新")


func _on_card_selection_cancel_requested() -> void:
	if (
		_submission_in_progress
		or !_current_attack_target_context_supported
		or _attack_target_context_state != ATTACK_CONTEXT_TARGET
		or !bool(_current_pending_action.get("cancelable", false))
	):
		return
	# 显式取消成功后会放弃整条预选路径；本地失败或 OCGCore Retry 时仍须
	# 保留当前合法候选供重试，不能把“请求已发出”误当成“规则已接受”。
	var preview_before_cancel := _pending_attack_target_preview.duplicate()
	_clear_attack_target_preview()
	_submission_in_progress = true
	var response: Dictionary = bridge.call("cancel_card_selection")
	_submission_in_progress = false
	if !bool(response.get("ok", false)):
		board.show_status("取消目标选择失败：" + str(response.get("message", "未知错误")))
		return
	if bool(response.get("response_rejected", false)):
		_pending_attack_target_preview = preview_before_cancel
		_restore_rejected_response(response)
		return
	_clear_attack_target_context()
	_refresh_board("已取消攻击目标选择")


func _on_yes_no_requested(accepted: bool) -> void:
	if (
		_submission_in_progress
		or str(_current_pending_action.get("kind", "none")) != "yes_no"
		or int(_current_pending_action.get("player", -1)) != 0
		or int(_current_pending_action.get("description", 0)) == 31
	):
		return
	_clear_attack_target_preview()
	_submit_yes_no_response(accepted, "规则确认已提交")


func _on_position_requested(
	selected_position: int,
	decision_generation: int
) -> void:
	if (
		_submission_in_progress
		or decision_generation != board._rule_decision_generation
		or str(_current_pending_action.get("kind", "none")) != "select_position"
		or int(_current_pending_action.get("player", -1)) != 0
		or selected_position not in _current_pending_action.get("position_options", [])
	):
		return
	_submission_in_progress = true
	var response: Dictionary = bridge.call("submit_position", selected_position)
	_submission_in_progress = false
	if !bool(response.get("ok", false)):
		board.show_status(
			"表示形式提交失败：" + str(response.get("message", "未知错误"))
		)
		return
	if bool(response.get("response_rejected", false)):
		_refresh_board(
			"OCGCore 拒绝了响应，请重新选择",
			response.get("pending_action", {})
		)
		return
	_refresh_board("表示形式已提交，场面已由 OCGCore 更新")


func _on_chain_requested(index: int, decision_generation: int) -> void:
	if (
		_submission_in_progress
		or decision_generation != board._rule_decision_generation
		or board._rule_decision_kind != "select_chain"
		or !_current_chain_has_option(index)
	):
		return
	_submit_chain_response("submit_chain", index)


func _on_chain_pass_requested(decision_generation: int) -> void:
	if (
		_submission_in_progress
		or decision_generation != board._rule_decision_generation
		or board._rule_decision_kind != "select_chain"
		or str(_current_pending_action.get("kind", "none")) != "select_chain"
		or int(_current_pending_action.get("player", -1)) != 0
		or bool(_current_pending_action.get("chain_forced", false))
	):
		return
	_submit_chain_response("pass_chain")


func _submit_chain_response(method_name: String, index: int = -1) -> void:
	# 锁必须在同步 Bridge 调用前持有；测试双击、旧按钮或 Bridge 回调重入都只能
	# 观察到锁定态。失败后不刷新快照，从而保留当前完整映射和按钮供玩家重试。
	_submission_in_progress = true
	var response: Dictionary = (
		bridge.call(method_name, index)
		if method_name == "submit_chain"
		else bridge.call(method_name)
	)
	_submission_in_progress = false
	if !bool(response.get("ok", false)):
		board.show_status(
			"连锁响应提交失败：" + str(response.get("message", "未知错误"))
		)
		return
	if _restore_rejected_response(response):
		return
	_refresh_board(
		"连锁效果已提交，场面已由 OCGCore 更新"
		if method_name == "submit_chain"
		else "已选择不连锁，场面已由 OCGCore 更新"
	)


func _current_chain_has_option(index: int) -> bool:
	if (
		str(_current_pending_action.get("kind", "none")) != "select_chain"
		or int(_current_pending_action.get("player", -1)) != 0
	):
		return false
	for option in _current_pending_action.get("chain_options", []):
		if int(option.get("index", -1)) == index:
			return true
	return false


func _submit_yes_no_response(accepted: bool, success_text: String) -> void:
	if _submission_in_progress:
		return
	var responds_to_attack_route := (
		_attack_target_context_state == ATTACK_CONTEXT_ROUTE
		and _is_local_attack_route_pending(_current_pending_action)
	)
	_submission_in_progress = true
	var response: Dictionary = bridge.call("submit_yes_no", accepted)
	_submission_in_progress = false
	if !bool(response.get("ok", false)):
		board.show_status("规则确认失败：" + str(response.get("message", "未知错误")))
		return
	if _restore_rejected_response(response):
		return
	if responds_to_attack_route:
		_attack_target_context_state = (
			ATTACK_CONTEXT_NONE
			if accepted
			else ATTACK_CONTEXT_AWAITING_TARGET
		)
	_refresh_board(success_text)


func _restore_rejected_response(response: Dictionary) -> bool:
	if !bool(response.get("response_rejected", false)):
		return false
	# MSG_RETRY 的 ok=true 表示会话本身仍可用，不代表玩家响应已被接受。
	# Bridge 已把提交前 PendingAction 恢复到 Session；这里不改变攻击来源
	# 状态和预选，只刷新真实快照，让同一个合法入口可再次提交。
	var preview_before_refresh := _pending_attack_target_preview.duplicate()
	_refresh_board(
		"OCGCore 拒绝了响应，请重新选择",
		response.get("pending_action", {})
	)
	# 路线 YesNo(false) 的怪兽预选需要跨过 Retry 后再次提交；常规刷新会
	# 因当前仍是 ROUTE 而清空它，所以只在结构化拒绝分支恢复这份位置。
	_pending_attack_target_preview = preview_before_refresh
	board.show_status("OCGCore 拒绝了响应，请重新选择")
	return true


func _submit_previewed_attack_target(pending: Dictionary) -> void:
	if _pending_attack_target_preview.is_empty():
		return
	# 无论是否匹配，预选都只消费一次。未匹配时保留 SelectCard 的真实高亮，
	# 等待用户明确点击；匹配时提交的仍是 Bridge 返回的候选 index。
	var preview := _pending_attack_target_preview.duplicate()
	_clear_attack_target_preview()
	for option in pending.get("card_options", []):
		if _rule_location(option) == preview:
			_on_attack_target_requested(int(option.get("index", -1)))
			return


func _current_pending_has_option(option_index: int) -> bool:
	for option in _current_pending_action.get("card_options", []):
		if int(option.get("index", -1)) == option_index:
			return true
	return false


func _is_local_single_card_selection(pending: Dictionary) -> bool:
	# 只有本地玩家的 1 选 1 决策才符合 DuelBoard 当前攻击目标交互协议。
	# 对手决策和多选即使意外收到残留信号，也必须留给规则核心的其他流程处理。
	return (
		str(pending.get("kind", "none")) == "select_card"
		and int(pending.get("player", -1)) == 0
		and int(pending.get("min_select", 0)) == 1
		and int(pending.get("max_select", 0)) == 1
	)


func _is_complete_attack_target_selection(
	pending: Dictionary,
	opponent_monsters: Array
) -> bool:
	if !_is_local_single_card_selection(pending):
		return false
	var options: Array = pending.get("card_options", [])
	if options.is_empty():
		return false

	# 决斗状态中的对手怪兽可能因隐藏信息省略卡号，但 sequence 仍是公开且稳定的
	# OCGCore 卡位语义。只记录实际存在的 0..4 卡位，不读取或输出任何身份字段。
	var occupied_sequences: Dictionary = {}
	for monster in opponent_monsters:
		var sequence := int(monster.get("sequence", -1))
		if sequence >= 0 and sequence <= 4:
			occupied_sequences[sequence] = true

	# 不能把部分可映射候选降级成较小集合，否则界面提交的选择范围会与核心不同。
	# 任一候选不属于对手怪兽区、越界或没有对应快照卡位时，整组都不受支持。
	for option in options:
		var controller := int(option.get("controller", -1))
		var location := int(option.get("location", -1))
		var sequence := int(option.get("sequence", -1))
		if (
			controller != 1
			or location != 4
			or sequence < 0
			or sequence > 4
			or !occupied_sequences.has(sequence)
		):
			return false
	return true


func _is_attack_route_pending() -> bool:
	return (
		_attack_target_context_state == ATTACK_CONTEXT_ROUTE
		and _current_attack_target_context_supported
		and _is_local_attack_route_pending(_current_pending_action)
	)


func _is_local_attack_route_pending(pending: Dictionary) -> bool:
	return (
		str(pending.get("kind", "none")) == "yes_no"
		and int(pending.get("player", -1)) == 0
		and int(pending.get("description", 0)) == 31
	)


func _update_attack_target_context(pending: Dictionary, game_over: bool) -> void:
	if game_over:
		_clear_attack_target_context()
		return
	match _attack_target_context_state:
		ATTACK_CONTEXT_SUBMITTING_ACTION:
			if _is_local_attack_route_pending(pending):
				_attack_target_context_state = ATTACK_CONTEXT_ROUTE
			elif _is_local_single_card_selection(pending):
				_attack_target_context_state = ATTACK_CONTEXT_TARGET
			else:
				_clear_attack_target_context()
		ATTACK_CONTEXT_AWAITING_TARGET:
			if _is_local_single_card_selection(pending):
				_attack_target_context_state = ATTACK_CONTEXT_TARGET
			else:
				_clear_attack_target_context()
		ATTACK_CONTEXT_ROUTE:
			if !_is_local_attack_route_pending(pending):
				_clear_attack_target_context()
		ATTACK_CONTEXT_TARGET:
			if !_is_local_single_card_selection(pending):
				_clear_attack_target_context()


func _rule_location(data: Dictionary) -> Dictionary:
	return {
		"controller": int(data.get("controller", -1)),
		"location": int(data.get("location", -1)),
		"sequence": int(data.get("sequence", -1)),
	}


func _clear_attack_target_preview() -> void:
	_pending_attack_target_preview.clear()


func _clear_attack_target_context() -> void:
	_attack_target_context_state = ATTACK_CONTEXT_NONE
	_current_attack_target_context_supported = false


func _turn_text(pending: Dictionary) -> String:
	if str(pending.get("kind", "none")) == "idle":
		return "玩家%s · 主阶段" % [int(pending.get("player", -1)) + 1]
	if str(pending.get("kind", "none")) == "battle":
		return "玩家%s · 战斗阶段" % [int(pending.get("player", -1)) + 1]
	return "规则处理中"


func _on_restart_requested() -> void:
	_clear_attack_target_preview()
	_clear_attack_target_context()
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
