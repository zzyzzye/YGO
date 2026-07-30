#include "ygo/pending_action_godot_adapter.hpp"

#include "ocgapi_constants.h"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <cstdint>

namespace ygo {

namespace {

const char *idle_action_kind_name(const IdleActionKind kind) {
	switch (kind) {
	case IdleActionKind::NormalSummon:
		return "normal_summon";
	case IdleActionKind::SpecialSummon:
		return "special_summon";
	case IdleActionKind::Reposition:
		return "reposition";
	case IdleActionKind::MonsterSet:
		return "monster_set";
	case IdleActionKind::SpellTrapSet:
		return "spell_trap_set";
	case IdleActionKind::Activate:
		return "activate";
	}
	return "unknown";
}

const char *battle_action_kind_name(const BattleActionKind kind) {
	switch (kind) {
	case BattleActionKind::Activate:
		return "battle_activate";
	case BattleActionKind::Attack:
		return "attack";
	}
	return "unknown";
}

const char *pending_action_kind_name(const PendingActionKind kind) {
	// 不使用 default：新增规则决策枚举时，编译器必须提醒桥接层同步定义
	// Godot 协议名，避免未知枚举静默落入错误界面状态。
	switch (kind) {
	case PendingActionKind::None:
		return "none";
	case PendingActionKind::Idle:
		return "idle";
	case PendingActionKind::Battle:
		return "battle";
	case PendingActionKind::YesNo:
		return "yes_no";
	case PendingActionKind::EffectYesNo:
		return "effect_yes_no";
	case PendingActionKind::SelectCard:
		return "select_card";
	case PendingActionKind::SelectPosition:
		return "select_position";
	case PendingActionKind::SelectChain:
		return "select_chain";
	case PendingActionKind::AutoPassChain:
		return "auto_pass_chain";
	case PendingActionKind::SelectPlace:
		return "select_place";
	case PendingActionKind::Retry:
		return "retry";
	case PendingActionKind::Unsupported:
		return "unsupported";
	case PendingActionKind::Malformed:
		return "malformed";
	}
	return "unknown";
}

} // namespace

godot::Dictionary pending_action_to_dictionary(const PendingAction &pending) {
	godot::Dictionary response;
	response["kind"] = godot::String(pending_action_kind_name(pending.kind));
	response["player"] = pending.player;
	response["can_end_turn"] = pending.can_end_turn;
	response["can_enter_battle"] = pending.can_enter_battle;
	response["can_enter_main2"] = pending.can_enter_main2;
	response["can_end_battle"] = pending.can_end_battle;
	response["message_type"] = pending.message_type;
	response["message"] = godot::String::utf8(pending.message.c_str());

	godot::Array idle_actions;
	for (const auto &action : pending.idle_actions) {
		godot::Dictionary item;
		item["action_kind"] = godot::String(idle_action_kind_name(action.kind));
		item["index"] = static_cast<std::int64_t>(action.index);
		item["card_id"] = static_cast<std::int64_t>(action.card_id);
		item["controller"] = action.controller;
		item["location"] = action.location;
		item["sequence"] = static_cast<std::int64_t>(action.sequence);
		item["description"] = static_cast<std::int64_t>(action.description);
		item["client_mode"] = action.client_mode;
		idle_actions.push_back(item);
	}
	response["idle_actions"] = idle_actions;

	godot::Array battle_actions;
	for (const auto &action : pending.battle_actions) {
		godot::Dictionary item;
		item["action_kind"] = godot::String(battle_action_kind_name(action.kind));
		item["index"] = static_cast<std::int64_t>(action.index);
		item["card_id"] = static_cast<std::int64_t>(action.card_id);
		item["controller"] = action.controller;
		item["location"] = action.location;
		item["sequence"] = static_cast<std::int64_t>(action.sequence);
		item["description"] = static_cast<std::int64_t>(action.description);
		item["client_mode"] = action.client_mode;
		item["direct_attackable"] = action.direct_attackable;
		battle_actions.push_back(item);
	}
	response["battle_actions"] = battle_actions;

	// MSG_SELECT_PLACE 的 forbidden 位图已在解析器转换为逐项语义候选。桥接层
	// 只能原样发布控制者、区域和序号，不能让 Godot 重新推导位图或默认选区。
	// 即使当前不是区域选择，也始终提供空数组以维持稳定 Dictionary 契约。
	godot::Array place_options;
	for (const PlaceOption &option : pending.place_options) {
		godot::Dictionary item;
		item["controller"] = option.player;
		item["location"] = option.location;
		item["sequence"] = option.sequence;
		place_options.push_back(item);
	}
	response["place_options"] = place_options;

	// OCGCore 脚本常用 aux.Stringid(card_id, effect_id) 生成 description，
	// 其高位可逆推出卡号。因此对手里侧效果来源必须同时隐藏卡号和描述；
	// 字段仍保持存在并归零，让 Godot 使用稳定契约和通用文案。
	const bool effect_source_visible = pending.kind != PendingActionKind::EffectYesNo
			|| pending.effect_controller == 0
			|| (pending.effect_position & POS_FACEUP) != 0;
	response["description"] = static_cast<std::int64_t>(
			effect_source_visible ? pending.description : 0);
	response["effect_card_id"] = static_cast<std::int64_t>(
			effect_source_visible
			? pending.effect_card_id
			: 0);
	response["effect_controller"] = pending.effect_controller;
	response["effect_location"] = pending.effect_location;
	response["effect_sequence"] =
			static_cast<std::int64_t>(pending.effect_sequence);
	response["effect_position"] =
			static_cast<std::int64_t>(pending.effect_position);
	response["cancelable"] = pending.cancelable;
	response["min_select"] = static_cast<std::int64_t>(pending.min_select);
	response["max_select"] = static_cast<std::int64_t>(pending.max_select);
	godot::Array card_options;
	for (const CardSelectionOption &option : pending.card_options) {
		godot::Dictionary item;
		item["index"] = static_cast<std::int64_t>(option.index);
		item["controller"] = option.controller;
		item["location"] = option.location;
		item["sequence"] = static_cast<std::int64_t>(option.sequence);
		item["position"] = static_cast<std::int64_t>(option.position);
		// 本地玩家知道自己的里侧卡；对手卡只有正面表示时才公开身份。
		// 该门禁位于 C++ 边界，避免 GDScript 误用内部查询所得的真实卡号。
		if (option.controller == 0 || (option.position & POS_FACEUP) != 0) {
			item["card_id"] = static_cast<std::int64_t>(option.card_id);
		}
		card_options.push_back(item);
	}
	response["card_options"] = card_options;
	response["selection_card_id"] =
			static_cast<std::int64_t>(pending.selection_card_id);
	godot::Array position_options;
	for (const std::uint32_t position : pending.position_options) {
		position_options.push_back(static_cast<std::int64_t>(position));
	}
	response["position_options"] = position_options;

	// SelectChain 直接对应 OCGCore 的 MSG_SELECT_CHAIN。每项 index 是当前
	// 响应窗口的唯一候选索引；位置、表示与 client_mode 可安全用于界面定位。
	// OCGCore 的 description 常由 Stringid 编码，包含可逆的 card_id 高位，
	// 所以对手里侧候选必须把 description 与 card_id 放进同一可见性门禁。
	response["chain_forced"] = pending.chain_forced;
	godot::Array chain_options;
	for (const ChainOption &option : pending.chain_options) {
		godot::Dictionary item;
		item["index"] = static_cast<std::int64_t>(option.index);
		item["controller"] = option.controller;
		item["location"] = option.location;
		item["sequence"] = static_cast<std::int64_t>(option.sequence);
		item["position"] = static_cast<std::int64_t>(option.position);
		item["client_mode"] = option.client_mode;
		if (option.controller == 0 || (option.position & POS_FACEUP) != 0) {
			item["card_id"] = static_cast<std::int64_t>(option.card_id);
			item["description"] = static_cast<std::int64_t>(option.description);
		}
		chain_options.push_back(item);
	}
	response["chain_options"] = chain_options;
	return response;
}

} // namespace ygo
