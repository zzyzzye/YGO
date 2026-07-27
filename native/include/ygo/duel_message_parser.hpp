#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace ygo {

enum class PendingActionKind {
	None,
	Idle,
	AutoPassChain,
	Retry,
	Unsupported,
	Malformed,
};

// 描述 OCGCore 当前等待的玩家决策。该值类型不暴露原始缓冲区，调用方只能
// 根据已经验证的语义字段决定是否显示或提交动作。
struct PendingAction {
	PendingActionKind kind = PendingActionKind::None;
	int player = -1;
	bool can_end_turn = false;
	int message_type = -1;
	std::string message = "当前没有待处理的玩家决策";
};

// 解析 OCGCore_DuelGetMessage 返回的完整缓冲区。缓冲区由若干
// “4 字节小端长度 + 消息正文”帧组成；函数不持有传入内存。
[[nodiscard]] PendingAction parse_pending_action(
		const std::uint8_t *data,
		std::size_t size);

} // namespace ygo
