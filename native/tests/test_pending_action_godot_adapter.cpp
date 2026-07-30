#include "ygo/pending_action_godot_adapter.hpp"
#include "ygo/process_result_godot_adapter.hpp"
#include "ygo/ygo_core_bridge.hpp"

#include "ocgapi_constants.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>

namespace {

void require(const bool condition, const char *message) {
	if (condition) {
		return;
	}
	std::fprintf(stderr, "PendingAction Godot 适配器契约失败：%s\n", message);
	std::abort();
}

} // namespace

namespace {

std::int64_t read_int(
		const godot::Dictionary &dictionary,
		const char *key) {
	return static_cast<std::int64_t>(dictionary[key]);
}

void test_yes_no_dictionary_contract() {
	ygo::PendingAction pending;
	pending.kind = ygo::PendingActionKind::YesNo;
	pending.player = 0;
	pending.description = 0x123456789ULL;

	const godot::Dictionary converted =
			ygo::pending_action_to_dictionary(pending);
	require(
			static_cast<godot::String>(converted["kind"]) == godot::String("yes_no"),
			"是非决策必须使用 yes_no kind");
	require(
			read_int(converted, "description") == 0x123456789LL,
			"是非描述编号必须按 64 位值保留");
	require(converted.has("cancelable"), "字典必须始终包含 cancelable");
	require(converted.has("min_select"), "字典必须始终包含 min_select");
	require(converted.has("max_select"), "字典必须始终包含 max_select");
	require(converted.has("card_options"), "字典必须始终包含 card_options");
	require(converted.has("place_options"), "字典必须始终包含 place_options");
	require(
			static_cast<godot::Array>(converted["place_options"]).is_empty(),
			"非区域选择决策必须发布空区域候选数组");
}

void test_effect_yes_no_dictionary_contract_and_hidden_identity() {
	ygo::PendingAction pending;
	pending.kind = ygo::PendingActionKind::EffectYesNo;
	pending.player = 0;
	pending.description = 0x123456789ULL;
	pending.effect_card_id = 89631139;
	pending.effect_controller = 0;
	pending.effect_location = LOCATION_MZONE;
	pending.effect_sequence = 3;
	pending.effect_position = POS_FACEUP_ATTACK;

	godot::Dictionary converted =
			ygo::pending_action_to_dictionary(pending);
	require(
			static_cast<godot::String>(converted["kind"])
					== godot::String("effect_yes_no"),
			"效果确认必须使用独立 effect_yes_no kind");
	require(read_int(converted, "effect_card_id") == 89631139,
			"本地效果来源必须发布卡号");
	require(read_int(converted, "effect_controller") == 0,
			"效果来源控制者必须透传");
	require(read_int(converted, "effect_location") == LOCATION_MZONE,
			"效果来源区域必须透传");
	require(read_int(converted, "effect_sequence") == 3,
			"效果来源序号必须透传");
	require(read_int(converted, "effect_position") == POS_FACEUP_ATTACK,
			"效果来源表示形式必须透传");

	pending.effect_controller = 1;
	pending.effect_position = POS_FACEDOWN_DEFENSE;
	converted = ygo::pending_action_to_dictionary(pending);
	require(
			read_int(converted, "effect_card_id") == 0
					&& read_int(converted, "description") == 0,
			"对手里侧效果来源不得通过卡号或 Stringid 描述泄露身份");
}

void test_card_selection_hides_opponent_facedown_identity() {
	ygo::PendingAction pending;
	pending.kind = ygo::PendingActionKind::SelectCard;
	pending.player = 0;
	pending.cancelable = true;
	pending.min_select = 1;
	pending.max_select = 1;
	pending.card_options = {
		{0, 111, 0, LOCATION_MZONE, 2, POS_FACEDOWN_DEFENSE},
		{1, 222, 1, LOCATION_MZONE, 3, POS_FACEDOWN_DEFENSE},
		{2, 333, 1, LOCATION_MZONE, 4, POS_FACEUP_ATTACK},
	};

	const godot::Dictionary converted =
			ygo::pending_action_to_dictionary(pending);
	require(
			static_cast<godot::String>(converted["kind"])
					== godot::String("select_card"),
			"卡牌选择必须使用 select_card kind");
	require(static_cast<bool>(converted["cancelable"]), "可取消能力必须透传");
	require(read_int(converted, "min_select") == 1, "最少选择数必须透传");
	require(read_int(converted, "max_select") == 1, "最多选择数必须透传");

	const godot::Array options = converted["card_options"];
	require(options.size() == 3, "候选数量必须保持不变");
	for (std::int64_t index = 0; index < options.size(); ++index) {
		const godot::Dictionary option = options[index];
		require(option.has("index"), "候选必须包含稳定索引");
		require(option.has("controller"), "候选必须包含控制者");
		require(option.has("location"), "候选必须包含区域");
		require(option.has("sequence"), "候选必须包含槽位");
		require(option.has("position"), "候选必须包含表示形式");
		require(read_int(option, "index") == index, "候选稳定索引不得重排");
	}

	const godot::Dictionary local_facedown = options[0];
	const godot::Dictionary opponent_facedown = options[1];
	const godot::Dictionary opponent_faceup = options[2];
	require(
			read_int(local_facedown, "card_id") == 111,
			"本地玩家里侧候选允许携带真实卡号");
	require(
			!opponent_facedown.has("card_id"),
			"对手里侧候选不得泄露真实卡号");
	require(
			read_int(opponent_faceup, "card_id") == 333,
			"对手正面候选应携带真实卡号");
}

void test_position_selection_dictionary_contract() {
	ygo::PendingAction pending;
	pending.kind = ygo::PendingActionKind::SelectPosition;
	pending.player = 0;
	pending.selection_card_id = 89631139;
	pending.position_options = {
		POS_FACEUP_ATTACK,
		POS_FACEDOWN_DEFENSE,
	};

	const godot::Dictionary converted =
			ygo::pending_action_to_dictionary(pending);
	require(
			static_cast<godot::String>(converted["kind"])
					== godot::String("select_position"),
			"表示形式决策必须使用 select_position kind");
	require(
			read_int(converted, "selection_card_id") == 89631139,
			"表示形式决策必须透传规则卡号");
	const godot::Array options = converted["position_options"];
	require(options.size() == 2, "表示形式候选数量必须保持不变");
	require(
			static_cast<std::int64_t>(options[0]) == POS_FACEUP_ATTACK
					&& static_cast<std::int64_t>(options[1]) == POS_FACEDOWN_DEFENSE,
			"表示形式离散候选不得重排或组合");
}

void test_place_selection_dictionary_uses_semantic_kind() {
	ygo::PendingAction pending;
	pending.kind = ygo::PendingActionKind::SelectPlace;
	pending.player = 0;
	pending.place_options = {
		{0, LOCATION_MZONE, 3},
		{1, LOCATION_SZONE, 1},
	};

	const godot::Dictionary converted =
			ygo::pending_action_to_dictionary(pending);
	require(
			static_cast<godot::String>(converted["kind"])
					== godot::String("select_place"),
			"区域选择必须使用 select_place kind");
	const godot::Array options = converted["place_options"];
	require(options.size() == 2, "区域选择必须保留全部合法候选");
	const godot::Dictionary local_monster_zone = options[0];
	const godot::Dictionary opponent_spell_zone = options[1];
	require(
			read_int(local_monster_zone, "controller") == 0
					&& read_int(local_monster_zone, "location") == LOCATION_MZONE
					&& read_int(local_monster_zone, "sequence") == 3,
			"本地区域候选必须按控制者、区域和序号完整发布");
	require(
			read_int(opponent_spell_zone, "controller") == 1
					&& read_int(opponent_spell_zone, "location") == LOCATION_SZONE
					&& read_int(opponent_spell_zone, "sequence") == 1,
			"对手区域候选必须按控制者、区域和序号完整发布");
}

void test_rejected_process_result_preserves_place_pending() {
	ygo::ProcessResult result;
	result.ok = true;
	result.status = OCG_DUEL_STATUS_AWAITING;
	result.message = "OCGCore 拒绝区域响应";
	result.response_rejected = true;
	result.pending_action.kind = ygo::PendingActionKind::SelectPlace;
	result.pending_action.player = 0;
	result.pending_action.message_type = MSG_SELECT_PLACE;
	result.pending_action.message = "请选择效果放置区域";
	result.pending_action.place_options = {
		{0, LOCATION_MZONE, 3},
		{1, LOCATION_SZONE, 1},
	};

	const godot::Dictionary converted =
			ygo::process_result_to_dictionary(result);
	require(static_cast<bool>(converted["ok"]), "Retry 结果必须保留成功推进语义");
	require(
			read_int(converted, "status") == OCG_DUEL_STATUS_AWAITING,
			"Retry 结果必须保留等待输入状态");
	require(
			static_cast<bool>(converted["response_rejected"]),
			"生产结果转换必须透传 OCGCore 的响应拒绝标志");

	const godot::Dictionary pending = converted["pending_action"];
	require(
			static_cast<godot::String>(pending["kind"])
					== godot::String("select_place"),
			"Retry 结果必须恢复 select_place 待处理动作");
	const godot::Array options = pending["place_options"];
	require(options.size() == 2, "Retry 结果必须完整恢复全部区域候选");
	const godot::Dictionary local_monster_zone = options[0];
	const godot::Dictionary opponent_spell_zone = options[1];
	require(
			read_int(local_monster_zone, "controller") == 0
					&& read_int(local_monster_zone, "location") == LOCATION_MZONE
					&& read_int(local_monster_zone, "sequence") == 3,
			"Retry 结果必须完整保留本地怪兽区三元组");
	require(
			read_int(opponent_spell_zone, "controller") == 1
					&& read_int(opponent_spell_zone, "location") == LOCATION_SZONE
					&& read_int(opponent_spell_zone, "sequence") == 1,
			"Retry 结果必须完整保留对手魔陷区三元组");
}

void test_bridge_submits_only_current_place_option_to_real_session() {
	// 此测试刻意经由 Godot 已绑定的 Bridge API 驱动真实 OCGCore，而不是直接
	// 调用 DuelSession：它要捕获 Bridge 误传三元组、跳过快照校验或擅自改写
	// pending 的回归。测试源码位于 native/tests，向上三级稳定回到项目根目录。
	const std::filesystem::path project_root =
			std::filesystem::path(__FILE__).parent_path().parent_path().parent_path();
	const std::string project_root_utf8 = project_root.string();

	godot::Ref<ygo::YgoCoreBridge> bridge;
	bridge.instantiate();
	require(bridge.is_valid(), "Bridge 真实区域选择测试实例创建失败");
	const godot::Dictionary initialized =
			bridge->initialize_card_database(godot::String::utf8(project_root_utf8.c_str()));
	require(static_cast<bool>(initialized["ok"]), "Bridge 必须初始化真实离线卡片数据库");

	const godot::PackedInt64Array deck = bridge->get_scripted_card_ids();
	require(deck.size() == 40, "真实区域选择测试必须取得完整 40 张离线牌组");
	const godot::Dictionary setup = bridge->setup_duel(deck, deck, 0x59474f);
	require(static_cast<bool>(setup["ok"]), "Bridge 必须成功启动真实离线决斗");

	const godot::Dictionary idle = bridge->get_pending_action();
	require(
			static_cast<godot::String>(idle["kind"]) == godot::String("idle"),
			"真实离线决斗必须先停在本地空闲决策");
	const godot::Array idle_actions = idle["idle_actions"];
	std::int64_t normal_summon_index = -1;
	for (std::int64_t index = 0; index < idle_actions.size(); ++index) {
		const godot::Dictionary action = idle_actions[index];
		if (static_cast<godot::String>(action["action_kind"])
				== godot::String("normal_summon")) {
			normal_summon_index = read_int(action, "index");
			break;
		}
	}
	require(normal_summon_index >= 0, "真实离线决斗必须提供通常召唤候选");

	const godot::Dictionary started_selection =
			bridge->submit_idle_action(godot::String("normal_summon"), normal_summon_index);
	require(static_cast<bool>(started_selection["ok"]), "通常召唤必须推进到区域选择");
	const godot::Dictionary before_forgery = started_selection["pending_action"];
	require(
			static_cast<godot::String>(before_forgery["kind"])
					== godot::String("select_place"),
			"通常召唤必须由 Bridge 暴露真实 SelectPlace 决策");
	const godot::Array place_options = before_forgery["place_options"];
	require(place_options.size() > 1, "区域选择必须提供多个真实候选");

	// 255 属于 uint8 范围，却不属于真实候选；因此失败必须来自 Session 的
	// 快照匹配，而不是 Bridge 的范围门禁。pending 仍须完整保留给界面重试。
	const godot::Dictionary forged = bridge->submit_place(0, LOCATION_MZONE, 255);
	require(!static_cast<bool>(forged["ok"]), "伪造但未越界的区域三元组必须被拒绝");
	const godot::Dictionary rejected_pending = forged["pending_action"];
	require(
			static_cast<godot::String>(rejected_pending["kind"])
					== godot::String("select_place"),
			"伪造区域被拒绝后必须保留 SelectPlace 决策");
	const godot::Array rejected_options = rejected_pending["place_options"];
	require(
			rejected_options.size() == place_options.size(),
			"伪造区域被拒绝后候选数量不得变化");
	for (std::int64_t index = 0; index < place_options.size(); ++index) {
		const godot::Dictionary expected = place_options[index];
		const godot::Dictionary actual = rejected_options[index];
		require(
				read_int(actual, "controller") == read_int(expected, "controller")
						&& read_int(actual, "location") == read_int(expected, "location")
						&& read_int(actual, "sequence") == read_int(expected, "sequence"),
				"伪造区域被拒绝后候选三元组不得重排或被改写");
	}
	require(
			static_cast<godot::String>(bridge->get_pending_action()["kind"])
					== godot::String("select_place"),
			"伪造区域被拒绝后当前 Bridge 快照不得推进");

	std::int64_t chosen_controller = -1;
	std::int64_t chosen_location = -1;
	std::int64_t chosen_sequence = -1;
	for (std::int64_t index = 1; index < place_options.size(); ++index) {
		const godot::Dictionary option = place_options[index];
		if (read_int(option, "controller") == 0
				&& read_int(option, "location") == LOCATION_MZONE
				&& read_int(option, "sequence") == 3) {
			chosen_controller = read_int(option, "controller");
			chosen_location = read_int(option, "location");
			chosen_sequence = read_int(option, "sequence");
			break;
		}
	}
	require(
			chosen_sequence == 3,
			"真实区域选择必须允许提交非首项的本地怪兽区序号 3");
	const godot::Dictionary accepted = bridge->submit_place(
			chosen_controller, chosen_location, chosen_sequence);
	require(static_cast<bool>(accepted["ok"]), "合法非首区域候选必须被 Bridge 提交");

	// 通常召唤可能紧接着要求表示形式；仍须通过 Bridge 消费它，才能在真实
	// 场面中观察 OCGCore 已采用的 sequence，而非凭返回结果推测提交成功。
	godot::Dictionary after_place = accepted["pending_action"];
	if (static_cast<godot::String>(after_place["kind"])
			== godot::String("select_position")) {
		const godot::Array positions = after_place["position_options"];
		require(!positions.is_empty(), "表示形式决策必须包含真实候选");
		const godot::Dictionary positioned =
				bridge->submit_position(static_cast<std::int64_t>(positions[0]));
		require(static_cast<bool>(positioned["ok"]), "合法表示形式候选必须被提交");
	}
	const godot::Dictionary state = bridge->get_duel_state();
	require(static_cast<bool>(state["ok"]), "提交区域后必须能读取真实决斗状态");
	const godot::Dictionary players = state["players"];
	const godot::Dictionary local_player = players["p1"];
	const godot::Array monster_cards = local_player["monster_cards"];
	bool placed_at_selected_sequence = false;
	for (std::int64_t index = 0; index < monster_cards.size(); ++index) {
		const godot::Dictionary card = monster_cards[index];
		if (read_int(card, "sequence") == chosen_sequence) {
			placed_at_selected_sequence = true;
			break;
		}
	}
	require(
			placed_at_selected_sequence,
			"合法非首区域候选必须更新真实场面的对应序号");
	bridge->destroy_duel();
}

void test_chain_dictionary_contract_hides_opponent_facedown_identity() {
	// OCGCore 卡片脚本常用 Stringid(card_id, effect_id)，其高位可直接还原卡号。
	// 因此对手里侧候选必须同时隐藏 card_id 与 description；仅隐藏前者仍会泄密。
	constexpr std::uint64_t hidden_string_id =
			(static_cast<std::uint64_t>(222) << 20U) | 4U;
	ygo::PendingAction pending;
	pending.kind = ygo::PendingActionKind::SelectChain;
	pending.player = 0;
	pending.chain_forced = true;
	pending.chain_options = {
		{7, 111, 0, LOCATION_HAND, 2, POS_FACEDOWN_DEFENSE, 101, 3},
		{8, 222, 1, LOCATION_SZONE, 3, POS_FACEDOWN_DEFENSE, hidden_string_id, 4},
		{9, 333, 1, LOCATION_MZONE, 4, POS_FACEUP_ATTACK, 303, 5},
	};

	const godot::Dictionary converted =
			ygo::pending_action_to_dictionary(pending);
	require(
			static_cast<godot::String>(converted["kind"])
					== godot::String("select_chain"),
			"连锁决策必须使用 select_chain kind");
	require(
			static_cast<bool>(converted["chain_forced"]),
			"强制连锁标记必须透传");
	const godot::Array options = converted["chain_options"];
	require(options.size() == 3, "连锁候选数量必须保持不变");

	const godot::Dictionary local_facedown = options[0];
	const godot::Dictionary opponent_facedown = options[1];
	const godot::Dictionary opponent_faceup = options[2];
	for (const godot::Dictionary &option : {
				local_facedown, opponent_facedown, opponent_faceup}) {
		require(option.has("index"), "连锁候选必须包含稳定索引");
		require(option.has("controller"), "连锁候选必须包含控制者");
		require(option.has("location"), "连锁候选必须包含区域");
		require(option.has("sequence"), "连锁候选必须包含槽位");
		require(option.has("position"), "连锁候选必须包含表示形式");
		require(option.has("client_mode"), "连锁候选必须包含客户端模式");
	}
	require(read_int(local_facedown, "index") == 7, "连锁候选索引不得重排");
	require(read_int(local_facedown, "card_id") == 111, "本地里侧连锁候选允许公开卡号");
	require(local_facedown.has("description"), "本地里侧连锁候选应保留效果描述编号");
	require(
			!opponent_facedown.has("card_id")
					&& !opponent_facedown.has("description"),
			"对手里侧连锁候选不得泄露真实卡号或 Stringid 描述");
	require(
			read_int(opponent_faceup, "card_id") == 333
					&& opponent_faceup.has("description"),
			"对手正面连锁候选应公开卡号和效果描述编号");
}

void test_bridge_rejects_negative_selection_before_narrowing() {
	godot::Ref<ygo::YgoCoreBridge> bridge;
	bridge.instantiate();
	require(bridge.is_valid(), "Bridge 测试实例创建失败");
	require(
			bridge->has_method(godot::StringName("submit_yes_no")),
			"submit_yes_no 必须绑定到 Godot");
	require(
			bridge->has_method(godot::StringName("submit_card_selection")),
			"submit_card_selection 必须绑定到 Godot");
	require(
			bridge->has_method(godot::StringName("submit_position")),
			"submit_position 必须绑定到 Godot");
	require(
			bridge->has_method(godot::StringName("cancel_card_selection")),
			"cancel_card_selection 必须绑定到 Godot");
	require(
			bridge->has_method(godot::StringName("submit_chain")),
			"submit_chain 必须绑定到 Godot");
	require(
			bridge->has_method(godot::StringName("pass_chain")),
			"pass_chain 必须绑定到 Godot");
	require(
			bridge->has_method(godot::StringName("submit_place")),
			"submit_place 必须绑定到 Godot");
	// 原始字节响应只为 C++ 兼容测试保留；一旦重新注册到 ClassDB，GDScript
	// 就能绕过 pending kind、稳定索引和决策代次等语义门禁。
	require(
			!bridge->has_method(godot::StringName("send_duel_response")),
			"send_duel_response 不得绑定到 Godot ClassDB");
	const godot::Dictionary inactive_place =
			bridge->submit_place(0, LOCATION_MZONE, 3);
	require(!static_cast<bool>(inactive_place["ok"]), "无活动会话不得提交合法区域三元组");
	require(
			static_cast<godot::String>(inactive_place["message"])
					== godot::String::utf8("决斗尚未创建"),
			"无活动会话的合法区域三元组必须返回中文会话错误");

	const godot::Dictionary rejected = bridge->submit_card_selection(-1);
	require(!static_cast<bool>(rejected["ok"]), "负索引必须被拒绝");
	require(
			static_cast<godot::String>(rejected["message"])
					== godot::String::utf8("卡牌候选索引不能为负数"),
			"负索引必须返回明确中文范围错误");
	const godot::Dictionary negative_position = bridge->submit_position(-1);
	require(
			!static_cast<bool>(negative_position["ok"])
				&& static_cast<godot::String>(negative_position["message"])
						== godot::String::utf8("表示形式超出 OCGCore 协议范围"),
			"负表示形式必须在窄化前拒绝");
	const godot::Dictionary oversized_position =
			bridge->submit_position(0x100000000LL);
	require(
			!static_cast<bool>(oversized_position["ok"])
				&& static_cast<godot::String>(oversized_position["message"])
						== godot::String::utf8("表示形式超出 OCGCore 协议范围"),
			"超过 uint32 的表示形式必须在窄化前拒绝");
	const godot::Dictionary negative_chain = bridge->submit_chain(-1);
	require(!static_cast<bool>(negative_chain["ok"]), "连锁负索引必须被拒绝");
	require(
			static_cast<godot::String>(negative_chain["message"])
					== godot::String::utf8("连锁候选索引不能为负数"),
			"连锁负索引必须在无符号窄化前返回明确中文范围错误");
	const godot::Dictionary inactive_pass = bridge->pass_chain();
	require(!static_cast<bool>(inactive_pass["ok"]), "无活动会话不得跳过连锁");
	require(
			static_cast<godot::String>(inactive_pass["message"])
					== godot::String::utf8("决斗尚未创建"),
			"无活动会话的跳过连锁必须返回中文门禁错误");
	const godot::Dictionary negative_place = bridge->submit_place(-1, LOCATION_MZONE, 3);
	require(!static_cast<bool>(negative_place["ok"]), "负区域控制者必须被拒绝");
	require(
			static_cast<godot::String>(negative_place["message"])
					== godot::String::utf8("区域选择参数超出 OCGCore 协议范围"),
			"负区域控制者必须在窄化前返回中文范围错误");
	const godot::Dictionary oversized_place = bridge->submit_place(0, 256, 3);
	require(!static_cast<bool>(oversized_place["ok"]), "超过 uint8 的区域必须被拒绝");
	require(
			static_cast<godot::String>(oversized_place["message"])
					== godot::String::utf8("区域选择参数超出 OCGCore 协议范围"),
			"超过 uint8 的区域必须在窄化前返回中文范围错误");
}

void run_contract_tests() {
	test_yes_no_dictionary_contract();
	test_effect_yes_no_dictionary_contract_and_hidden_identity();
	test_card_selection_hides_opponent_facedown_identity();
	test_position_selection_dictionary_contract();
	test_place_selection_dictionary_uses_semantic_kind();
	test_rejected_process_result_preserves_place_pending();
	test_bridge_submits_only_current_place_option_to_real_session();
	test_chain_dictionary_contract_hides_opponent_facedown_identity();
	test_bridge_rejects_negative_selection_before_narrowing();
	godot::Ref<ygo::YgoCoreBridge> bridge;
	bridge.instantiate();
	require(
			bridge->has_method(godot::StringName("submit_effect_yes_no")),
			"submit_effect_yes_no 必须独立绑定到 Godot");
	std::fprintf(stdout, "PendingAction Godot 适配器契约测试通过\n");
}

void initialize_test_extension(const godot::ModuleInitializationLevel level) {
	if (level != godot::MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	godot::ClassDB::register_class<ygo::YgoCoreBridge>();
	run_contract_tests();
}

void uninitialize_test_extension(const godot::ModuleInitializationLevel level) {
	if (level != godot::MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

} // namespace

extern "C" {

GDExtensionBool GDE_EXPORT ygo_pending_action_adapter_test_init(
		GDExtensionInterfaceGetProcAddress get_proc_address,
		GDExtensionClassLibraryPtr library,
		GDExtensionInitialization *initialization) {
	godot::GDExtensionBinding::InitObject init_object(
			get_proc_address,
			library,
			initialization);
	init_object.register_initializer(initialize_test_extension);
	init_object.register_terminator(uninitialize_test_extension);
	init_object.set_minimum_library_initialization_level(
			godot::MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_object.init();
}
}
