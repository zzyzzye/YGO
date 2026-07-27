#include "ygo/duel_message_parser.hpp"

#include "ocgapi_constants.h"

#include <array>
#include <limits>

namespace {

class ByteReader final {
public:
	ByteReader(const std::uint8_t *data, const std::size_t size) :
			data_(data),
			size_(size) {
	}

	bool read_u8(std::uint8_t &value) {
		if (remaining() < 1) {
			return false;
		}
		value = data_[offset_++];
		return true;
	}

	bool read_u32(std::uint32_t &value) {
		if (remaining() < 4) {
			return false;
		}
		value = static_cast<std::uint32_t>(data_[offset_])
				| (static_cast<std::uint32_t>(data_[offset_ + 1]) << 8U)
				| (static_cast<std::uint32_t>(data_[offset_ + 2]) << 16U)
				| (static_cast<std::uint32_t>(data_[offset_ + 3]) << 24U);
		offset_ += 4;
		return true;
	}

	bool skip(const std::size_t count) {
		if (remaining() < count) {
			return false;
		}
		offset_ += count;
		return true;
	}

	[[nodiscard]] std::size_t remaining() const {
		return size_ - offset_;
	}

	[[nodiscard]] const std::uint8_t *current() const {
		return data_ + offset_;
	}

private:
	const std::uint8_t *data_ = nullptr;
	std::size_t size_ = 0;
	std::size_t offset_ = 0;
};

ygo::PendingAction malformed_idle_message() {
	return {
			ygo::PendingActionKind::Malformed,
			-1,
			false,
			MSG_SELECT_IDLECMD,
			"空闲阶段消息长度不足，无法安全解析",
	};
}

ygo::PendingAction parse_idle_message(
		const std::uint8_t *data,
		const std::size_t size) {
	ByteReader reader(data, size);
	std::uint8_t message_type = 0;
	std::uint8_t player = 0;
	if (!reader.read_u8(message_type) || !reader.read_u8(player)) {
		return malformed_idle_message();
	}
	if (player > 1) {
		return {
				ygo::PendingActionKind::Malformed,
				-1,
				false,
				MSG_SELECT_IDLECMD,
				"空闲阶段消息包含非法玩家编号",
		};
	}

	// 六组候选项与上游 playerop.cpp 的 MSG_SELECT_IDLECMD 写入顺序严格对应：
	// 通常召唤、特殊召唤、表示形式变更、怪兽盖放、魔陷盖放、可发动效果。
	constexpr std::array<std::size_t, 6> element_sizes{10, 10, 7, 10, 10, 19};
	for (const auto element_size : element_sizes) {
		std::uint32_t count = 0;
		if (!reader.read_u32(count)
				|| count > std::numeric_limits<std::size_t>::max() / element_size
				|| !reader.skip(static_cast<std::size_t>(count) * element_size)) {
			return malformed_idle_message();
		}
	}

	std::uint8_t can_enter_battle = 0;
	std::uint8_t can_end_turn = 0;
	std::uint8_t can_shuffle = 0;
	if (!reader.read_u8(can_enter_battle)
			|| !reader.read_u8(can_end_turn)
			|| !reader.read_u8(can_shuffle)) {
		return malformed_idle_message();
	}

	return {
			ygo::PendingActionKind::Idle,
			static_cast<int>(player),
			can_end_turn != 0,
			MSG_SELECT_IDLECMD,
			can_end_turn != 0 ? "等待玩家选择空闲阶段动作"
							  : "当前空闲阶段不能结束回合",
	};
}

ygo::PendingAction parse_chain_message(
		const std::uint8_t *data,
		const std::size_t size) {
	ByteReader reader(data, size);
	std::uint8_t message_type = 0;
	std::uint8_t player = 0;
	std::uint8_t special_count = 0;
	std::uint8_t forced = 0;
	std::uint32_t chain_count = 0;
	if (!reader.read_u8(message_type)
			|| !reader.read_u8(player)
			|| !reader.read_u8(special_count)
			|| !reader.read_u8(forced)
			|| !reader.skip(8)
			|| !reader.read_u32(chain_count)) {
		return {
				ygo::PendingActionKind::Malformed,
				-1,
				false,
				MSG_SELECT_CHAIN,
				"连锁选择消息长度不足，无法安全解析",
		};
	}
	if (player > 1) {
		return {
				ygo::PendingActionKind::Malformed,
				-1,
				false,
				MSG_SELECT_CHAIN,
				"连锁选择消息包含非法玩家编号",
		};
	}
	if (forced == 0 && chain_count == 0) {
		return {
				ygo::PendingActionKind::AutoPassChain,
				static_cast<int>(player),
				false,
				MSG_SELECT_CHAIN,
				"当前没有可发动连锁，将自动跳过响应窗口",
		};
	}
	return {
			ygo::PendingActionKind::Unsupported,
			static_cast<int>(player),
			false,
			MSG_SELECT_CHAIN,
			"当前连锁选择包含候选效果，尚未实现",
	};
}

bool requires_player_response(const std::uint8_t message_type) {
	// 这些消息都对应上游 Processor 的返回缓冲区读取点。当前里程碑只实现
	// MSG_SELECT_IDLECMD，其余类型必须显式阻断，不能被通知消息过滤逻辑吞掉。
	switch (message_type) {
	case MSG_SELECT_BATTLECMD:
	case MSG_SELECT_EFFECTYN:
	case MSG_SELECT_YESNO:
	case MSG_SELECT_OPTION:
	case MSG_SELECT_CARD:
	case MSG_SELECT_CHAIN:
	case MSG_SELECT_PLACE:
	case MSG_SELECT_POSITION:
	case MSG_SELECT_TRIBUTE:
	case MSG_SORT_CHAIN:
	case MSG_SELECT_COUNTER:
	case MSG_SELECT_SUM:
	case MSG_SELECT_DISFIELD:
	case MSG_SORT_CARD:
	case MSG_SELECT_UNSELECT_CARD:
	case MSG_ROCK_PAPER_SCISSORS:
	case MSG_ANNOUNCE_RACE:
	case MSG_ANNOUNCE_ATTRIB:
	case MSG_ANNOUNCE_CARD:
	case MSG_ANNOUNCE_NUMBER:
		return true;
	default:
		return false;
	}
}

} // namespace

namespace ygo {

PendingAction parse_pending_action(
		const std::uint8_t *data,
		const std::size_t size) {
	PendingAction pending;
	if (data == nullptr || size == 0) {
		return pending;
	}

	ByteReader stream(data, size);
	while (stream.remaining() > 0) {
		std::uint32_t frame_size = 0;
		if (!stream.read_u32(frame_size) || frame_size == 0
				|| stream.remaining() < frame_size) {
			return {
					PendingActionKind::Malformed,
					-1,
					false,
					-1,
					"OCGCore 消息帧长度无效",
			};
		}

		const std::uint8_t *frame = stream.current();
		if (frame[0] == MSG_SELECT_IDLECMD) {
			pending = parse_idle_message(frame, frame_size);
		} else if (frame[0] == MSG_SELECT_CHAIN) {
			pending = parse_chain_message(frame, frame_size);
		} else if (frame[0] == MSG_RETRY) {
			pending = {
					PendingActionKind::Retry,
					-1,
					false,
					MSG_RETRY,
					"OCGCore 拒绝了上一条玩家响应",
			};
		} else if (requires_player_response(frame[0])) {
			pending = {
					PendingActionKind::Unsupported,
					-1,
					false,
					static_cast<int>(frame[0]),
					"当前 OCGCore 玩家决策类型尚未实现",
			};
		}
		if (!stream.skip(frame_size)) {
			return {
					PendingActionKind::Malformed,
					-1,
					false,
					-1,
					"OCGCore 消息帧读取越界",
			};
		}
	}
	return pending;
}

} // namespace ygo
