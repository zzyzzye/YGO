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
	assert(pending.can_end_turn);
	assert(pending.message_type == MSG_SELECT_IDLECMD);
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

void test_unimplemented_interactive_message_is_not_silently_ignored() {
	std::vector<std::uint8_t> stream;
	// MSG_SELECT_YESNO 需要玩家响应，但不属于当前里程碑支持的动作。
	append_frame(stream, {MSG_SELECT_YESNO, 0, 0, 0, 0, 0, 0, 0, 0, 0});

	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::Unsupported);
	assert(pending.message_type == MSG_SELECT_YESNO);
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

void test_select_place_exposes_first_available_own_monster_zone() {
	std::vector<std::uint8_t> stream;
	std::vector<std::uint8_t> place{MSG_SELECT_PLACE, 0, 1};
	// bit=1 表示不可选：己方怪兽区 0、1 被占用，其余区域全部屏蔽。
	append_little_endian<std::uint32_t>(place, 0xffffff03U);
	append_frame(stream, place);

	const ygo::PendingAction pending =
			ygo::parse_pending_action(stream.data(), stream.size());
	assert(pending.kind == ygo::PendingActionKind::AutoSelectPlace);
	assert(pending.player == 0);
	assert(pending.place_options.size() == 5);
	assert(pending.place_options[0].player == 0);
	assert(pending.place_options[0].location == LOCATION_MZONE);
	assert(pending.place_options[0].sequence == 2);

	std::vector<std::uint8_t> player_two_stream;
	std::vector<std::uint8_t> player_two_place{MSG_SELECT_PLACE, 1, 1};
	append_little_endian<std::uint32_t>(player_two_place, 0xfffffffeU);
	append_frame(player_two_stream, player_two_place);
	const ygo::PendingAction player_two_pending =
			ygo::parse_pending_action(
					player_two_stream.data(),
					player_two_stream.size());
	assert(player_two_pending.kind == ygo::PendingActionKind::AutoSelectPlace);
	// forbidden 的低 16 位永远描述当前选择者；即使玩家2选择，也必须优先
	// 返回玩家2自己的 0 号怪兽区，不能误把对手区域当成首选项。
	assert(player_two_pending.place_options[0].player == 1);
	assert(player_two_pending.place_options[0].location == LOCATION_MZONE);
	assert(player_two_pending.place_options[0].sequence == 0);
}

} // namespace

int main() {
	test_notification_before_idle_action_does_not_hide_pending_player();
	test_truncated_frame_is_reported_as_malformed();
	test_unimplemented_interactive_message_is_not_silently_ignored();
	test_empty_optional_chain_is_safe_to_auto_pass();
	test_all_idle_list_widths_are_consumed_before_flags();
	test_invalid_player_is_rejected_for_supported_messages();
	test_all_known_unimplemented_interactions_preserve_message_type();
	test_retry_has_dedicated_diagnostic_kind();
	test_idle_message_exposes_all_six_action_lists();
	test_select_place_exposes_first_available_own_monster_zone();
}
