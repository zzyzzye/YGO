#include "ygo/duel_response.hpp"
#include "ocgapi_constants.h"

#include <cassert>
#include <cstdint>
#include <limits>
#include <vector>

namespace {

void test_yes_no_response_rejects_wrong_action_kind() {
	ygo::PendingAction pending;
	pending.kind = ygo::PendingActionKind::Idle;

	const ygo::DuelResponse response =
			ygo::build_yes_no_response(pending, true);

	assert(!response.ok);
	assert(response.message == "当前不是是非选择");
	assert(response.bytes.empty());
}

void test_yes_no_response_encodes_boolean_as_little_endian_int32() {
	ygo::PendingAction pending;
	pending.kind = ygo::PendingActionKind::YesNo;

	const ygo::DuelResponse accepted =
			ygo::build_yes_no_response(pending, true);
	const ygo::DuelResponse declined =
			ygo::build_yes_no_response(pending, false);

	assert(accepted.ok);
	assert(accepted.bytes == std::vector<std::uint8_t>({1, 0, 0, 0}));
	assert(declined.ok);
	assert(declined.bytes == std::vector<std::uint8_t>({0, 0, 0, 0}));
}

void test_position_response_requires_current_discrete_candidate() {
	ygo::PendingAction pending;
	pending.kind = ygo::PendingActionKind::YesNo;
	const ygo::DuelResponse wrong_kind =
			ygo::build_position_response(pending, POS_FACEUP_ATTACK);
	assert(!wrong_kind.ok);
	assert(wrong_kind.message == "当前不是表示形式选择");
	assert(wrong_kind.bytes.empty());

	pending.kind = ygo::PendingActionKind::SelectPosition;
	pending.position_options = {POS_FACEUP_ATTACK, POS_FACEDOWN_DEFENSE};
	const ygo::DuelResponse combination = ygo::build_position_response(
			pending, POS_FACEUP_ATTACK | POS_FACEDOWN_DEFENSE);
	assert(!combination.ok);
	assert(combination.message == "表示形式不属于当前 OCGCore 候选列表");

	const ygo::DuelResponse unknown =
			ygo::build_position_response(pending, POS_FACEUP_DEFENSE);
	assert(!unknown.ok);
	assert(unknown.bytes.empty());
}

void test_position_response_encodes_little_endian_int32() {
	ygo::PendingAction pending;
	pending.kind = ygo::PendingActionKind::SelectPosition;
	pending.position_options = {POS_FACEDOWN_DEFENSE};

	const ygo::DuelResponse response =
			ygo::build_position_response(pending, POS_FACEDOWN_DEFENSE);
	assert(response.ok);
	assert(response.bytes == std::vector<std::uint8_t>({8, 0, 0, 0}));
}

void test_card_selection_response_rejects_wrong_kind_and_unknown_candidate() {
	ygo::PendingAction pending;
	pending.kind = ygo::PendingActionKind::YesNo;

	const ygo::DuelResponse wrong_kind =
			ygo::build_card_selection_response(pending, 0);
	assert(!wrong_kind.ok);
	assert(wrong_kind.message == "当前不是卡牌选择");
	assert(wrong_kind.bytes.empty());

	pending.kind = ygo::PendingActionKind::SelectCard;
	pending.min_select = 1;
	pending.max_select = 1;
	pending.card_options.push_back(ygo::CardSelectionOption{3});
	const ygo::DuelResponse unknown =
			ygo::build_card_selection_response(pending, 2);
	assert(!unknown.ok);
	assert(unknown.message == "卡牌候选不属于当前 OCGCore 候选列表");
	assert(unknown.bytes.empty());
}

void test_card_selection_response_rejects_index_outside_uint32_protocol() {
	if (std::numeric_limits<std::size_t>::max()
			<= std::numeric_limits<std::uint32_t>::max()) {
		return;
	}
	ygo::PendingAction pending;
	pending.kind = ygo::PendingActionKind::SelectCard;
	pending.min_select = 1;
	pending.max_select = 1;
	const std::size_t oversized =
			static_cast<std::size_t>(std::numeric_limits<std::uint32_t>::max()) + 1U;
	pending.card_options.push_back(ygo::CardSelectionOption{oversized});

	const ygo::DuelResponse response =
			ygo::build_card_selection_response(pending, oversized);

	assert(!response.ok);
	assert(response.message == "卡牌候选索引超出 OCGCore 协议范围");
	assert(response.bytes.empty());
}

void test_card_selection_response_rejects_non_single_selection_constraints() {
	ygo::PendingAction pending;
	pending.kind = ygo::PendingActionKind::SelectCard;
	pending.min_select = 1;
	pending.max_select = 2;
	pending.card_options.push_back(ygo::CardSelectionOption{0});

	const ygo::DuelResponse response =
			ygo::build_card_selection_response(pending, 0);

	assert(!response.ok);
	assert(response.message == "当前原型只支持选择一张卡牌");
	assert(response.bytes.empty());
}

void test_card_selection_response_encodes_one_uint32_candidate() {
	ygo::PendingAction pending;
	pending.kind = ygo::PendingActionKind::SelectCard;
	pending.min_select = 1;
	pending.max_select = 1;
	pending.card_options.push_back(ygo::CardSelectionOption{0x01020304U});

	const ygo::DuelResponse response =
			ygo::build_card_selection_response(pending, 0x01020304U);

	assert(response.ok);
	assert(response.bytes == std::vector<std::uint8_t>({
			0, 0, 0, 0,
			1, 0, 0, 0,
			4, 3, 2, 1,
	}));
}

void test_card_selection_cancel_requires_cancelable_select_card() {
	ygo::PendingAction pending;
	pending.kind = ygo::PendingActionKind::YesNo;
	pending.cancelable = true;

	const ygo::DuelResponse wrong_kind =
			ygo::build_card_selection_cancel_response(pending);
	assert(!wrong_kind.ok);
	assert(wrong_kind.message == "当前不是卡牌选择");
	assert(wrong_kind.bytes.empty());

	pending.kind = ygo::PendingActionKind::SelectCard;
	pending.min_select = 1;
	pending.max_select = 2;
	const ygo::DuelResponse unsupported =
			ygo::build_card_selection_cancel_response(pending);
	assert(!unsupported.ok);
	assert(unsupported.message == "当前原型只支持选择一张卡牌");
	assert(unsupported.bytes.empty());

	pending.max_select = 1;
	pending.cancelable = false;
	const ygo::DuelResponse forbidden =
			ygo::build_card_selection_cancel_response(pending);
	assert(!forbidden.ok);
	assert(forbidden.message == "当前卡牌选择不可取消");
	assert(forbidden.bytes.empty());
}

void test_card_selection_cancel_encodes_negative_one_as_little_endian_int32() {
	ygo::PendingAction pending;
	pending.kind = ygo::PendingActionKind::SelectCard;
	pending.min_select = 1;
	pending.max_select = 1;
	pending.cancelable = true;

	const ygo::DuelResponse response =
			ygo::build_card_selection_cancel_response(pending);

	assert(response.ok);
	assert(response.bytes == std::vector<std::uint8_t>({
			0xff, 0xff, 0xff, 0xff,
	}));
}

} // namespace

int main() {
	test_yes_no_response_rejects_wrong_action_kind();
	test_yes_no_response_encodes_boolean_as_little_endian_int32();
	test_position_response_requires_current_discrete_candidate();
	test_position_response_encodes_little_endian_int32();
	test_card_selection_response_rejects_wrong_kind_and_unknown_candidate();
	test_card_selection_response_rejects_index_outside_uint32_protocol();
	test_card_selection_response_rejects_non_single_selection_constraints();
	test_card_selection_response_encodes_one_uint32_candidate();
	test_card_selection_cancel_requires_cancelable_select_card();
	test_card_selection_cancel_encodes_negative_one_as_little_endian_int32();
}
