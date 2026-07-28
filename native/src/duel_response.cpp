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

} // namespace ygo
