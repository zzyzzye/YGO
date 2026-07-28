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
			bridge->has_method(godot::StringName("cancel_card_selection")),
			"cancel_card_selection 必须绑定到 Godot");

	const godot::Dictionary rejected = bridge->submit_card_selection(-1);
	require(!static_cast<bool>(rejected["ok"]), "负索引必须被拒绝");
	require(
			static_cast<godot::String>(rejected["message"])
					== godot::String::utf8("卡牌候选索引不能为负数"),
			"负索引必须返回明确中文范围错误");
}

void run_contract_tests() {
	test_yes_no_dictionary_contract();
	test_card_selection_hides_opponent_facedown_identity();
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
