#include "ygo/duel_message_parser.hpp"

#include "ocgapi_constants.h"

#include <cassert>
#include <cstdint>
#include <vector>

namespace {

template <typename T>
void append_little_endian(std::vector<std::uint8_t> &bytes, T value) {
	// 测试夹具显式按 OCGCore 当前平台协议写入小端整数，避免复用生产解析逻辑
	// 导致“实现和期望同时写错”却仍然通过。
	for (std::size_t index = 0; index < sizeof(T); ++index) {
		bytes.push_back(static_cast<std::uint8_t>(
				(static_cast<std::uint64_t>(value) >> (index * 8U)) & 0xffU));
	}
}

void append_frame(
		std::vector<std::uint8_t> &stream,
		const std::vector<std::uint8_t> &message) {
	append_little_endian<std::uint32_t>(
			stream,
			static_cast<std::uint32_t>(message.size()));
	stream.insert(stream.end(), message.begin(), message.end());
}

std::vector<std::uint8_t> framed(const std::vector<std::uint8_t> &message) {
	std::vector<std::uint8_t> stream;
	append_frame(stream, message);
	return stream;
}

void append_card_option(
		std::vector<std::uint8_t> &message,
		const std::uint32_t card_id,
		const std::uint8_t controller,
		const std::uint8_t location,
		const std::uint32_t sequence,
		const std::uint32_t position) {
	// MSG_SELECT_CARD 的每个候选固定携带卡片编号和 loc_info。测试夹具逐字段
	// 写入协议值，以便捕获生产代码对 sequence 或 position 宽度的误读。
	append_little_endian<std::uint32_t>(message, card_id);
	message.push_back(controller);
	message.push_back(location);
	append_little_endian<std::uint32_t>(message, sequence);
	append_little_endian<std::uint32_t>(message, position);
}

void append_chain_option(
		std::vector<std::uint8_t> &message,
		const std::uint32_t card_id,
		const std::uint8_t controller,
		const std::uint8_t location,
		const std::uint32_t sequence,
		const std::uint32_t position,
		const std::uint64_t description,
		const std::uint8_t client_mode) {
	// MSG_SELECT_CHAIN 的候选必须完整保留卡位、效果描述和客户端模式。这里
	// 手工写入上游固定的 23 字节记录，防止测试与生产解析共用实现细节。
	append_little_endian<std::uint32_t>(message, card_id);
	message.push_back(controller);
	message.push_back(location);
	append_little_endian<std::uint32_t>(message, sequence);
	append_little_endian<std::uint32_t>(message, position);
	append_little_endian<std::uint64_t>(message, description);
	message.push_back(client_mode);
}

void test_notification_before_idle_action_does_not_hide_pending_player() {
	std::vector<std::uint8_t> stream;
	append_frame(stream, {MSG_NEW_TURN, 0});

	std::vector<std::uint8_t> idle{MSG_SELECT_IDLECMD, 0};
	for (int list_index = 0; list_index < 6; ++list_index) {
		append_little_endian<std::uint32_t>(idle, 0);
	}
	idle.push_back(1); // 可以进入战斗阶段。
	idle.push_back(1); // 可以进入结束阶段。
	idle.push_back(0); // 当前不可洗手牌。
	append_frame(stream, idle);

	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::Idle);
	assert(pending.player == 0);
	assert(pending.can_enter_battle);
	assert(pending.can_end_turn);
	assert(pending.message_type == MSG_SELECT_IDLECMD);
}

void test_battle_message_exposes_attackers_and_phase_options() {
	std::vector<std::uint8_t> stream;
	std::vector<std::uint8_t> battle{MSG_SELECT_BATTLECMD, 0};

	append_little_endian<std::uint32_t>(battle, 1);
	append_little_endian<std::uint32_t>(battle, 46986414);
	battle.push_back(0);
	battle.push_back(LOCATION_SZONE);
	append_little_endian<std::uint32_t>(battle, 3);
	append_little_endian<std::uint64_t>(battle, 0x1122334455667788ULL);
	battle.push_back(2);
	append_little_endian<std::uint32_t>(battle, 1);
	append_little_endian<std::uint32_t>(battle, 89631139);
	battle.push_back(0);
	battle.push_back(LOCATION_MZONE);
	battle.push_back(2);
	battle.push_back(1); // 可以直接攻击。
	battle.push_back(1); // 可以进入主要阶段二。
	battle.push_back(1); // 可以结束战斗阶段。
	append_frame(stream, battle);

	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::Battle);
	assert(pending.player == 0);
	assert(pending.can_enter_main2);
	assert(pending.can_end_battle);
	assert(pending.battle_actions.size() == 2);
	assert(pending.battle_actions[0].kind == ygo::BattleActionKind::Activate);
	assert(pending.battle_actions[0].card_id == 46986414);
	assert(pending.battle_actions[0].description == 0x1122334455667788ULL);
	assert(pending.battle_actions[1].kind == ygo::BattleActionKind::Attack);
	assert(pending.battle_actions[1].card_id == 89631139);
	assert(pending.battle_actions[1].sequence == 2);
	assert(pending.battle_actions[1].direct_attackable);
}

void test_life_point_and_win_notifications_are_preserved() {
	std::vector<std::uint8_t> stream;
	std::vector<std::uint8_t> damage{MSG_DAMAGE, 1};
	append_little_endian<std::uint32_t>(damage, 2500);
	append_frame(stream, damage);
	std::vector<std::uint8_t> recover{MSG_RECOVER, 0};
	append_little_endian<std::uint32_t>(recover, 500);
	append_frame(stream, recover);
	std::vector<std::uint8_t> update{MSG_LPUPDATE, 1};
	append_little_endian<std::uint32_t>(update, 7000);
	append_frame(stream, update);
	append_frame(stream, {MSG_WIN, 0, 1});

	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.life_point_events.size() == 3);
	assert(pending.life_point_events[0].kind
			== ygo::LifePointEventKind::Damage);
	assert(pending.life_point_events[0].player == 1);
	assert(pending.life_point_events[0].amount == 2500);
	assert(pending.life_point_events[1].kind
			== ygo::LifePointEventKind::Recover);
	assert(pending.life_point_events[2].kind
			== ygo::LifePointEventKind::Set);
	assert(pending.winner == 0);
	assert(pending.win_reason == 1);
}

void test_truncated_frame_is_reported_as_malformed() {
	const std::vector<std::uint8_t> stream{
			8, 0, 0, 0, // 声明正文有 8 字节。
			MSG_SELECT_IDLECMD,
			0, // 实际正文仅有 2 字节。
	};

	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::Malformed);
}

void test_yes_no_message_exposes_player_and_description() {
	std::vector<std::uint8_t> yes_no{MSG_SELECT_YESNO, 0};
	append_little_endian<std::uint64_t>(yes_no, 31);
	const std::vector<std::uint8_t> stream = framed(yes_no);
	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::YesNo);
	assert(pending.player == 0);
	assert(pending.description == 31);
	assert(pending.message_type == MSG_SELECT_YESNO);
}

void test_yes_no_rejects_invalid_player_and_truncated_description() {
	std::vector<std::uint8_t> invalid_player{MSG_SELECT_YESNO, 2};
	append_little_endian<std::uint64_t>(invalid_player, 31);
	const std::vector<std::uint8_t> invalid_player_stream = framed(invalid_player);
	const ygo::PendingAction invalid_player_pending =
			ygo::parse_pending_action(
				invalid_player_stream.data(), invalid_player_stream.size());
	assert(invalid_player_pending.kind == ygo::PendingActionKind::Malformed);
	assert(invalid_player_pending.message
			== "是/否选择消息包含非法玩家编号");

	const std::vector<std::uint8_t> truncated_stream =
			framed({MSG_SELECT_YESNO, 0, 31, 0, 0, 0, 0, 0, 0});
	const ygo::PendingAction truncated_pending =
			ygo::parse_pending_action(
				truncated_stream.data(), truncated_stream.size());
	assert(truncated_pending.kind == ygo::PendingActionKind::Malformed);
	assert(truncated_pending.message
			== "是/否选择消息长度不足，无法安全解析");
}

void test_yes_no_rejects_trailing_bytes_without_publishing_description() {
	std::vector<std::uint8_t> yes_no{MSG_SELECT_YESNO, 0};
	append_little_endian<std::uint64_t>(yes_no, 31);
	yes_no.push_back(0xff);
	const std::vector<std::uint8_t> stream = framed(yes_no);

	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::Malformed);
	assert(pending.description == 0);
	assert(pending.message
			== "是/否选择消息含有尾随字节，无法安全解析");
}

void test_select_position_exposes_only_core_candidates() {
	std::vector<std::uint8_t> select{MSG_SELECT_POSITION, 0};
	append_little_endian<std::uint32_t>(select, 89631139);
	select.push_back(
			POS_FACEUP_ATTACK | POS_FACEDOWN_ATTACK
			| POS_FACEUP_DEFENSE | POS_FACEDOWN_DEFENSE);
	const std::vector<std::uint8_t> stream = framed(select);

	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::SelectPosition);
	assert(pending.player == 0);
	assert(pending.selection_card_id == 89631139);
	assert(pending.position_options == std::vector<std::uint32_t>({
			POS_FACEUP_ATTACK,
			POS_FACEDOWN_ATTACK,
			POS_FACEUP_DEFENSE,
			POS_FACEDOWN_DEFENSE,
	}));
}

void test_select_position_rejects_invalid_or_malformed_frames() {
	const auto assert_malformed = [](std::vector<std::uint8_t> message) {
		const std::vector<std::uint8_t> stream = framed(message);
		const ygo::PendingAction pending =
				ygo::parse_pending_action(stream.data(), stream.size());
		assert(pending.kind == ygo::PendingActionKind::Malformed);
		assert(pending.position_options.empty());
		assert(pending.selection_card_id == 0);
	};

	std::vector<std::uint8_t> invalid_player{MSG_SELECT_POSITION, 2};
	append_little_endian<std::uint32_t>(invalid_player, 89631139);
	invalid_player.push_back(POS_FACEUP_ATTACK);
	assert_malformed(invalid_player);

	std::vector<std::uint8_t> empty_mask{MSG_SELECT_POSITION, 0};
	append_little_endian<std::uint32_t>(empty_mask, 89631139);
	empty_mask.push_back(0);
	assert_malformed(empty_mask);

	std::vector<std::uint8_t> invalid_mask{MSG_SELECT_POSITION, 0};
	append_little_endian<std::uint32_t>(invalid_mask, 89631139);
	invalid_mask.push_back(0x10);
	assert_malformed(invalid_mask);

	assert_malformed({MSG_SELECT_POSITION, 0, 1, 2, 3, 4});

	std::vector<std::uint8_t> trailing{MSG_SELECT_POSITION, 0};
	append_little_endian<std::uint32_t>(trailing, 89631139);
	trailing.insert(trailing.end(), {POS_FACEUP_ATTACK, 0xff});
	assert_malformed(trailing);
}

void test_select_card_exposes_single_card_candidates() {
	std::vector<std::uint8_t> select{MSG_SELECT_CARD, 0, 1};
	append_little_endian<std::uint32_t>(select, 1);
	append_little_endian<std::uint32_t>(select, 1);
	append_little_endian<std::uint32_t>(select, 2);
	append_card_option(select, 123, 1, LOCATION_MZONE, 0, POS_FACEUP_ATTACK);
	append_card_option(select, 456, 1, LOCATION_MZONE, 4, POS_FACEUP_DEFENSE);
	const std::vector<std::uint8_t> stream = framed(select);

	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::SelectCard);
	assert(pending.player == 0);
	assert(pending.cancelable);
	assert(pending.min_select == 1);
	assert(pending.max_select == 1);
	assert(pending.card_options.size() == 2);
	assert(pending.card_options[0].index == 0);
	assert(pending.card_options[0].card_id == 123);
	assert(pending.card_options[0].controller == 1);
	assert(pending.card_options[0].location == LOCATION_MZONE);
	assert(pending.card_options[0].sequence == 0);
	assert(pending.card_options[0].position == POS_FACEUP_ATTACK);
	assert(pending.card_options[1].index == 1);
	assert(pending.card_options[1].card_id == 456);
	assert(pending.card_options[1].controller == 1);
	assert(pending.card_options[1].location == LOCATION_MZONE);
	assert(pending.card_options[1].sequence == 4);
	assert(pending.card_options[1].position == POS_FACEUP_DEFENSE);
}

void test_select_card_rejects_invalid_protocol_fields_without_candidates() {
	const auto assert_malformed = [](std::vector<std::uint8_t> message) {
		const std::vector<std::uint8_t> stream = framed(message);
		const ygo::PendingAction pending =
				ygo::parse_pending_action(stream.data(), stream.size());
		assert(pending.kind == ygo::PendingActionKind::Malformed);
		assert(pending.card_options.empty());
		assert(!pending.message.empty());
	};

	std::vector<std::uint8_t> invalid_player{MSG_SELECT_CARD, 2, 0};
	append_little_endian<std::uint32_t>(invalid_player, 1);
	append_little_endian<std::uint32_t>(invalid_player, 1);
	append_little_endian<std::uint32_t>(invalid_player, 1);
	append_card_option(
			invalid_player, 123, 1, LOCATION_MZONE, 0, POS_FACEUP_ATTACK);
	assert_malformed(invalid_player);

	std::vector<std::uint8_t> invalid_cancelable{MSG_SELECT_CARD, 0, 2};
	append_little_endian<std::uint32_t>(invalid_cancelable, 1);
	append_little_endian<std::uint32_t>(invalid_cancelable, 1);
	append_little_endian<std::uint32_t>(invalid_cancelable, 1);
	append_card_option(
			invalid_cancelable, 123, 1, LOCATION_MZONE, 0, POS_FACEUP_ATTACK);
	assert_malformed(invalid_cancelable);

	std::vector<std::uint8_t> invalid_range{MSG_SELECT_CARD, 0, 0};
	append_little_endian<std::uint32_t>(invalid_range, 2);
	append_little_endian<std::uint32_t>(invalid_range, 1);
	append_little_endian<std::uint32_t>(invalid_range, 2);
	append_card_option(
			invalid_range, 123, 1, LOCATION_MZONE, 0, POS_FACEUP_ATTACK);
	append_card_option(
			invalid_range, 456, 1, LOCATION_MZONE, 1, POS_FACEUP_ATTACK);
	assert_malformed(invalid_range);

	std::vector<std::uint8_t> max_exceeds_count{MSG_SELECT_CARD, 0, 0};
	append_little_endian<std::uint32_t>(max_exceeds_count, 1);
	append_little_endian<std::uint32_t>(max_exceeds_count, 2);
	append_little_endian<std::uint32_t>(max_exceeds_count, 1);
	append_card_option(
			max_exceeds_count, 123, 1, LOCATION_MZONE, 0, POS_FACEUP_ATTACK);
	assert_malformed(max_exceeds_count);

	std::vector<std::uint8_t> truncated_option{MSG_SELECT_CARD, 0, 0};
	append_little_endian<std::uint32_t>(truncated_option, 1);
	append_little_endian<std::uint32_t>(truncated_option, 1);
	append_little_endian<std::uint32_t>(truncated_option, 2);
	append_card_option(
			truncated_option, 123, 1, LOCATION_MZONE, 0, POS_FACEUP_ATTACK);
	truncated_option.insert(truncated_option.end(), {0, 0, 0, 0, 1, LOCATION_MZONE});
	assert_malformed(truncated_option);
}

void test_select_card_rejects_impossible_candidate_count_before_allocation() {
	std::vector<std::uint8_t> select{MSG_SELECT_CARD, 0, 0};
	append_little_endian<std::uint32_t>(select, 0);
	append_little_endian<std::uint32_t>(select, 0);
	append_little_endian<std::uint32_t>(select, 0xffffffffU);
	const std::vector<std::uint8_t> stream = framed(select);

	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::Malformed);
	assert(pending.card_options.empty());
}

void test_select_card_rejects_invalid_second_candidate_controller() {
	std::vector<std::uint8_t> select{MSG_SELECT_CARD, 0, 0};
	append_little_endian<std::uint32_t>(select, 1);
	append_little_endian<std::uint32_t>(select, 1);
	append_little_endian<std::uint32_t>(select, 2);
	append_card_option(select, 123, 1, LOCATION_MZONE, 0, POS_FACEUP_ATTACK);
	append_card_option(select, 456, 2, LOCATION_MZONE, 1, POS_FACEUP_ATTACK);
	const std::vector<std::uint8_t> stream = framed(select);

	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::Malformed);
	assert(pending.card_options.empty());
}

void test_select_card_rejects_trailing_bytes_after_candidates() {
	std::vector<std::uint8_t> select{MSG_SELECT_CARD, 0, 0};
	append_little_endian<std::uint32_t>(select, 1);
	append_little_endian<std::uint32_t>(select, 1);
	append_little_endian<std::uint32_t>(select, 1);
	append_card_option(select, 123, 1, LOCATION_MZONE, 0, POS_FACEUP_ATTACK);
	select.push_back(0xff);
	const std::vector<std::uint8_t> stream = framed(select);

	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::Malformed);
	assert(pending.card_options.empty());
}

void test_empty_optional_chain_is_safe_to_auto_pass() {
	std::vector<std::uint8_t> stream;
	std::vector<std::uint8_t> chain{
			MSG_SELECT_CHAIN,
			0, // 决策玩家。
			0, // 特殊计数。
			0, // 非强制连锁。
	};
	append_little_endian<std::uint32_t>(chain, 0); // 当前玩家时点提示。
	append_little_endian<std::uint32_t>(chain, 0); // 对手时点提示。
	append_little_endian<std::uint32_t>(chain, 0); // 没有可发动连锁。
	append_frame(stream, chain);

	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::AutoPassChain);
	assert(pending.player == 0);
	assert(pending.message_type == MSG_SELECT_CHAIN);
}

void test_chain_exposes_each_effect_of_the_same_card_as_a_distinct_option() {
	std::vector<std::uint8_t> chain{MSG_SELECT_CHAIN, 1, 2, 0};
	append_little_endian<std::uint32_t>(chain, 0x01020304U);
	append_little_endian<std::uint32_t>(chain, 0x05060708U);
	append_little_endian<std::uint32_t>(chain, 2);
	append_chain_option(
			chain, 46986414, 1, LOCATION_MZONE, 3, POS_FACEUP_ATTACK,
			0x1122334455667788ULL, 4);
	append_chain_option(
			chain, 46986414, 1, LOCATION_MZONE, 3, POS_FACEUP_ATTACK,
			0x8877665544332211ULL, 9);

	const std::vector<std::uint8_t> stream = framed(chain);
	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());

	assert(pending.kind == ygo::PendingActionKind::SelectChain);
	assert(pending.player == 1);
	assert(!pending.chain_forced);
	assert(pending.chain_options.size() == 2);
	assert(pending.chain_options[0].index == 0);
	assert(pending.chain_options[0].card_id == 46986414);
	assert(pending.chain_options[0].sequence == 3);
	assert(pending.chain_options[0].description == 0x1122334455667788ULL);
	assert(pending.chain_options[0].client_mode == 4);
	assert(pending.chain_options[1].index == 1);
	assert(pending.chain_options[1].card_id == 46986414);
	assert(pending.chain_options[1].description == 0x8877665544332211ULL);
	assert(pending.chain_options[1].client_mode == 9);
}

void test_chain_rejects_truncated_candidate_without_publishing_options() {
	std::vector<std::uint8_t> chain{MSG_SELECT_CHAIN, 0, 0, 1};
	append_little_endian<std::uint32_t>(chain, 0);
	append_little_endian<std::uint32_t>(chain, 0);
	append_little_endian<std::uint32_t>(chain, 1);
	chain.insert(chain.end(), 22, 0);

	const std::vector<std::uint8_t> stream = framed(chain);
	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::Malformed);
	assert(pending.chain_options.empty());
}

void test_chain_rejects_trailing_bytes_after_candidates() {
	std::vector<std::uint8_t> chain{MSG_SELECT_CHAIN, 0, 0, 0};
	append_little_endian<std::uint32_t>(chain, 0);
	append_little_endian<std::uint32_t>(chain, 0);
	append_little_endian<std::uint32_t>(chain, 1);
	append_chain_option(
			chain, 1, 0, LOCATION_SZONE, 0, POS_FACEDOWN_DEFENSE, 2, 3);
	chain.push_back(0xff);

	const std::vector<std::uint8_t> stream = framed(chain);
	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::Malformed);
	assert(pending.chain_options.empty());
}

void test_chain_rejects_invalid_player_and_forced_flag() {
	std::vector<std::uint8_t> invalid_player{MSG_SELECT_CHAIN, 2, 0, 0};
	append_little_endian<std::uint32_t>(invalid_player, 0);
	append_little_endian<std::uint32_t>(invalid_player, 0);
	append_little_endian<std::uint32_t>(invalid_player, 0);
	const std::vector<std::uint8_t> invalid_player_stream = framed(invalid_player);
	assert(ygo::parse_pending_action(
				invalid_player_stream.data(), invalid_player_stream.size()).kind
			== ygo::PendingActionKind::Malformed);

	std::vector<std::uint8_t> invalid_forced{MSG_SELECT_CHAIN, 0, 0, 2};
	append_little_endian<std::uint32_t>(invalid_forced, 0);
	append_little_endian<std::uint32_t>(invalid_forced, 0);
	append_little_endian<std::uint32_t>(invalid_forced, 0);
	const std::vector<std::uint8_t> invalid_forced_stream = framed(invalid_forced);
	assert(ygo::parse_pending_action(
				invalid_forced_stream.data(), invalid_forced_stream.size()).kind
			== ygo::PendingActionKind::Malformed);
}

void test_forced_chain_without_candidates_is_malformed() {
	std::vector<std::uint8_t> chain{MSG_SELECT_CHAIN, 0, 0, 1};
	append_little_endian<std::uint32_t>(chain, 0);
	append_little_endian<std::uint32_t>(chain, 0);
	append_little_endian<std::uint32_t>(chain, 0);

	const std::vector<std::uint8_t> stream = framed(chain);
	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	// 强制窗口既不能跳过也没有可发动效果时不存在合法响应；必须在解析边界
	// 拒绝该矛盾帧，不能把不可恢复状态发布给会话或界面。
	assert(pending.kind == ygo::PendingActionKind::Malformed);
	assert(pending.chain_options.empty());
}

void test_all_idle_list_widths_are_consumed_before_flags() {
	std::vector<std::uint8_t> stream;
	std::vector<std::uint8_t> idle{MSG_SELECT_IDLECMD, 1};
	const std::size_t element_sizes[]{10, 10, 7, 10, 10, 19};
	for (const auto element_size : element_sizes) {
		append_little_endian<std::uint32_t>(idle, 1);
		idle.insert(idle.end(), element_size, 0xa5);
	}
	idle.push_back(0);
	idle.push_back(1);
	idle.push_back(0);
	append_frame(stream, idle);

	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::Idle);
	assert(pending.player == 1);
	assert(pending.can_end_turn);
}

void test_invalid_player_is_rejected_for_supported_messages() {
	std::vector<std::uint8_t> idle_stream;
	std::vector<std::uint8_t> idle{MSG_SELECT_IDLECMD, 255};
	for (int list_index = 0; list_index < 6; ++list_index) {
		append_little_endian<std::uint32_t>(idle, 0);
	}
	idle.insert(idle.end(), {0, 1, 0});
	append_frame(idle_stream, idle);
	assert(ygo::parse_pending_action(idle_stream.data(), idle_stream.size()).kind
			== ygo::PendingActionKind::Malformed);

	std::vector<std::uint8_t> chain_stream;
	std::vector<std::uint8_t> chain{MSG_SELECT_CHAIN, 255, 0, 0};
	append_little_endian<std::uint32_t>(chain, 0);
	append_little_endian<std::uint32_t>(chain, 0);
	append_little_endian<std::uint32_t>(chain, 0);
	append_frame(chain_stream, chain);
	assert(ygo::parse_pending_action(chain_stream.data(), chain_stream.size()).kind
			== ygo::PendingActionKind::Malformed);
}

void test_all_known_unimplemented_interactions_preserve_message_type() {
	const std::uint8_t types[]{
			MSG_ROCK_PAPER_SCISSORS,
			MSG_ANNOUNCE_RACE,
			MSG_ANNOUNCE_ATTRIB,
			MSG_ANNOUNCE_CARD,
			MSG_ANNOUNCE_NUMBER,
	};
	for (const auto type : types) {
		std::vector<std::uint8_t> stream;
		append_frame(stream, {type});
		const ygo::PendingAction pending =
				ygo::parse_pending_action(stream.data(), stream.size());
		assert(pending.kind == ygo::PendingActionKind::Unsupported);
		assert(pending.message_type == type);
	}
}

void test_retry_has_dedicated_diagnostic_kind() {
	std::vector<std::uint8_t> stream;
	append_frame(stream, {MSG_RETRY});
	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::Retry);
	assert(pending.message_type == MSG_RETRY);
}

void test_idle_message_exposes_all_six_action_lists() {
	std::vector<std::uint8_t> stream;
	std::vector<std::uint8_t> idle{MSG_SELECT_IDLECMD, 0};

	append_little_endian<std::uint32_t>(idle, 1);
	append_little_endian<std::uint32_t>(idle, 101);
	idle.push_back(0);
	idle.push_back(LOCATION_HAND);
	append_little_endian<std::uint32_t>(idle, 3);

	append_little_endian<std::uint32_t>(idle, 1);
	append_little_endian<std::uint32_t>(idle, 202);
	idle.push_back(0);
	idle.push_back(LOCATION_HAND);
	append_little_endian<std::uint32_t>(idle, 4);

	append_little_endian<std::uint32_t>(idle, 1);
	append_little_endian<std::uint32_t>(idle, 303);
	idle.push_back(0);
	idle.push_back(LOCATION_MZONE);
	idle.push_back(2);

	append_little_endian<std::uint32_t>(idle, 1);
	append_little_endian<std::uint32_t>(idle, 404);
	idle.push_back(0);
	idle.push_back(LOCATION_HAND);
	append_little_endian<std::uint32_t>(idle, 5);

	append_little_endian<std::uint32_t>(idle, 1);
	append_little_endian<std::uint32_t>(idle, 505);
	idle.push_back(0);
	idle.push_back(LOCATION_HAND);
	append_little_endian<std::uint32_t>(idle, 6);

	append_little_endian<std::uint32_t>(idle, 1);
	append_little_endian<std::uint32_t>(idle, 606);
	idle.push_back(0);
	idle.push_back(LOCATION_HAND);
	append_little_endian<std::uint32_t>(idle, 7);
	append_little_endian<std::uint64_t>(idle, 0x1122334455667788ULL);
	idle.push_back(9);

	idle.insert(idle.end(), {1, 1, 0});
	append_frame(stream, idle);

	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::Idle);
	assert(pending.idle_actions.size() == 6);
	assert(pending.idle_actions[0].kind == ygo::IdleActionKind::NormalSummon);
	assert(pending.idle_actions[0].card_id == 101);
	assert(pending.idle_actions[0].sequence == 3);
	assert(pending.idle_actions[1].kind == ygo::IdleActionKind::SpecialSummon);
	assert(pending.idle_actions[2].kind == ygo::IdleActionKind::Reposition);
	assert(pending.idle_actions[2].sequence == 2);
	assert(pending.idle_actions[3].kind == ygo::IdleActionKind::MonsterSet);
	assert(pending.idle_actions[4].kind == ygo::IdleActionKind::SpellTrapSet);
	assert(pending.idle_actions[5].kind == ygo::IdleActionKind::Activate);
	assert(pending.idle_actions[5].index == 0);
	assert(pending.idle_actions[5].card_id == 606);
	assert(pending.idle_actions[5].description == 0x1122334455667788ULL);
	assert(pending.idle_actions[5].client_mode == 9);
}

void assert_place_option(
		const ygo::PlaceOption &option,
		const std::uint8_t player,
		const std::uint8_t location,
		const std::uint8_t sequence) {
	assert(option.player == player);
	assert(option.location == location);
	assert(option.sequence == sequence);
}

void test_select_place_expands_all_zone_bits_for_both_players() {
	// forbidden 的低 16 位始终属于决策玩家，高 16 位属于另一方。刻意只
	// 放开每类区域的首尾位，确保怪兽区 0-6、魔陷区 0-7 的偏移没有错位。
	constexpr std::uint32_t allowed_bits =
			(1U << 0U) | (1U << 6U) | (1U << 8U) | (1U << 15U)
			| (1U << 16U) | (1U << 22U) | (1U << 24U) | (1U << 31U);
	std::vector<std::uint8_t> place{MSG_SELECT_PLACE, 0, 1};
	append_little_endian<std::uint32_t>(place, ~allowed_bits);
	const std::vector<std::uint8_t> stream = framed(place);

	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::SelectPlace);
	// 旧会话仅会自动提交 AutoSelectPlace；新协议决策必须保留给调用方，
	// 因而即使临时保留旧枚举值，也不能与 SelectPlace 使用同一数值。
	assert(pending.kind != ygo::PendingActionKind::AutoSelectPlace);
	assert(pending.player == 0);
	assert(pending.place_options.size() == 8);
	assert_place_option(pending.place_options[0], 0, LOCATION_MZONE, 0);
	assert_place_option(pending.place_options[1], 0, LOCATION_MZONE, 6);
	assert_place_option(pending.place_options[2], 0, LOCATION_SZONE, 0);
	assert_place_option(pending.place_options[3], 0, LOCATION_SZONE, 7);
	assert_place_option(pending.place_options[4], 1, LOCATION_MZONE, 0);
	assert_place_option(pending.place_options[5], 1, LOCATION_MZONE, 6);
	assert_place_option(pending.place_options[6], 1, LOCATION_SZONE, 0);
	assert_place_option(pending.place_options[7], 1, LOCATION_SZONE, 7);
}

void test_select_place_keeps_player_two_in_low_forbidden_bits() {
	// 同一位图在玩家2决策时，低 16 位仍属于玩家2，不能按绝对玩家编号解释。
	constexpr std::uint32_t allowed_bits = (1U << 3U) | (1U << 25U);
	std::vector<std::uint8_t> place{MSG_SELECT_PLACE, 1, 1};
	append_little_endian<std::uint32_t>(place, ~allowed_bits);
	const std::vector<std::uint8_t> stream = framed(place);

	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::SelectPlace);
	assert(pending.place_options.size() == 2);
	assert_place_option(pending.place_options[0], 1, LOCATION_MZONE, 3);
	assert_place_option(pending.place_options[1], 0, LOCATION_SZONE, 1);
}

void test_select_place_rejects_truncated_trailing_empty_and_multi_messages() {
	const std::vector<std::uint8_t> truncated_stream =
			framed({MSG_SELECT_PLACE, 0, 1});
	const ygo::PendingAction truncated = ygo::parse_pending_action(
			truncated_stream.data(), truncated_stream.size());
	assert(truncated.kind == ygo::PendingActionKind::Malformed);

	std::vector<std::uint8_t> trailing{MSG_SELECT_PLACE, 0, 1};
	append_little_endian<std::uint32_t>(trailing, 0xfffffffeU);
	trailing.push_back(0);
	const std::vector<std::uint8_t> trailing_stream = framed(trailing);
	const ygo::PendingAction trailing_pending = ygo::parse_pending_action(
			trailing_stream.data(), trailing_stream.size());
	assert(trailing_pending.kind == ygo::PendingActionKind::Malformed);

	std::vector<std::uint8_t> no_options{MSG_SELECT_PLACE, 0, 1};
	append_little_endian<std::uint32_t>(no_options, 0xffffffffU);
	const std::vector<std::uint8_t> no_options_stream = framed(no_options);
	const ygo::PendingAction no_options_pending = ygo::parse_pending_action(
			no_options_stream.data(), no_options_stream.size());
	assert(no_options_pending.kind == ygo::PendingActionKind::Malformed);

	std::vector<std::uint8_t> multi{MSG_SELECT_PLACE, 0, 2};
	append_little_endian<std::uint32_t>(multi, 0U);
	const std::vector<std::uint8_t> multi_stream = framed(multi);
	const ygo::PendingAction multi_pending = ygo::parse_pending_action(
			multi_stream.data(), multi_stream.size());
	assert(multi_pending.kind == ygo::PendingActionKind::Unsupported);
}

} // namespace

int main() {
	test_notification_before_idle_action_does_not_hide_pending_player();
	test_battle_message_exposes_attackers_and_phase_options();
	test_life_point_and_win_notifications_are_preserved();
	test_truncated_frame_is_reported_as_malformed();
	test_yes_no_message_exposes_player_and_description();
	test_yes_no_rejects_invalid_player_and_truncated_description();
	test_yes_no_rejects_trailing_bytes_without_publishing_description();
	test_select_position_exposes_only_core_candidates();
	test_select_position_rejects_invalid_or_malformed_frames();
	test_select_card_exposes_single_card_candidates();
	test_select_card_rejects_invalid_protocol_fields_without_candidates();
	test_select_card_rejects_impossible_candidate_count_before_allocation();
	test_select_card_rejects_invalid_second_candidate_controller();
	test_select_card_rejects_trailing_bytes_after_candidates();
	test_empty_optional_chain_is_safe_to_auto_pass();
	test_chain_exposes_each_effect_of_the_same_card_as_a_distinct_option();
	test_chain_rejects_truncated_candidate_without_publishing_options();
	test_chain_rejects_trailing_bytes_after_candidates();
	test_chain_rejects_invalid_player_and_forced_flag();
	test_forced_chain_without_candidates_is_malformed();
	test_all_idle_list_widths_are_consumed_before_flags();
	test_invalid_player_is_rejected_for_supported_messages();
	test_all_known_unimplemented_interactions_preserve_message_type();
	test_retry_has_dedicated_diagnostic_kind();
	test_idle_message_exposes_all_six_action_lists();
	test_select_place_expands_all_zone_bits_for_both_players();
	test_select_place_keeps_player_two_in_low_forbidden_bits();
	test_select_place_rejects_truncated_trailing_empty_and_multi_messages();
}
