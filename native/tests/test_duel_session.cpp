#include "test_support.hpp"
#include "ygo/card_database.hpp"
#include "ygo/card_repository.hpp"
#include "ygo/duel_message_parser.hpp"
#include "ygo/ocg_card_data_adapter.hpp"
#include "ygo/official_script_loader.hpp"

#define private public
#include "ygo/duel_session.hpp"
#undef private

#include "ocgapi.h"
#include "ocgapi_constants.h"

#include <array>
#include <algorithm>
#include <cassert>
#include <cstdlib>
#include <filesystem>
#include <map>
#include <memory>
#include <vector>

namespace {

std::shared_ptr<ygo::CardDatabase> create_database() {
	ygo::CardRecord record;
	record.display.cid = 4007;
	record.display.cn_name = "青眼白龙";
	record.rule.code = 89631139;
	record.rule.type = 17;
	record.rule.level = 8;
	record.rule.attack = 3000;
	record.rule.defense = 2500;

	std::map<std::uint32_t, ygo::CardRecord> records;
	records.emplace(record.rule.code, std::move(record));
	return ygo::CardDatabase::from_records(std::move(records), {});
}

void test_real_callbacks_create_and_destroy_duel() {
	ygo::test::TemporaryDirectory fixture;
	fixture.write_text("scripts/constant.lua", "");
	fixture.write_text("scripts/utility.lua", "");
	fixture.touch("scripts/official/.keep");

	auto scripts = std::make_shared<ygo::OfficialScriptLoader>(
			fixture.path("scripts"));
	ygo::DuelSession session(create_database(), scripts);
	assert(!session.is_active());

	const auto result = session.create(0x59474fULL);
	assert(result.ok);
	assert(result.message == "决斗创建成功");
	assert(session.is_active());

	const auto duplicate = session.create(0x59474fULL);
	assert(!duplicate.ok);
	assert(duplicate.message.find("已经存在") != std::string::npos);

	session.destroy();
	assert(!session.is_active());
	session.destroy();
	assert(!session.is_active());
}

void test_inactive_session_rejects_end_turn() {
	ygo::test::TemporaryDirectory fixture;
	fixture.write_text("scripts/constant.lua", "");
	fixture.write_text("scripts/utility.lua", "");

	auto scripts = std::make_shared<ygo::OfficialScriptLoader>(
			fixture.path("scripts"));
	ygo::DuelSession session(create_database(), scripts);

	const ygo::ProcessResult result = session.submit_end_turn();
	assert(!result.ok);
	assert(result.message == "决斗尚未创建");
	assert(!session.submit_enter_battle().ok);
	assert(!session.submit_enter_main2().ok);
	assert(!session.submit_end_battle().ok);
	assert(!session.submit_battle_action(ygo::BattleActionKind::Attack, 0).ok);
}

std::filesystem::path repository_root() {
	// __FILE__ 由 CMake 以仓库内源码路径编译；向上三级可稳定回到项目根目录，
	// 使 CTest 不依赖调用者的当前工作目录。
	return std::filesystem::path(__FILE__).parent_path().parent_path().parent_path();
}

void test_raw_compatibility_response_advances_pending_decision() {
	const std::filesystem::path root = repository_root();
	const auto loaded = ygo::CardDatabase::load_json_intersection(
			root / "data/cards.json",
			root / "images");
	assert(loaded.ok);
	auto scripts = std::make_shared<ygo::OfficialScriptLoader>(
			root / "third_party/CardScripts");
	const std::vector<std::uint32_t> deck(40, 89631139);

	ygo::DuelSession session(loaded.database, scripts);
	assert(session.create(0x524157ULL).ok);
	assert(session.add_deck_cards(0, deck, LOCATION_DECK).added == 40);
	assert(session.add_deck_cards(1, deck, LOCATION_DECK).added == 40);
	ygo::ProcessResult process = session.start();
	while (process.pending_action.kind == ygo::PendingActionKind::None) {
		process = session.step();
	}
	assert(process.pending_action.kind == ygo::PendingActionKind::Idle);
	assert(process.pending_action.player == 0);

	// legacy 入口接收完整 OCGCore 响应；写入响应后必须消费原决策快照，
	// 否则 step() 会把仍在 pending 的旧快照误判为重复推进并拒绝处理。
	const std::array<std::uint8_t, 4> end_turn_response{7, 0, 0, 0};
	session.set_response(end_turn_response.data(), end_turn_response.size());
	process = session.step();
	while (process.ok
			&& process.pending_action.kind == ygo::PendingActionKind::None
			&& process.status != OCG_DUEL_STATUS_END) {
		process = session.step();
	}
	assert(process.ok);
	assert(process.pending_action.kind == ygo::PendingActionKind::Idle);
	assert(process.pending_action.player == 1);
}

void test_real_direct_attack_is_accepted() {
	const std::filesystem::path root = repository_root();
	const auto loaded = ygo::CardDatabase::load_json_intersection(
			root / "data/cards.json",
			root / "images");
	assert(loaded.ok);
	const std::filesystem::path scripts_root = root / "third_party/CardScripts";
	auto scripts = std::make_shared<ygo::OfficialScriptLoader>(scripts_root);
	std::vector<std::uint32_t> deck;
	constexpr std::uint32_t excluded_types =
			TYPE_FUSION | TYPE_SYNCHRO | TYPE_XYZ | TYPE_LINK | TYPE_TOKEN;
	for (const auto &[id, record] : loaded.database->records()) {
		if ((record.rule.type & excluded_types) == 0
				&& (record.rule.type & TYPE_NORMAL) != 0
				&& std::filesystem::is_regular_file(
						scripts_root / "official" / ("c" + std::to_string(id) + ".lua"))) {
			deck.push_back(id);
		}
	}
	for (std::size_t index = 0; deck.size() < 40 && index < deck.size(); ++index) {
		deck.push_back(deck[index]);
	}
	assert(deck.size() == 40);

	ygo::DuelSession session(loaded.database, scripts);
	assert(session.create(0x424154544c45ULL).ok);
	assert(session.add_deck_cards(0, deck, LOCATION_DECK).added == 40);
	assert(session.add_deck_cards(1, deck, LOCATION_DECK).added == 40);
	auto advance = [&session](ygo::ProcessResult result) {
		for (int index = 0;
				index < 100
				&& result.pending_action.kind == ygo::PendingActionKind::None
				&& result.status != OCG_DUEL_STATUS_END;
				++index) {
			result = session.step();
		}
		return result;
	};

	ygo::ProcessResult process = advance(session.start());
	assert(process.pending_action.kind == ygo::PendingActionKind::Idle);
	process = advance(session.submit_end_turn());
	assert(process.pending_action.kind == ygo::PendingActionKind::Idle);
	assert(process.pending_action.player == 1);
	const auto summon = std::find_if(
			process.pending_action.idle_actions.begin(),
			process.pending_action.idle_actions.end(),
			[](const ygo::IdleAction &action) {
				return action.kind == ygo::IdleActionKind::NormalSummon;
			});
	assert(summon != process.pending_action.idle_actions.end());
	process = advance(session.submit_idle_action(summon->kind, summon->index));
	assert(process.pending_action.kind == ygo::PendingActionKind::Idle);
	process = advance(session.submit_enter_battle());
	assert(process.pending_action.kind == ygo::PendingActionKind::Battle);
	const auto attack = std::find_if(
			process.pending_action.battle_actions.begin(),
			process.pending_action.battle_actions.end(),
			[](const ygo::BattleAction &action) {
				return action.kind == ygo::BattleActionKind::Attack;
			});
	assert(attack != process.pending_action.battle_actions.end());
	assert(attack->direct_attackable);

	process = advance(session.submit_battle_action(attack->kind, attack->index));
	assert(process.ok);
	assert(process.pending_action.kind != ygo::PendingActionKind::Retry);
	assert(process.pending_action.kind != ygo::PendingActionKind::Malformed);
	assert(process.pending_action.kind != ygo::PendingActionKind::Unsupported);
	assert(session.life_points(0) < 8000);
	assert(session.life_points(1) == 8000);
	assert(session.winner() == -1);
}

void test_fixed_real_decks_advance_to_second_players_idle_action() {
	const std::filesystem::path root = repository_root();
	const auto loaded = ygo::CardDatabase::load_json_intersection(
			root / "data/cards.json",
			root / "images");
	assert(loaded.ok);

	const std::filesystem::path scripts_root = root / "third_party/CardScripts";
	auto scripts = std::make_shared<ygo::OfficialScriptLoader>(scripts_root);
	std::vector<std::uint32_t> deck;
	constexpr std::uint32_t extra_deck_or_token_types =
			TYPE_FUSION | TYPE_SYNCHRO | TYPE_XYZ | TYPE_LINK | TYPE_TOKEN;
	for (const auto &[id, record] : loaded.database->records()) {
		if ((record.rule.type & extra_deck_or_token_types) != 0
				|| (record.rule.type & TYPE_NORMAL) == 0) {
			continue;
		}
		if (std::filesystem::is_regular_file(
					scripts_root / "official" / ("c" + std::to_string(id) + ".lua"))) {
			deck.push_back(id);
		}
	}
	// 当前素材交集中只有 38 张带独立脚本的通常卡；重复前两张补足 40 张。
	// OCGCore 生命周期测试不应用禁限卡表，重复不会改变本测试关注的阶段流转。
	for (std::size_t index = 0; deck.size() < 40 && index < deck.size(); ++index) {
		deck.push_back(deck[index]);
	}
	assert(deck.size() == 40);

	ygo::DuelSession session(loaded.database, scripts);
	assert(session.create(0x59474fULL).ok);
	assert(session.add_deck_cards(0, deck, LOCATION_DECK).added == 40);
	assert(session.add_deck_cards(1, deck, LOCATION_DECK).added == 40);

	ygo::ProcessResult process = session.start();
	for (int step_index = 0;
			step_index < 100
			&& process.pending_action.kind == ygo::PendingActionKind::None
			&& process.status != OCG_DUEL_STATUS_END;
			++step_index) {
		process = session.step();
	}

	assert(session.query_count(0, LOCATION_DECK) == 35);
	assert(session.query_count(0, LOCATION_HAND) == 5);
	assert(session.query_count(1, LOCATION_DECK) == 35);
	assert(session.query_count(1, LOCATION_HAND) == 5);
	const std::vector<ygo::DuelCardSnapshot> opening_hand =
			session.query_cards(0, LOCATION_HAND);
	assert(opening_hand.size() == 5);
	assert(std::all_of(
			opening_hand.begin(),
			opening_hand.end(),
			[](const ygo::DuelCardSnapshot &card) {
				return card.card_id != 0 && card.location == LOCATION_HAND;
			}));
	assert(process.pending_action.kind == ygo::PendingActionKind::Idle);
	assert(process.pending_action.player == 0);
	assert(process.pending_action.can_end_turn);

	const ygo::PendingAction idle_snapshot = session.pending_action();
	const ygo::ProcessResult invalid_yes_no = session.submit_yes_no(true);
	assert(!invalid_yes_no.ok);
	assert(invalid_yes_no.message == "当前不是是非选择");
	assert(invalid_yes_no.pending_action.kind == idle_snapshot.kind);
	assert(invalid_yes_no.pending_action.player == idle_snapshot.player);
	assert(invalid_yes_no.pending_action.message_type == idle_snapshot.message_type);
	assert(invalid_yes_no.pending_action.idle_actions.size()
			== idle_snapshot.idle_actions.size());
	assert(session.pending_action().kind == idle_snapshot.kind);
	assert(session.pending_action().player == idle_snapshot.player);
	assert(session.pending_action().idle_actions.size()
			== idle_snapshot.idle_actions.size());

	const ygo::ProcessResult rejected_step = session.step();
	assert(!rejected_step.ok);
	assert(rejected_step.pending_action.kind == ygo::PendingActionKind::Idle);
	assert(rejected_step.pending_action.player == 0);
	assert(session.query_count(0, LOCATION_DECK) == 35);
	assert(session.query_count(0, LOCATION_HAND) == 5);

	const auto monster_set = std::find_if(
			process.pending_action.idle_actions.begin(),
			process.pending_action.idle_actions.end(),
			[](const ygo::IdleAction &action) {
				return action.kind == ygo::IdleActionKind::MonsterSet;
			});
	assert(monster_set != process.pending_action.idle_actions.end());
	const std::uint32_t selected_card_id = monster_set->card_id;

	const ygo::ProcessResult invalid_action =
			session.submit_idle_action(ygo::IdleActionKind::MonsterSet, 999);
	assert(!invalid_action.ok);
	assert(session.query_count(0, LOCATION_HAND) == 5);
	assert(session.query_count(0, LOCATION_MZONE) == 0);

	process = session.submit_idle_action(monster_set->kind, monster_set->index);
	for (int step_index = 0;
			step_index < 100
			&& process.pending_action.kind == ygo::PendingActionKind::None;
			++step_index) {
		process = session.step();
	}
	assert(process.ok);
	assert(session.query_count(0, LOCATION_HAND) == 4);
	assert(session.query_count(0, LOCATION_MZONE) == 1);
	const std::vector<ygo::DuelCardSnapshot> monster_zone =
			session.query_cards(0, LOCATION_MZONE);
	assert(monster_zone.size() == 1);
	assert(monster_zone.front().card_id == selected_card_id);
	assert(monster_zone.front().location == LOCATION_MZONE);
	assert(process.pending_action.kind == ygo::PendingActionKind::Idle);
	assert(selected_card_id != 0);

	// 先攻第一回合按规则不能进入战斗阶段，必须从空闲命令直接结束回合。
	assert(!process.pending_action.can_enter_battle);
	process = session.submit_end_turn();
	for (int step_index = 0;
			step_index < 100
			&& !(process.pending_action.kind == ygo::PendingActionKind::Idle
					&& process.pending_action.player == 1)
			&& process.status != OCG_DUEL_STATUS_END;
			++step_index) {
		assert(process.pending_action.kind != ygo::PendingActionKind::Unsupported);
		assert(process.pending_action.kind != ygo::PendingActionKind::Malformed);
		process = session.step();
	}
	assert(process.pending_action.kind == ygo::PendingActionKind::Idle);
	assert(process.pending_action.player == 1);
	assert(process.pending_action.can_end_turn);
	assert(process.pending_action.can_enter_battle);

	process = session.submit_enter_battle();
	for (int step_index = 0;
			step_index < 100
			&& process.pending_action.kind == ygo::PendingActionKind::None;
			++step_index) {
		process = session.step();
	}
	assert(process.pending_action.kind == ygo::PendingActionKind::Battle);
	assert(process.pending_action.player == 1);
	assert(process.pending_action.can_enter_main2);
	assert(process.pending_action.can_end_battle);
	const ygo::ProcessResult invalid_battle =
			session.submit_battle_action(ygo::BattleActionKind::Attack, 999);
	assert(!invalid_battle.ok);
	assert(invalid_battle.pending_action.kind == ygo::PendingActionKind::Battle);
	process = session.submit_enter_main2();
	for (int step_index = 0;
			step_index < 100
			&& process.pending_action.kind == ygo::PendingActionKind::None;
			++step_index) {
		process = session.step();
	}
	assert(process.pending_action.kind == ygo::PendingActionKind::Idle);
	assert(process.pending_action.player == 1);

	const std::array<int, 6> first_trace{
			MSG_SELECT_IDLECMD,
			0,
			process.pending_action.message_type,
			process.pending_action.player,
			static_cast<int>(session.query_count(1, LOCATION_DECK)),
			static_cast<int>(session.query_count(1, LOCATION_HAND)),
	};
	session.destroy();

	// 使用完全相同的牌组与种子重放一次，比较关键决策序列和最终区域计数，
	// 防止随机种子映射或消息推进顺序发生非确定性回归。
	ygo::DuelSession replay(loaded.database, scripts);
	assert(replay.create(0x59474fULL).ok);
	assert(replay.add_deck_cards(0, deck, LOCATION_DECK).added == 40);
	assert(replay.add_deck_cards(1, deck, LOCATION_DECK).added == 40);
	ygo::ProcessResult replay_process = replay.start();
	for (int step_index = 0;
			step_index < 100
			&& replay_process.pending_action.kind == ygo::PendingActionKind::None;
			++step_index) {
		replay_process = replay.step();
	}
	const int replay_first_message = replay_process.pending_action.message_type;
	const int replay_first_player = replay_process.pending_action.player;
	replay_process = replay.submit_end_turn();
	for (int step_index = 0;
			step_index < 100
			&& !(replay_process.pending_action.kind == ygo::PendingActionKind::Idle
					&& replay_process.pending_action.player == 1);
			++step_index) {
		replay_process = replay.step();
	}
	const std::array<int, 6> replay_trace{
			replay_first_message,
			replay_first_player,
			replay_process.pending_action.message_type,
			replay_process.pending_action.player,
			static_cast<int>(replay.query_count(1, LOCATION_DECK)),
			static_cast<int>(replay.query_count(1, LOCATION_HAND)),
	};
	assert(replay_trace == first_trace);

	// 先消耗本回合的一次通常召唤，使真实 OCGCore 的下一份 Idle 快照不再
	// 接受 type=0/index=0。随后仅注入待提交语义快照，并通过公共接口提交；
	// SelectCard 的 type=0 会被真实 Idle Processor 拒绝并产生 MSG_RETRY。
	const auto replay_summon = std::find_if(
			replay_process.pending_action.idle_actions.begin(),
			replay_process.pending_action.idle_actions.end(),
			[](const ygo::IdleAction &action) {
				return action.kind == ygo::IdleActionKind::NormalSummon;
			});
	assert(replay_summon != replay_process.pending_action.idle_actions.end());
	replay_process = replay.submit_idle_action(
			replay_summon->kind,
			replay_summon->index);
	assert(replay_process.ok);
	assert(!replay_process.response_rejected);
	for (int step_index = 0;
			step_index < 100
			&& replay_process.pending_action.kind == ygo::PendingActionKind::None;
			++step_index) {
		replay_process = replay.step();
	}
	assert(replay_process.pending_action.kind == ygo::PendingActionKind::Idle);

	ygo::PendingAction submitted;
	submitted.kind = ygo::PendingActionKind::SelectCard;
	submitted.player = 1;
	submitted.message_type = MSG_SELECT_CARD;
	submitted.message = "请选择攻击目标";
	submitted.cancelable = true;
	submitted.min_select = 1;
	submitted.max_select = 1;
	submitted.card_options = {
			{0, 100, 0, LOCATION_MZONE, 2, POS_FACEUP_ATTACK},
			{1, 200, 0, LOCATION_MZONE, 4, POS_FACEUP_DEFENSE},
	};
	replay.last_submitted_action_ = {};
	replay.pending_action_ = submitted;

	const ygo::ProcessResult retry = replay.submit_card_selection(0);
	assert(retry.response_rejected);
	assert(retry.pending_action.kind == ygo::PendingActionKind::SelectCard);
	assert(retry.pending_action.player == submitted.player);
	assert(retry.pending_action.message_type == submitted.message_type);
	assert(retry.pending_action.message == submitted.message);
	assert(retry.pending_action.cancelable == submitted.cancelable);
	assert(retry.pending_action.min_select == submitted.min_select);
	assert(retry.pending_action.max_select == submitted.max_select);
	assert(retry.pending_action.card_options.size() == 2);
	assert(retry.pending_action.card_options[0].index == 0);
	assert(retry.pending_action.card_options[0].card_id == 100);
	assert(retry.pending_action.card_options[0].sequence == 2);
	assert(retry.pending_action.card_options[1].index == 1);
	assert(retry.pending_action.card_options[1].card_id == 200);
	assert(retry.pending_action.card_options[1].sequence == 4);

	const ygo::ProcessResult stale =
			replay.submit_card_selection(99);
	assert(!stale.ok);
	assert(!stale.response_rejected);
	assert(stale.message == "卡牌候选不属于当前 OCGCore 候选列表");
	assert(stale.pending_action.kind == ygo::PendingActionKind::SelectCard);
	assert(stale.pending_action.card_options.size() == 2);
}

void test_full_local_assets_when_requested() {
	const char *asset_root = std::getenv("YGO_TEST_ASSET_ROOT");
	const char *script_root = std::getenv("YGO_TEST_SCRIPT_ROOT");
	if (asset_root == nullptr || script_root == nullptr) {
		return;
	}

	ygo::test::TemporaryDirectory cache;
	ygo::CardRepository repository;
	const auto initialized = repository.initialize({
		std::filesystem::path(asset_root) / "data/cards.json",
		std::filesystem::path(asset_root) / "images",
		cache.path("card_database.bin"),
	});
	assert(initialized.ok);

	auto scripts = std::make_shared<ygo::OfficialScriptLoader>(script_root);
	ygo::DuelSession session(initialized.database, scripts);
	const auto created = session.create(0x59474fULL);
	assert(created.ok);
	session.destroy();
}

} // namespace

int main() {
	const auto [major, minor] = ygo::DuelSession::core_version();
	assert(major >= 0);
	assert(minor >= 0);
	test_real_callbacks_create_and_destroy_duel();
	test_inactive_session_rejects_end_turn();
	test_raw_compatibility_response_advances_pending_decision();
	test_real_direct_attack_is_accepted();
	test_fixed_real_decks_advance_to_second_players_idle_action();
	test_full_local_assets_when_requested();
}
