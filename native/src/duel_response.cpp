#include "ygo/duel_response.hpp"

#include <algorithm>
#include <limits>

namespace ygo {

DuelResponse build_yes_no_response(
		const PendingAction &pending_action,
		const bool accepted) {
	if (pending_action.kind != PendingActionKind::YesNo) {
		return {false, "当前不是是非选择", {}};
	}

	// MSG_SELECT_YESNO 使用有符号 32 位整数；这里显式逐字节编码，避免把
	// 主机端字节序和 int 宽度泄漏到 OCGCore 协议边界。
	const std::int32_t value = accepted ? 1 : 0;
	const std::uint8_t response[4]{
			static_cast<std::uint8_t>(value & 0xff),
			static_cast<std::uint8_t>((value >> 8) & 0xff),
			static_cast<std::uint8_t>((value >> 16) & 0xff),
			static_cast<std::uint8_t>((value >> 24) & 0xff),
	};
	return {true, "", {response, response + sizeof(response)}};
}

DuelResponse build_effect_yes_no_response(
		const PendingAction &pending_action,
		const bool accepted) {
	if (pending_action.kind != PendingActionKind::EffectYesNo) {
		return {false, "当前不是效果发动确认", {}};
	}

	// SelectEffectYesNo 与普通 YesNo 都读取 int32，但保持独立构造器可防止调用方
	// 用普通确认快照误消费带效果来源位置的规则决策。
	const std::uint8_t value = accepted ? 1 : 0;
	return {true, "", {value, 0, 0, 0}};
}

DuelResponse build_card_selection_response(
		const PendingAction &pending_action,
		const std::size_t option_index) {
	if (pending_action.kind != PendingActionKind::SelectCard) {
		return {false, "当前不是卡牌选择", {}};
	}
	// 当前接口固定编码 count=1，只能消费解析器明确标记为 1/1 的单选
	// 快照；多选或零选约束必须留待后续专用语义接口，不能交给 core 试错。
	if (pending_action.min_select != 1 || pending_action.max_select != 1) {
		return {false, "当前原型只支持选择一张卡牌", {}};
	}
	const auto candidate = std::find_if(
			pending_action.card_options.begin(),
			pending_action.card_options.end(),
			[option_index](const CardSelectionOption &option) {
				return option.index == option_index;
			});
	if (candidate == pending_action.card_options.end()) {
		return {false, "卡牌候选不属于当前 OCGCore 候选列表", {}};
	}
	if (option_index > std::numeric_limits<std::uint32_t>::max()) {
		return {false, "卡牌候选索引超出 OCGCore 协议范围", {}};
	}

	// SelectCard 的 type=0 表示索引列表，count=1 表示当前接口只提交一个
	// 已验证候选；option_index 对应解析器保留的 OCGCore 原始候选下标。
	const std::uint8_t response[12]{
			0, 0, 0, 0,
			1, 0, 0, 0,
			static_cast<std::uint8_t>(option_index & 0xffU),
			static_cast<std::uint8_t>((option_index >> 8U) & 0xffU),
			static_cast<std::uint8_t>((option_index >> 16U) & 0xffU),
			static_cast<std::uint8_t>((option_index >> 24U) & 0xffU),
	};
	return {true, "", {response, response + sizeof(response)}};
}

DuelResponse build_card_selection_cancel_response(
		const PendingAction &pending_action) {
	if (pending_action.kind != PendingActionKind::SelectCard) {
		return {false, "当前不是卡牌选择", {}};
	}
	if (pending_action.min_select != 1 || pending_action.max_select != 1) {
		return {false, "当前原型只支持选择一张卡牌", {}};
	}
	if (!pending_action.cancelable) {
		return {false, "当前卡牌选择不可取消", {}};
	}

	// OCGCore 以 int32(-1) 表示取消选择，固定写为小端四字节，避免依赖
	// 宿主机对负数右移或对象表示的实现细节。
	return {true, "", {0xff, 0xff, 0xff, 0xff}};
}

DuelResponse build_position_response(
		const PendingAction &pending_action,
		const std::uint32_t position) {
	if (pending_action.kind != PendingActionKind::SelectPosition) {
		return {false, "当前不是表示形式选择", {}};
	}
	const auto candidate = std::find(
			pending_action.position_options.begin(),
			pending_action.position_options.end(),
			position);
	if (candidate == pending_action.position_options.end()) {
		return {false, "表示形式不属于当前 OCGCore 候选列表", {}};
	}
	// MSG_SELECT_POSITION 接受位置常量的 int32 小端值。候选已由解析器拆成
	// 单值，这里仍逐字节编码，避免宿主端字节序进入协议边界。
	return {
		true,
		"",
		{
			static_cast<std::uint8_t>(position & 0xffU),
			static_cast<std::uint8_t>((position >> 8U) & 0xffU),
			static_cast<std::uint8_t>((position >> 16U) & 0xffU),
			static_cast<std::uint8_t>((position >> 24U) & 0xffU),
		},
	};
}

DuelResponse build_place_response(
		const PendingAction &pending_action,
		const std::uint8_t player,
		const std::uint8_t location,
		const std::uint8_t sequence) {
	if (pending_action.kind != PendingActionKind::SelectPlace) {
		return {false, "当前不是区域选择", {}};
	}
	const auto candidate = std::find_if(
			pending_action.place_options.begin(),
			pending_action.place_options.end(),
			[player, location, sequence](const PlaceOption &option) {
				return option.player == player && option.location == location
						&& option.sequence == sequence;
			});
	if (candidate == pending_action.place_options.end()) {
		return {false, "区域候选不属于当前 OCGCore 候选列表", {}};
	}
	// OCGCore 对单区域选择不接受索引或位掩码，而是读取三个原始字节。候选
	// 已由解析器验证，本层只将完整三元组原样编码，绝不推断或修正卡位。
	return {true, "", {player, location, sequence}};
}

DuelResponse build_chain_response(
		const PendingAction &pending_action,
		const std::size_t option_index) {
	if (pending_action.kind != PendingActionKind::SelectChain) {
		return {false, "当前不是连锁选择", {}};
	}
	const auto candidate = std::find_if(
			pending_action.chain_options.begin(),
			pending_action.chain_options.end(),
			[option_index](const ChainOption &option) {
				return option.index == option_index;
			});
	if (candidate == pending_action.chain_options.end()) {
		return {false, "连锁候选不属于当前 OCGCore 候选列表", {}};
	}
	if (option_index
			> static_cast<std::size_t>(std::numeric_limits<std::int32_t>::max())) {
		return {false, "连锁候选索引超出 OCGCore 有符号协议范围", {}};
	}
	// SelectChain 直接读取已选候选的 int32 下标。只允许从快照候选表取值，
	// 以免 Godot 按卡片或效果描述重新匹配后提交一个已失效的索引。
	return {
		true,
		"",
		{
			static_cast<std::uint8_t>(option_index & 0xffU),
			static_cast<std::uint8_t>((option_index >> 8U) & 0xffU),
			static_cast<std::uint8_t>((option_index >> 16U) & 0xffU),
			static_cast<std::uint8_t>((option_index >> 24U) & 0xffU),
		},
	};
}

DuelResponse build_chain_pass_response(const PendingAction &pending_action) {
	if (pending_action.kind != PendingActionKind::SelectChain) {
		return {false, "当前不是连锁选择", {}};
	}
	if (pending_action.chain_forced) {
		return {false, "强制连锁必须发动一个候选效果", {}};
	}
	// OCGCore 对非强制连锁以 int32(-1) 表示跳过。字面量编码规避宿主端
	// 字节序和负数对象表示差异，且不会改变当前待处理快照。
	return {true, "", {0xff, 0xff, 0xff, 0xff}};
}

} // namespace ygo
