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
	assert(!session.submit_position(POS_FACEUP_ATTACK).ok);
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

void test_automatic_chain_strategy_selects_local_stop_pass_or_first_option() {
	ygo::PendingAction local_chain;
	local_chain.kind = ygo::PendingActionKind::SelectChain;
	local_chain.player = 0;
	local_chain.chain_options = {
			{17, 100, 0, LOCATION_HAND, 1, POS_FACEUP_ATTACK, 11, 0},
			{42, 200, 0, LOCATION_SZONE, 3, POS_FACEDOWN_DEFENSE, 22, 1},
	};
	const ygo::AutomaticChainDecision local =
			ygo::decide_automatic_chain_action(local_chain);
	assert(local.kind == ygo::AutomaticChainDecisionKind::Stop);

	ygo::PendingAction opponent_optional = local_chain;
	opponent_optional.player = 1;
	opponent_optional.chain_forced = false;
	const ygo::AutomaticChainDecision optional =
			ygo::decide_automatic_chain_action(opponent_optional);
	assert(optional.kind == ygo::AutomaticChainDecisionKind::Pass);

	ygo::PendingAction opponent_forced = opponent_optional;
	opponent_forced.chain_forced = true;
	const ygo::AutomaticChainDecision forced =
			ygo::decide_automatic_chain_action(opponent_forced);
	assert(forced.kind == ygo::AutomaticChainDecisionKind::Submit);
	// 索引故意不是 0，且与第二候选不同；这能捕获硬编码 0 或误选第二项。
	assert(forced.option_index == 17);
}

void test_chain_submission_validates_snapshot_and_recovers_after_retry() {
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
		if ((record.rule.type & excluded_types) != 0
				|| (record.rule.type & TYPE_NORMAL) == 0
				|| !std::filesystem::is_regular_file(
						scripts_root / "official" / ("c" + std::to_string(id) + ".lua"))) {
			continue;
		}
		deck.push_back(id);
	}
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
			&& process.pending_action.kind == ygo::PendingActionKind::None;
			++step_index) {
		process = session.step();
	}
	assert(process.pending_action.kind == ygo::PendingActionKind::Idle);
	const auto monster_set = std::find_if(
			process.pending_action.idle_actions.begin(),
			process.pending_action.idle_actions.end(),
			[](const ygo::IdleAction &action) {
				return action.kind == ygo::IdleActionKind::MonsterSet;
			});
	assert(monster_set != process.pending_action.idle_actions.end());
	process = session.submit_idle_action(monster_set->kind, monster_set->index);
	for (int step_index = 0;
			step_index < 100
			&& process.pending_action.kind == ygo::PendingActionKind::None;
			++step_index) {
		process = session.step();
	}
	assert(process.pending_action.kind == ygo::PendingActionKind::Idle);

	// 将已消耗通常召唤的真实 Idle Processor 与连锁快照错配。它会拒绝
	// int32(0) 并发出 MSG_RETRY，从而验证 Session 保存并恢复完整连锁上下文。
	ygo::PendingAction chain;
	chain.kind = ygo::PendingActionKind::SelectChain;
	chain.player = 0;
	chain.message_type = MSG_SELECT_CHAIN;
	chain.message = "请选择发动连锁效果";
	chain.chain_options = {
			{0, 100, 0, LOCATION_HAND, 1, POS_FACEUP_ATTACK, 11, 0},
			{1, 200, 0, LOCATION_SZONE, 3, POS_FACEDOWN_DEFENSE, 22, 1},
	};
	session.pending_action_ = chain;

	const ygo::ProcessResult invalid = session.submit_chain(99);
	assert(!invalid.ok);
	assert(!invalid.response_rejected);
	assert(invalid.message == "连锁候选不属于当前 OCGCore 候选列表");
	assert(invalid.pending_action.chain_options.size() == 2);
	assert(session.pending_action().kind == ygo::PendingActionKind::SelectChain);

	chain.chain_forced = true;
	session.pending_action_ = chain;
	const ygo::ProcessResult forced_pass = session.pass_chain();
	assert(!forced_pass.ok);
	assert(!forced_pass.response_rejected);
	assert(forced_pass.message == "强制连锁必须发动一个候选效果");
	assert(forced_pass.pending_action.chain_forced);
	assert(session.pending_action().kind == ygo::PendingActionKind::SelectChain);

	chain.chain_forced = false;
	session.pending_action_ = chain;
	const ygo::ProcessResult retry = session.submit_chain(0);
	assert(retry.ok);
	assert(retry.response_rejected);
	assert(retry.pending_action.kind == ygo::PendingActionKind::SelectChain);
	assert(retry.pending_action.player == chain.player);
	assert(retry.pending_action.message_type == chain.message_type);
	assert(retry.pending_action.message == chain.message);
	assert(!retry.pending_action.chain_forced);
	assert(retry.pending_action.chain_options.size() == 2);
	assert(retry.pending_action.chain_options[0].index == 0);
	assert(retry.pending_action.chain_options[0].card_id == 100);
	assert(retry.pending_action.chain_options[0].location == LOCATION_HAND);
	assert(retry.pending_action.chain_options[0].description == 11);
	assert(retry.pending_action.chain_options[1].index == 1);
	assert(retry.pending_action.chain_options[1].card_id == 200);
	assert(retry.pending_action.chain_options[1].location == LOCATION_SZONE);
	assert(retry.pending_action.chain_options[1].description == 22);

	// Bridge 的确定性对手策略只会走这两个语义分支：可选窗口跳过，强制
	// 窗口提交候选表第一项。两次均应被真实 Idle Processor 拒绝并完整恢复，
	// 证明策略不会借由原始字节绕开 Session 的重试上下文。
	const ygo::ProcessResult optional_pass_retry = session.pass_chain();
	assert(optional_pass_retry.ok);
	assert(optional_pass_retry.response_rejected);
	assert(optional_pass_retry.pending_action.kind
			== ygo::PendingActionKind::SelectChain);
	assert(!optional_pass_retry.pending_action.chain_forced);
	assert(optional_pass_retry.pending_action.chain_options.size() == 2);

	chain.chain_forced = true;
	session.pending_action_ = chain;
	const ygo::ProcessResult forced_first_retry =
			session.submit_chain(chain.chain_options.front().index);
	assert(forced_first_retry.ok);
	assert(forced_first_retry.response_rejected);
	assert(forced_first_retry.pending_action.kind
			== ygo::PendingActionKind::SelectChain);
	assert(forced_first_retry.pending_action.chain_forced);
	assert(forced_first_retry.pending_action.chain_options.front().index == 0);

	// 本地玩家的连锁窗口必须原样交还界面。若自动推进错误地把 player=0
	// 当作对手，本断言会因响应被消费或 MSG_RETRY 恢复而失败。
	ygo::PendingAction local_chain = chain;
	local_chain.player = 0;
	local_chain.chain_forced = false;
	session.pending_action_ = local_chain;
	const ygo::ProcessResult local_stopped = ygo::advance_to_local_decision(
			session,
			{true, OCG_DUEL_STATUS_AWAITING, "等待玩家决策输入", local_chain});
	assert(local_stopped.ok);
	assert(!local_stopped.response_rejected);
	assert(local_stopped.pending_action.kind == ygo::PendingActionKind::SelectChain);
	assert(local_stopped.pending_action.player == 0);
	assert(!local_stopped.pending_action.chain_forced);
	assert(session.pending_action().kind == ygo::PendingActionKind::SelectChain);
	assert(session.pending_action().player == 0);

	// 自动对手的可选窗口必须走 pass_chain；真实 Idle Processor 会拒绝该
	// SelectChain 字节并返回 MSG_RETRY，因此 response_rejected 证明循环
	// 的确调用了生产 Session 语义接口，而非只返回输入快照。
	ygo::PendingAction opponent_optional = chain;
	opponent_optional.player = 1;
	opponent_optional.chain_forced = false;
	session.pending_action_ = opponent_optional;
	const ygo::ProcessResult optional_advanced = ygo::advance_to_local_decision(
			session,
			{true,
			 OCG_DUEL_STATUS_AWAITING,
			 "等待玩家决策输入",
			 opponent_optional});
	assert(optional_advanced.ok);
	assert(optional_advanced.response_rejected);
	assert(optional_advanced.pending_action.kind
			== ygo::PendingActionKind::SelectChain);
	assert(optional_advanced.pending_action.player == 1);
	assert(!optional_advanced.pending_action.chain_forced);

	// 强制窗口则必须提交候选表中的首个稳定索引；若分支反转为跳过，
	// Session 会在写入前拒绝并返回 ok=false，不能满足此处的 Retry 断言。
	ygo::PendingAction opponent_forced = opponent_optional;
	opponent_forced.chain_forced = true;
	session.pending_action_ = opponent_forced;
	const ygo::ProcessResult forced_advanced = ygo::advance_to_local_decision(
			session,
			{true,
			 OCG_DUEL_STATUS_AWAITING,
			 "等待玩家决策输入",
			 opponent_forced});
	assert(forced_advanced.ok);
	assert(forced_advanced.response_rejected);
	assert(forced_advanced.pending_action.kind
			== ygo::PendingActionKind::SelectChain);
	assert(forced_advanced.pending_action.player == 1);
	assert(forced_advanced.pending_action.chain_forced);
	assert(forced_advanced.pending_action.chain_options.front().index == 0);
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

	// 电子龙在己方无怪兽、对手有怪兽时提供手牌特殊召唤；其脚本允许表侧
	// 攻击或表侧守备，因此能确定性让真实 OCGCore 发出 MSG_SELECT_POSITION，
	// 不依赖人工注入 PendingAction。
	{
		constexpr std::uint32_t cyber_dragon = 70095154;
		assert(loaded.database->find(cyber_dragon) != nullptr);
		std::vector<std::uint32_t> cyber_deck(40, cyber_dragon);
		ygo::DuelSession position_session(loaded.database, scripts);
		assert(position_session.create(0x59474fULL).ok);
		assert(position_session.add_deck_cards(0, deck, LOCATION_DECK).added == 40);
		assert(position_session.add_deck_cards(
				1, cyber_deck, LOCATION_DECK).added == 40);
		ygo::ProcessResult position_process = position_session.start();
		for (int step_index = 0;
				step_index < 100
				&& position_process.pending_action.kind
						== ygo::PendingActionKind::None;
				++step_index) {
			position_process = position_session.step();
		}
		assert(position_process.pending_action.kind == ygo::PendingActionKind::Idle);
		const auto first_monster = std::find_if(
				position_process.pending_action.idle_actions.begin(),
				position_process.pending_action.idle_actions.end(),
				[](const ygo::IdleAction &action) {
					return action.kind == ygo::IdleActionKind::NormalSummon;
				});
		assert(first_monster != position_process.pending_action.idle_actions.end());
		position_process = position_session.submit_idle_action(
				first_monster->kind, first_monster->index);
		for (int step_index = 0;
				step_index < 100
				&& position_process.pending_action.kind
						== ygo::PendingActionKind::None;
				++step_index) {
			position_process = position_session.step();
		}
		assert(position_session.query_count(0, LOCATION_MZONE) == 1);
		position_process = position_session.submit_end_turn();
		for (int step_index = 0;
				step_index < 100
				&& !(position_process.pending_action.kind
							== ygo::PendingActionKind::Idle
						&& position_process.pending_action.player == 1);
				++step_index) {
			position_process = position_session.step();
		}
		const auto special_summon = std::find_if(
				position_process.pending_action.idle_actions.begin(),
				position_process.pending_action.idle_actions.end(),
				[](const ygo::IdleAction &action) {
					return action.kind == ygo::IdleActionKind::SpecialSummon;
				});
		assert(special_summon != position_process.pending_action.idle_actions.end());
		position_process = position_session.submit_idle_action(
				special_summon->kind, special_summon->index);
		for (int step_index = 0;
				step_index < 100
				&& position_process.pending_action.kind
						== ygo::PendingActionKind::None;
				++step_index) {
			position_process = position_session.step();
		}
		assert(position_process.pending_action.kind
				== ygo::PendingActionKind::SelectPosition);
		assert(position_process.pending_action.selection_card_id == cyber_dragon);
		assert(position_process.pending_action.position_options
				== std::vector<std::uint32_t>({
					POS_FACEUP_ATTACK,
					POS_FACEUP_DEFENSE,
				}));
		position_process =
				position_session.submit_position(POS_FACEUP_DEFENSE);
		for (int step_index = 0;
				step_index < 100
				&& position_process.pending_action.kind
						== ygo::PendingActionKind::None;
				++step_index) {
			position_process = position_session.step();
		}
		assert(position_process.ok);
		// 后手玩家回合开始先抽到第六张手牌，特殊召唤后应回到五张。
		assert(position_session.query_count(1, LOCATION_HAND) == 5);
		const auto summoned = position_session.query_cards(1, LOCATION_MZONE);
		assert(summoned.size() == 1);
		assert(summoned.front().card_id == cyber_dragon);
		assert(summoned.front().position == POS_FACEUP_DEFENSE);
	}

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
	// 使用真实 OCGCore 的通常召唤候选进入 MSG_SELECT_POSITION。Session 只
	// 提交 C++ 已解析的离散候选，卡牌必须在核心接受后才从手牌进入怪兽区。
	const auto normal_summon = std::find_if(
			replay_process.pending_action.idle_actions.begin(),
			replay_process.pending_action.idle_actions.end(),
			[](const ygo::IdleAction &action) {
				return action.kind == ygo::IdleActionKind::NormalSummon;
			});
	assert(normal_summon != replay_process.pending_action.idle_actions.end());
	const std::uint32_t summoned_card_id = normal_summon->card_id;
	replay_process = replay.submit_idle_action(
			normal_summon->kind,
			normal_summon->index);
	for (int step_index = 0;
			step_index < 100
			&& replay_process.pending_action.kind == ygo::PendingActionKind::None;
			++step_index) {
		replay_process = replay.step();
	}
	assert(replay_process.ok);
	// 当前通常怪兽只能表侧攻击召唤，OCGCore 会直接采用唯一位置而不询问；
	// 若将来卡池规则返回多候选，则同一真实流程必须消费 SelectPosition。
	if (replay_process.pending_action.kind
			== ygo::PendingActionKind::SelectPosition) {
		assert(replay_process.pending_action.selection_card_id == summoned_card_id);
		assert(!replay_process.pending_action.position_options.empty());
		const std::uint32_t summon_position =
				replay_process.pending_action.position_options.front();
		replay_process = replay.submit_position(summon_position);
		for (int step_index = 0;
				step_index < 100
				&& replay_process.pending_action.kind == ygo::PendingActionKind::None;
				++step_index) {
			replay_process = replay.step();
		}
	}
	assert(replay_process.ok);
	assert(replay.query_count(0, LOCATION_HAND) == 4);
	assert(replay.query_count(0, LOCATION_MZONE) == 1);
	assert(replay.query_cards(0, LOCATION_MZONE).front().card_id
			== summoned_card_id);
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

	// 同样把一个 SelectPosition 快照提交给仍等待 Idle 的真实 Processor，
	// 验证 MSG_RETRY 会完整恢复卡号与离散候选，而不是只恢复 kind。
	ygo::PendingAction submitted_position;
	submitted_position.kind = ygo::PendingActionKind::SelectPosition;
	submitted_position.player = 0;
	submitted_position.message_type = MSG_SELECT_POSITION;
	submitted_position.message = "请选择表示形式";
	submitted_position.selection_card_id = 89631139;
	submitted_position.position_options = {
		POS_FACEUP_ATTACK,
		POS_FACEDOWN_DEFENSE,
	};
	replay.last_submitted_action_ = {};
	replay.pending_action_ = submitted_position;
	const ygo::ProcessResult position_retry =
			replay.submit_position(POS_FACEUP_ATTACK);
	assert(position_retry.response_rejected);
	assert(position_retry.pending_action.kind
			== ygo::PendingActionKind::SelectPosition);
	assert(position_retry.pending_action.selection_card_id == 89631139);
	assert(position_retry.pending_action.position_options
			== submitted_position.position_options);

	const ygo::ProcessResult invalid_position =
			replay.submit_position(POS_FACEUP_DEFENSE);
	assert(!invalid_position.ok);
	assert(!invalid_position.response_rejected);
	assert(invalid_position.message
			== "表示形式不属于当前 OCGCore 候选列表");
	assert(invalid_position.pending_action.position_options
			== submitted_position.position_options);
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
	test_automatic_chain_strategy_selects_local_stop_pass_or_first_option();
	test_chain_submission_validates_snapshot_and_recovers_after_retry();
	test_real_direct_attack_is_accepted();
	test_fixed_real_decks_advance_to_second_players_idle_action();
	test_full_local_assets_when_requested();
}
