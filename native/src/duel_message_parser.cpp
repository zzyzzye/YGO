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

	bool read_u64(std::uint64_t &value) {
		if (remaining() < 8) {
			return false;
		}
		value = 0;
		for (std::size_t index = 0; index < 8; ++index) {
			value |= static_cast<std::uint64_t>(data_[offset_ + index])
					<< (index * 8U);
		}
		offset_ += 8;
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

	constexpr std::array<ygo::IdleActionKind, 6> action_kinds{
			ygo::IdleActionKind::NormalSummon,
			ygo::IdleActionKind::SpecialSummon,
			ygo::IdleActionKind::Reposition,
			ygo::IdleActionKind::MonsterSet,
			ygo::IdleActionKind::SpellTrapSet,
			ygo::IdleActionKind::Activate,
	};
	std::vector<ygo::IdleAction> actions;
	for (std::size_t list_index = 0; list_index < action_kinds.size(); ++list_index) {
		std::uint32_t count = 0;
		if (!reader.read_u32(count)) {
			return malformed_idle_message();
		}
		for (std::uint32_t action_index = 0; action_index < count; ++action_index) {
			ygo::IdleAction action;
			action.kind = action_kinds[list_index];
			action.index = action_index;
			if (!reader.read_u32(action.card_id)
					|| !reader.read_u8(action.controller)
					|| !reader.read_u8(action.location)) {
				return malformed_idle_message();
			}
			if (action.kind == ygo::IdleActionKind::Reposition) {
				std::uint8_t sequence = 0;
				if (!reader.read_u8(sequence)) {
					return malformed_idle_message();
				}
				action.sequence = sequence;
			} else if (!reader.read_u32(action.sequence)) {
				return malformed_idle_message();
			}
			if (action.kind == ygo::IdleActionKind::Activate
					&& (!reader.read_u64(action.description)
							|| !reader.read_u8(action.client_mode))) {
				return malformed_idle_message();
			}
			actions.push_back(action);
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

	ygo::PendingAction pending{
			ygo::PendingActionKind::Idle,
			static_cast<int>(player),
			can_end_turn != 0,
			MSG_SELECT_IDLECMD,
			can_end_turn != 0 ? "等待玩家选择空闲阶段动作"
							  : "当前空闲阶段不能结束回合",
	};
	pending.idle_actions = std::move(actions);
	pending.can_enter_battle = can_enter_battle != 0;
	return pending;
}

ygo::PendingAction malformed_battle_message() {
	return {
			ygo::PendingActionKind::Malformed,
			-1,
			false,
			MSG_SELECT_BATTLECMD,
			"战斗阶段消息长度不足，无法安全解析",
	};
}

ygo::PendingAction parse_battle_message(
		const std::uint8_t *data,
		const std::size_t size) {
	ByteReader reader(data, size);
	std::uint8_t message_type = 0;
	std::uint8_t player = 0;
	if (!reader.read_u8(message_type) || !reader.read_u8(player)) {
		return malformed_battle_message();
	}
	if (player > 1) {
		return {
				ygo::PendingActionKind::Malformed,
				-1,
				false,
				MSG_SELECT_BATTLECMD,
				"战斗阶段消息包含非法玩家编号",
		};
	}

	std::vector<ygo::BattleAction> actions;
	std::uint32_t activate_count = 0;
	if (!reader.read_u32(activate_count)) {
		return malformed_battle_message();
	}
	for (std::uint32_t index = 0; index < activate_count; ++index) {
		ygo::BattleAction action;
		action.kind = ygo::BattleActionKind::Activate;
		action.index = index;
		if (!reader.read_u32(action.card_id)
				|| !reader.read_u8(action.controller)
				|| !reader.read_u8(action.location)
				|| !reader.read_u32(action.sequence)
				|| !reader.read_u64(action.description)
				|| !reader.read_u8(action.client_mode)) {
			return malformed_battle_message();
		}
		actions.push_back(action);
	}

	std::uint32_t attack_count = 0;
	if (!reader.read_u32(attack_count)) {
		return malformed_battle_message();
	}
	for (std::uint32_t index = 0; index < attack_count; ++index) {
		ygo::BattleAction action;
		action.kind = ygo::BattleActionKind::Attack;
		action.index = index;
		std::uint8_t sequence = 0;
		std::uint8_t direct_attackable = 0;
		if (!reader.read_u32(action.card_id)
				|| !reader.read_u8(action.controller)
				|| !reader.read_u8(action.location)
				|| !reader.read_u8(sequence)
				|| !reader.read_u8(direct_attackable)) {
			return malformed_battle_message();
		}
		action.sequence = sequence;
		action.direct_attackable = direct_attackable != 0;
		actions.push_back(action);
	}

	std::uint8_t can_enter_main2 = 0;
	std::uint8_t can_end_battle = 0;
	if (!reader.read_u8(can_enter_main2) || !reader.read_u8(can_end_battle)) {
		return malformed_battle_message();
	}
	ygo::PendingAction pending{
			ygo::PendingActionKind::Battle,
			static_cast<int>(player),
			false,
			MSG_SELECT_BATTLECMD,
			"等待玩家选择战斗阶段动作",
	};
	pending.battle_actions = std::move(actions);
	pending.can_enter_main2 = can_enter_main2 != 0;
	pending.can_end_battle = can_end_battle != 0;
	return pending;
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

ygo::PendingAction parse_select_place_message(
		const std::uint8_t *data,
		const std::size_t size) {
	ByteReader reader(data, size);
	std::uint8_t message_type = 0;
	std::uint8_t player = 0;
	std::uint8_t count = 0;
	std::uint32_t forbidden = 0;
	if (!reader.read_u8(message_type)
			|| !reader.read_u8(player)
			|| !reader.read_u8(count)
			|| !reader.read_u32(forbidden)
			|| player > 1) {
		return {
				ygo::PendingActionKind::Malformed,
				-1,
				false,
				MSG_SELECT_PLACE,
				"区域选择消息长度不足或玩家编号非法",
		};
	}
	if (count != 1) {
		return {
				ygo::PendingActionKind::Unsupported,
				static_cast<int>(player),
				false,
				MSG_SELECT_PLACE,
				"当前需要同时选择多个区域，尚未实现",
		};
	}

	std::vector<ygo::PlaceOption> options;
	for (std::uint8_t side_index = 0; side_index < 2; ++side_index) {
		// 位掩码低 16 位属于当前选择者，高 16 位属于对手。候选顺序必须
		// 始终“己方优先”，否则玩家2行动时会确定性选到玩家1的区域。
		const std::uint8_t selected_player =
				side_index == 0 ? player : static_cast<std::uint8_t>(1U - player);
		const std::uint32_t player_shift =
				selected_player == player ? 0U : 16U;
		for (std::uint8_t sequence = 0; sequence <= 6; ++sequence) {
			const std::uint32_t bit = 1U << (player_shift + sequence);
			if ((forbidden & bit) == 0) {
				options.push_back({selected_player, LOCATION_MZONE, sequence});
			}
		}
		for (std::uint8_t sequence = 0; sequence <= 7; ++sequence) {
			const std::uint32_t bit = 1U << (player_shift + 8U + sequence);
			if ((forbidden & bit) == 0) {
				options.push_back({selected_player, LOCATION_SZONE, sequence});
			}
		}
	}
	if (options.empty()) {
		return {
				ygo::PendingActionKind::Malformed,
				static_cast<int>(player),
				false,
				MSG_SELECT_PLACE,
				"区域选择消息没有任何合法区域",
		};
	}
	ygo::PendingAction pending{
			ygo::PendingActionKind::AutoSelectPlace,
			static_cast<int>(player),
			false,
			MSG_SELECT_PLACE,
			"正在选择第一个合法场地区域",
	};
	pending.place_options = std::move(options);
	return pending;
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
	std::vector<LifePointEvent> life_point_events;
	int winner = -1;
	int win_reason = -1;
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
		if (frame[0] == MSG_DAMAGE
				|| frame[0] == MSG_RECOVER
				|| frame[0] == MSG_LPUPDATE) {
			ByteReader notification(frame, frame_size);
			std::uint8_t type = 0;
			std::uint8_t player = 0;
			std::uint32_t amount = 0;
			if (!notification.read_u8(type)
					|| !notification.read_u8(player)
					|| !notification.read_u32(amount)
					|| player > 1) {
				return {
						PendingActionKind::Malformed,
						-1,
						false,
						static_cast<int>(frame[0]),
						"生命值通知消息长度不足或玩家编号非法",
				};
			}
			LifePointEventKind kind = LifePointEventKind::Set;
			if (type == MSG_DAMAGE) {
				kind = LifePointEventKind::Damage;
			} else if (type == MSG_RECOVER) {
				kind = LifePointEventKind::Recover;
			}
			life_point_events.push_back({kind, player, amount});
		} else if (frame[0] == MSG_WIN) {
			if (frame_size < 3 || frame[1] > 2) {
				return {
						PendingActionKind::Malformed,
						-1,
						false,
						MSG_WIN,
						"胜负通知消息长度不足或胜者编号非法",
				};
			}
			winner = frame[1];
			win_reason = frame[2];
		} else if (frame[0] == MSG_SELECT_IDLECMD) {
			pending = parse_idle_message(frame, frame_size);
		} else if (frame[0] == MSG_SELECT_BATTLECMD) {
			pending = parse_battle_message(frame, frame_size);
		} else if (frame[0] == MSG_SELECT_CHAIN) {
			pending = parse_chain_message(frame, frame_size);
		} else if (frame[0] == MSG_SELECT_PLACE) {
			pending = parse_select_place_message(frame, frame_size);
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
	pending.life_point_events = std::move(life_point_events);
	pending.winner = winner;
	pending.win_reason = win_reason;
	return pending;
}

} // namespace ygo
