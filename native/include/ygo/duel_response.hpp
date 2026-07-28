#pragma once

#include "ygo/duel_message_parser.hpp"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace ygo {

// 语义响应构造器的纯值结果。ok=false 时 bytes 必须为空，调用方可直接把
// 中文 message 返回给界面，而不接触 OCGCore 或改变当前决策快照。
struct DuelResponse {
	bool ok = false;
	std::string message;
	std::vector<std::uint8_t> bytes;
};

// 根据已经解析并验证的待决策快照构造 OCGCore 响应。三个函数都不持有
// PendingAction，也不调用规则引擎，因此可独立验证协议字节与语义门禁。
[[nodiscard]] DuelResponse build_yes_no_response(
		const PendingAction &pending_action,
		bool accepted);
[[nodiscard]] DuelResponse build_card_selection_response(
		const PendingAction &pending_action,
		std::size_t option_index);
[[nodiscard]] DuelResponse build_card_selection_cancel_response(
		const PendingAction &pending_action);
[[nodiscard]] DuelResponse build_position_response(
		const PendingAction &pending_action,
		std::uint32_t position);
// SelectChain 通过 int32 小端候选索引发动效果；跳过则使用 int32(-1)，但仅
// 非强制窗口可以构造该响应。两个函数只消费已验证的 PendingAction 快照。
[[nodiscard]] DuelResponse build_chain_response(
		const PendingAction &pending_action,
		std::size_t option_index);
[[nodiscard]] DuelResponse build_chain_pass_response(
		const PendingAction &pending_action);

} // namespace ygo
