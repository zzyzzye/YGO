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

ygo::PendingAction malformed_yes_no_message() {
	return {
			ygo::PendingActionKind::Malformed,
			-1,
			false,
			MSG_SELECT_YESNO,
			"是/否选择消息长度不足，无法安全解析",
	};
}

ygo::PendingAction parse_yes_no_message(
		const std::uint8_t *data,
		const std::size_t size) {
	ByteReader reader(data, size);
	std::uint8_t message_type = 0;
	std::uint8_t player = 0;
	std::uint64_t description = 0;
	if (!reader.read_u8(message_type)
			|| !reader.read_u8(player)
			|| !reader.read_u64(description)) {
		return malformed_yes_no_message();
	}
	// MSG_SELECT_YESNO 的正文固定为消息类型、玩家和 64 位描述共 10 字节；
	// 任意尾随内容都表示当前帧不符合协议，必须在发布 description 前整帧拒绝。
	if (reader.remaining() != 0) {
		return {
				ygo::PendingActionKind::Malformed,
				-1,
				false,
				MSG_SELECT_YESNO,
				"是/否选择消息含有尾随字节，无法安全解析",
		};
	}
	if (player > 1) {
		return {
				ygo::PendingActionKind::Malformed,
				-1,
				false,
				MSG_SELECT_YESNO,
				"是/否选择消息包含非法玩家编号",
		};
	}

	ygo::PendingAction pending{
			ygo::PendingActionKind::YesNo,
			static_cast<int>(player),
			false,
			MSG_SELECT_YESNO,
			"等待玩家确认是或否",
	};
	pending.description = description;
	return pending;
}

ygo::PendingAction malformed_select_card_message() {
	return {
			ygo::PendingActionKind::Malformed,
			-1,
			false,
			MSG_SELECT_CARD,
			"卡牌选择消息长度不足或字段非法，无法安全解析",
	};
}

ygo::PendingAction parse_select_card_message(
		const std::uint8_t *data,
		const std::size_t size) {
	ByteReader reader(data, size);
	std::uint8_t message_type = 0;
	std::uint8_t player = 0;
	std::uint8_t cancelable = 0;
	std::uint32_t min_select = 0;
	std::uint32_t max_select = 0;
	std::uint32_t candidate_count = 0;
	if (!reader.read_u8(message_type)
			|| !reader.read_u8(player)
			|| !reader.read_u8(cancelable)
			|| !reader.read_u32(min_select)
			|| !reader.read_u32(max_select)
			|| !reader.read_u32(candidate_count)) {
		return malformed_select_card_message();
	}
	// OCGCore 的 cancelable 仅允许布尔值，选择上下限必须能由本帧候选满足；
	// 在读取 loc_info 前拒绝矛盾范围，避免异常数量触发无意义的大量分配。
	if (player > 1 || cancelable > 1 || min_select > max_select
			|| max_select > candidate_count) {
		return malformed_select_card_message();
	}
	// 每个 loc_info 在本协议中恰好占 14 字节。使用除法而非乘法比较可避免
	// candidate_count 为极大值时溢出，并且必须在 reserve 前完成，防止畸形帧
	// 根据声明数量请求超大内存。
	constexpr std::size_t card_option_size = 14;
	if (candidate_count > reader.remaining() / card_option_size) {
		return malformed_select_card_message();
	}

	std::vector<ygo::CardSelectionOption> options;
	options.reserve(candidate_count);
	for (std::uint32_t index = 0; index < candidate_count; ++index) {
		ygo::CardSelectionOption option;
		option.index = index;
		if (!reader.read_u32(option.card_id)
				|| !reader.read_u8(option.controller)
				|| !reader.read_u8(option.location)
				|| !reader.read_u32(option.sequence)
				|| !reader.read_u32(option.position)
				|| option.controller > 1) {
			return malformed_select_card_message();
		}
		options.push_back(option);
	}
	// MSG_SELECT_CARD 不定义候选后的扩展字段；留下任何字节都意味着帧格式
	// 与当前 OCGCore 协议不一致，不能被悄悄接受为同一项玩家决策。
	if (reader.remaining() != 0) {
		return malformed_select_card_message();
	}

	ygo::PendingAction pending{
			ygo::PendingActionKind::SelectCard,
			static_cast<int>(player),
			false,
			MSG_SELECT_CARD,
			"等待玩家选择卡牌",
	};
	pending.cancelable = cancelable != 0;
	pending.min_select = min_select;
	pending.max_select = max_select;
	// 只有所有 loc_info 读取成功后才将候选交给调用方，畸形帧不能泄露半成品。
	pending.card_options = std::move(options);
	return pending;
}

ygo::PendingAction parse_select_position_message(
		const std::uint8_t *data,
		const std::size_t size) {
	ByteReader reader(data, size);
	std::uint8_t message_type = 0;
	std::uint8_t player = 0;
	std::uint32_t card_id = 0;
	std::uint8_t position_mask = 0;
	if (!reader.read_u8(message_type)
			|| !reader.read_u8(player)
			|| !reader.read_u32(card_id)
			|| !reader.read_u8(position_mask)
			|| reader.remaining() != 0) {
		return {
				ygo::PendingActionKind::Malformed,
				-1,
				false,
				MSG_SELECT_POSITION,
				"表示形式选择消息长度不是固定的 7 字节",
		};
	}
	constexpr std::uint8_t legal_mask =
			POS_FACEUP_ATTACK | POS_FACEDOWN_ATTACK
			| POS_FACEUP_DEFENSE | POS_FACEDOWN_DEFENSE;
	if (player > 1 || position_mask == 0
			|| (position_mask & static_cast<std::uint8_t>(~legal_mask)) != 0) {
		return {
				ygo::PendingActionKind::Malformed,
				-1,
				false,
				MSG_SELECT_POSITION,
				"表示形式选择消息包含非法玩家或位置掩码",
		};
	}

	ygo::PendingAction pending{
			ygo::PendingActionKind::SelectPosition,
			static_cast<int>(player),
			false,
			MSG_SELECT_POSITION,
			"等待玩家选择表示形式",
	};
	pending.selection_card_id = card_id;
	// 固定顺序是 C++/Godot 的稳定显示契约；只发布核心掩码中真实存在的
	// 单值候选，禁止界面补全或提交组合值。
	for (const std::uint32_t position : {
				POS_FACEUP_ATTACK,
				POS_FACEDOWN_ATTACK,
				POS_FACEUP_DEFENSE,
				POS_FACEDOWN_DEFENSE,
			}) {
		if ((position_mask & position) != 0) {
			pending.position_options.push_back(position);
		}
	}
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
	if (forced > 1) {
		return {
				ygo::PendingActionKind::Malformed,
				-1,
				false,
				MSG_SELECT_CHAIN,
				"连锁选择消息包含非法强制标记",
		};
	}
	// 每个候选严格对应 OCGCore 写入的 23 字节：code(4)、loc_info(10)、
	// description(8)、client_mode(1)。先按剩余长度验证，既拒绝截断/尾随，
	// 也避免由不可信 chain_count 触发过量分配。
	constexpr std::size_t chain_option_size = 23;
	if (chain_count > reader.remaining() / chain_option_size
			|| reader.remaining() != chain_count * chain_option_size) {
		return {
				ygo::PendingActionKind::Malformed,
				-1,
				false,
				MSG_SELECT_CHAIN,
				"连锁选择候选长度与协议不一致",
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

	ygo::PendingAction pending{
			ygo::PendingActionKind::SelectChain,
			static_cast<int>(player),
			false,
			MSG_SELECT_CHAIN,
			"等待玩家选择发动连锁效果",
	};
	pending.chain_forced = forced != 0;
	pending.chain_options.reserve(chain_count);
	for (std::uint32_t index = 0; index < chain_count; ++index) {
		ygo::ChainOption option;
		option.index = index;
		if (!reader.read_u32(option.card_id)
				|| !reader.read_u8(option.controller)
				|| !reader.read_u8(option.location)
				|| !reader.read_u32(option.sequence)
				|| !reader.read_u32(option.position)
				|| !reader.read_u64(option.description)
				|| !reader.read_u8(option.client_mode)
				|| option.controller > 1) {
			return {
					ygo::PendingActionKind::Malformed,
					-1,
					false,
					MSG_SELECT_CHAIN,
					"连锁选择候选包含截断或非法卡位信息",
			};
		}
		pending.chain_options.push_back(option);
	}
	return pending;
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
	// 这些消息都对应上游 Processor 的返回缓冲区读取点。已支持类型会在调用
	// 本函数前解析；剩余类型必须显式阻断，不能被通知消息过滤逻辑吞掉。
	switch (message_type) {
	case MSG_SELECT_BATTLECMD:
	case MSG_SELECT_EFFECTYN:
	case MSG_SELECT_OPTION:
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
		} else if (frame[0] == MSG_SELECT_YESNO) {
			pending = parse_yes_no_message(frame, frame_size);
		} else if (frame[0] == MSG_SELECT_CARD) {
			pending = parse_select_card_message(frame, frame_size);
		} else if (frame[0] == MSG_SELECT_POSITION) {
			pending = parse_select_position_message(frame, frame_size);
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
