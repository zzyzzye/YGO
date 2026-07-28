#include "ygo/pending_action_godot_adapter.hpp"
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

namespace {

void require(const bool condition, const char *message) {
	if (condition) {
		return;
	}
	std::fprintf(stderr, "PendingAction Godot 适配器契约失败：%s\n", message);
	std::abort();
}

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
	// 原始字节响应只为 C++ 兼容测试保留；一旦重新注册到 ClassDB，GDScript
	// 就能绕过 pending kind、稳定索引和决策代次等语义门禁。
	require(
			!bridge->has_method(godot::StringName("send_duel_response")),
			"send_duel_response 不得绑定到 Godot ClassDB");

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
}

void run_contract_tests() {
	test_yes_no_dictionary_contract();
	test_card_selection_hides_opponent_facedown_identity();
	test_position_selection_dictionary_contract();
	test_chain_dictionary_contract_hides_opponent_facedown_identity();
	test_bridge_rejects_negative_selection_before_narrowing();
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
