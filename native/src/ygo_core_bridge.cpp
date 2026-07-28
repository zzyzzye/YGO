#include "ygo/ygo_core_bridge.hpp"
#include "ygo/pending_action_godot_adapter.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include "ocgapi.h"
#include "ocgapi_constants.h"

#include <filesystem>
#include <limits>
#include <utility>
#include <vector>

namespace ygo {

namespace {

godot::Dictionary card_to_dictionary(
		const CardDatabase &database,
		const DuelCardSnapshot &snapshot) {
	godot::Dictionary item;
	const CardRecord *card = database.find(snapshot.card_id);
	if (card == nullptr) {
		return item;
	}
	item["card_id"] = static_cast<std::int64_t>(snapshot.card_id);
	item["id"] = static_cast<std::int64_t>(card->rule.code);
	item["sequence"] = static_cast<std::int64_t>(snapshot.sequence);
	item["location"] = static_cast<std::int64_t>(snapshot.location);
	item["position"] = static_cast<std::int64_t>(snapshot.position);
	item["cn_name"] = godot::String::utf8(card->display.cn_name.c_str());
	item["types"] = godot::String::utf8(card->display.types_text.c_str());
	item["description"] = godot::String::utf8(card->display.description.c_str());
	item["image_path"] = godot::String::utf8(
			("res://" + card->display.image_relative_path).c_str());
	return item;
}

godot::Array cards_to_array(
		const CardDatabase &database,
		const std::vector<DuelCardSnapshot> &snapshots) {
	godot::Array cards;
	for (const DuelCardSnapshot &snapshot : snapshots) {
		const godot::Dictionary item = card_to_dictionary(database, snapshot);
		if (!item.is_empty()) {
			cards.push_back(item);
		}
	}
	return cards;
}

godot::Array hidden_cards_to_array(
		const std::vector<DuelCardSnapshot> &snapshots) {
	godot::Array cards;
	for (const DuelCardSnapshot &snapshot : snapshots) {
		godot::Dictionary item;
		// 对手场上卡只公开槽位和表示形式。即使 OCGCore 查询接口能返回
		// 内部卡号，桥接层也不能把里侧卡身份交给本地界面。
		item["sequence"] = static_cast<std::int64_t>(snapshot.sequence);
		item["location"] = static_cast<std::int64_t>(snapshot.location);
		item["position"] = static_cast<std::int64_t>(snapshot.position);
		cards.push_back(item);
	}
	return cards;
}

godot::Dictionary process_result_to_dictionary(const ProcessResult &result) {
	godot::Dictionary response;
	response["ok"] = result.ok;
	response["status"] = result.status;
	response["message"] = godot::String::utf8(result.message.c_str());
	response["pending_action"] = pending_action_to_dictionary(result.pending_action);
	response["response_rejected"] = result.response_rejected;
	return response;
}

ProcessResult advance_to_local_decision(DuelSession &session, ProcessResult result) {
	// 当前单机原型固定玩家1为本地玩家。玩家2暂用最保守的确定性策略：
	// 不发动、不召唤，遇到空闲阶段直接结束回合；若未来从其他流程进入战斗
	// 阶段则直接结束战斗阶段。该策略只调用已经校验的会话语义接口，绝不
	// 拼装原始响应，也不会替本地玩家跨过任何决策。
	constexpr int max_steps = 200;
	for (int step_index = 0;
			step_index < max_steps
			&& result.ok
			&& !result.response_rejected
			&& result.status != OCG_DUEL_STATUS_END;
			++step_index) {
		if (result.pending_action.kind == PendingActionKind::None) {
			result = session.step();
			continue;
		}
		if (result.pending_action.player != 1) {
			break;
		}
		if (result.pending_action.kind == PendingActionKind::Idle
				&& result.pending_action.can_end_turn) {
			result = session.submit_end_turn();
			continue;
		}
		if (result.pending_action.kind == PendingActionKind::Battle
				&& result.pending_action.can_end_battle) {
			result = session.submit_end_battle();
			continue;
		}
		break;
	}
	// 达到保险上限却仍没有可交互决策，说明规则消息链异常过长。
	// 明确向 Godot 报错，避免界面收到 ok=true 后停在无法操作的空状态。
	if (result.ok
			&& result.status != OCG_DUEL_STATUS_END
			&& result.pending_action.kind == PendingActionKind::None) {
		result.ok = false;
		result.message = "自动推进超过 200 步，仍未得到可操作决策";
	}
	return result;
}

} // namespace

YgoCoreBridge::YgoCoreBridge() {
}

godot::Dictionary YgoCoreBridge::initialize_card_database(
		const godot::String &project_root) {
	godot::Dictionary response;
	const godot::CharString root_utf8 = project_root.utf8();
	std::error_code error;
	// weakly_canonical 会消除 `..` 等路径歧义。后续所有资源路径均从这个
	// 已验证目录派生，防止调用方绕过项目边界或引入机器相关的固定路径。
	const auto root = std::filesystem::weakly_canonical(
			std::filesystem::path(root_utf8.get_data()), error);
	if (error || !std::filesystem::is_directory(root)) {
		response["ok"] = false;
		response["message"] = godot::String::utf8("项目根目录无效");
		return response;
	}

	// 允许 Godot 在开发期重复初始化；必须先结束 OCGCore 句柄，再释放回调借用的对象。
	if (session_ && session_->is_active()) {
		session_->destroy();
	}
	session_.reset();
	scripts_.reset();
	database_.reset();
	scripts_root_.clear();

	CardRepository repository;
	repository_status_ = repository.initialize({
		root / "data/cards.json",
		root / "images",
		root / ".cache/cards/card_database.bin",
	});
	if (!repository_status_.ok) {
		response["ok"] = false;
		response["message"] = godot::String::utf8(repository_status_.message.c_str());
		return response;
	}

	auto scripts = std::make_shared<OfficialScriptLoader>(
			root / "third_party/CardScripts");
	// 在创建决斗前验证基础脚本，使缺失依赖尽早成为中文初始化错误，
	// 而不是等 OCGCore 请求某张卡时才暴露成难以定位的回调失败。
	const auto script_validation = scripts->validate();
	if (!script_validation.ok) {
		response["ok"] = false;
		response["message"] = godot::String::utf8(script_validation.message.c_str());
		return response;
	}

	database_ = repository_status_.database;
	scripts_ = std::move(scripts);
	scripts_root_ = root / "third_party/CardScripts";
	session_ = std::make_unique<DuelSession>(database_, scripts_);

	godot::PackedStringArray warnings;
	for (const auto &warning : repository_status_.warnings) {
		warnings.push_back(godot::String::utf8(warning.c_str()));
	}
	response["ok"] = true;
	response["message"] = godot::String::utf8(repository_status_.message.c_str());
	response["cache_state"] = godot::String::utf8(
			repository_status_.cache_state == CacheState::Hit ? "缓存已命中" : "缓存已重建");
	response["card_count"] = static_cast<std::int64_t>(database_->size());
	response["invalid_records"] =
			static_cast<std::int64_t>(repository_status_.stats.invalid_records);
	response["missing_image_records"] =
			static_cast<std::int64_t>(repository_status_.stats.missing_image_records);
	response["warnings"] = warnings;
	return response;
}

std::int64_t YgoCoreBridge::get_card_count() const {
	return database_ ? static_cast<std::int64_t>(database_->size()) : 0;
}

godot::Dictionary YgoCoreBridge::get_card(std::int64_t id) const {
	godot::Dictionary response;
	// Godot 整数是有符号 64 位，卡片主键是无符号 32 位。先检查范围，
	// 避免窄化转换把负数或超大值意外变成另一张合法卡片的编号。
	if (!database_ || id < 0 || id > std::numeric_limits<std::uint32_t>::max()) {
		response["ok"] = false;
		response["message"] = godot::String::utf8(
				("未找到卡片：" + std::to_string(id)).c_str());
		return response;
	}
	const CardRecord *card = database_->find(static_cast<std::uint32_t>(id));
	if (card == nullptr) {
		response["ok"] = false;
		response["message"] = godot::String::utf8(
				("未找到卡片：" + std::to_string(id)).c_str());
		return response;
	}

	response["ok"] = true;
	response["id"] = static_cast<std::int64_t>(card->rule.code);
	response["cid"] = static_cast<std::int64_t>(card->display.cid);
	response["cn_name"] = godot::String::utf8(card->display.cn_name.c_str());
	response["types"] = godot::String::utf8(card->display.types_text.c_str());
	response["pendulum_description"] =
			godot::String::utf8(card->display.pendulum_description.c_str());
	response["description"] = godot::String::utf8(card->display.description.c_str());
	// 数据库只保存项目相对路径；桥接层补上 res:// 供 Godot 资源层直接使用，
	// 同时不向脚本泄漏宿主机的绝对路径。
	response["image_path"] = godot::String::utf8(
			("res://" + card->display.image_relative_path).c_str());
	return response;
}

godot::Dictionary YgoCoreBridge::get_cache_state() const {
	godot::Dictionary response;
	response["ok"] = repository_status_.ok;
	response["message"] = godot::String::utf8(repository_status_.message.c_str());
	if (repository_status_.ok) {
		response["state"] = godot::String::utf8(
				repository_status_.cache_state == CacheState::Hit ? "缓存已命中" : "缓存已重建");
	}
	return response;
}

godot::Dictionary YgoCoreBridge::get_core_version() const {
	const auto [major, minor] = DuelSession::core_version();
	godot::Dictionary version;
	version["major"] = major;
	version["minor"] = minor;
	return version;
}

godot::PackedInt64Array YgoCoreBridge::get_scripted_card_ids() const {
	godot::PackedInt64Array ids;
	if (!database_ || !scripts_) {
		return ids;
	}

	constexpr std::uint32_t excluded_types =
			TYPE_FUSION | TYPE_SYNCHRO | TYPE_XYZ | TYPE_LINK | TYPE_TOKEN;
	for (const auto &[id, record] : database_->records()) {
		// 当前诊断牌组只使用通常主卡组卡，避免尚未实现的效果选择打断
		// “开局—结束回合”闭环；复杂动作将在后续语义接口中逐类接入。
		if ((record.rule.type & excluded_types) != 0
				|| (record.rule.type & TYPE_NORMAL) == 0) {
			continue;
		}
		const auto script_path = scripts_root_ / "official" / ("c" + std::to_string(id) + ".lua");
		if (std::filesystem::is_regular_file(script_path)) {
			ids.push_back(static_cast<std::int64_t>(id));
		}
	}
	for (std::int64_t index = 0; ids.size() < 40 && index < ids.size(); ++index) {
		ids.push_back(ids[index]);
	}
	return ids;
}

godot::Dictionary YgoCoreBridge::create_duel(std::int64_t seed) {
	if (!session_) {
		godot::Dictionary response;
		response["ok"] = false;
		response["status"] = -1;
		response["message"] = godot::String("卡片数据库尚未初始化");
		return response;
	}
	const CreateResult result = session_->create(static_cast<std::uint64_t>(seed));
	godot::Dictionary response;
	response["ok"] = result.ok;
	response["status"] = result.status;
	response["message"] = godot::String(result.message.c_str());
	return response;
}

godot::Dictionary YgoCoreBridge::setup_duel(
		const godot::PackedInt64Array &player1_main,
		const godot::PackedInt64Array &player2_main,
		const std::int64_t seed) {
	godot::Dictionary response;
	if (!session_) {
		response["ok"] = false;
		response["message"] = godot::String("卡片数据库尚未初始化");
		response["status"] = -1;
		return response;
	}
	if (session_->is_active()) {
		session_->destroy();
	}

	const CreateResult create_result = session_->create(static_cast<std::uint64_t>(seed));
	if (!create_result.ok) {
		response["ok"] = false;
		response["status"] = create_result.status;
		response["message"] = godot::String(create_result.message.c_str());
		return response;
	}

	auto to_code_list = [](const godot::PackedInt64Array &source,
						  std::vector<std::uint32_t> &out) {
		std::size_t skipped = 0;
		for (const auto value : source) {
			if (value <= 0 || value > std::numeric_limits<std::uint32_t>::max()) {
				++skipped;
				continue;
			}
			out.push_back(static_cast<std::uint32_t>(value));
		}
		return skipped;
	};

	std::vector<std::uint32_t> deck1;
	std::vector<std::uint32_t> deck2;
	const auto skipped1 = to_code_list(player1_main, deck1);
	const auto skipped2 = to_code_list(player2_main, deck2);

	const auto deck1_result = session_->add_deck_cards(0, deck1, LOCATION_DECK);
	const auto deck2_result = session_->add_deck_cards(1, deck2, LOCATION_DECK);
	if (!deck1_result.ok || !deck2_result.ok) {
		session_->destroy();
		response["ok"] = false;
		response["status"] = -1;
		std::string message = "牌组下发失败：";
		if (!deck1_result.ok) {
			message += "玩家1未能写入有效卡片；";
		}
		if (!deck2_result.ok) {
			message += "玩家2未能写入有效卡片；";
		}
		response["message"] = godot::String(message.c_str());
		return response;
	}

	const ProcessResult started = advance_to_local_decision(*session_, session_->start());
	response["ok"] = true;
	response["status"] = started.status;
	response["message"] = godot::String("决斗设置并启动完成");
	response["pending_action"] = pending_action_to_dictionary(started.pending_action);
	response["player1_added"] = static_cast<std::int64_t>(deck1_result.added);
	response["player2_added"] = static_cast<std::int64_t>(deck2_result.added);
	response["player1_invalid"] = static_cast<std::int64_t>(skipped1);
	response["player2_invalid"] = static_cast<std::int64_t>(skipped2);
	return response;
}

godot::Dictionary YgoCoreBridge::start_duel() {
	godot::Dictionary response;
	if (!session_ || !session_->is_active()) {
		response["ok"] = false;
		response["message"] = godot::String("决斗尚未创建");
		response["status"] = OCG_DUEL_STATUS_END;
		return response;
	}

	return process_result_to_dictionary(
			advance_to_local_decision(*session_, session_->step()));
}

godot::Dictionary YgoCoreBridge::send_duel_response(
		const godot::PackedByteArray &response_data) {
	godot::Dictionary response;
	if (!session_ || !session_->is_active()) {
		response["ok"] = false;
		response["message"] = godot::String("决斗尚未创建");
		return response;
	}

	session_->set_response(response_data.ptr(), response_data.size());
	return process_result_to_dictionary(
			advance_to_local_decision(*session_, session_->step()));
}

godot::Dictionary YgoCoreBridge::get_pending_action() const {
	if (!session_ || !session_->is_active()) {
		return pending_action_to_dictionary({
				PendingActionKind::None,
				-1,
				false,
				-1,
				"当前无活动决斗",
		});
	}
	return pending_action_to_dictionary(session_->pending_action());
}

godot::Dictionary YgoCoreBridge::submit_end_turn() {
	if (!session_ || !session_->is_active()) {
		return process_result_to_dictionary({
				false,
				OCG_DUEL_STATUS_END,
				"决斗尚未创建",
				{},
		});
	}
	if (session_->winner() >= 0) {
		return process_result_to_dictionary({
				false, OCG_DUEL_STATUS_END, "决斗已经结束，不能继续提交动作",
				session_->pending_action()});
	}
	if (session_->pending_action().player != 0) {
		return process_result_to_dictionary({
				false,
				OCG_DUEL_STATUS_AWAITING,
				"当前不是本地玩家的操作回合",
				session_->pending_action(),
		});
	}
	const ProcessResult result = session_->submit_end_turn();
	if (!result.ok) {
		return process_result_to_dictionary(result);
	}
	return process_result_to_dictionary(
			advance_to_local_decision(*session_, result));
}

godot::Dictionary YgoCoreBridge::submit_enter_battle() {
	if (!session_ || !session_->is_active()) {
		return process_result_to_dictionary({false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}});
	}
	if (session_->winner() >= 0) {
		return process_result_to_dictionary({
				false, OCG_DUEL_STATUS_END, "决斗已经结束，不能继续提交动作",
				session_->pending_action()});
	}
	if (session_->pending_action().player != 0) {
		return process_result_to_dictionary({
				false, OCG_DUEL_STATUS_AWAITING, "当前不是本地玩家的操作回合",
				session_->pending_action()});
	}
	const ProcessResult result = session_->submit_enter_battle();
	return result.ok
			? process_result_to_dictionary(advance_to_local_decision(*session_, result))
			: process_result_to_dictionary(result);
}

godot::Dictionary YgoCoreBridge::submit_enter_main2() {
	if (!session_ || !session_->is_active()) {
		return process_result_to_dictionary({false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}});
	}
	if (session_->winner() >= 0) {
		return process_result_to_dictionary({
				false, OCG_DUEL_STATUS_END, "决斗已经结束，不能继续提交动作",
				session_->pending_action()});
	}
	if (session_->pending_action().player != 0) {
		return process_result_to_dictionary({
				false, OCG_DUEL_STATUS_AWAITING, "当前不是本地玩家的操作回合",
				session_->pending_action()});
	}
	const ProcessResult result = session_->submit_enter_main2();
	return result.ok
			? process_result_to_dictionary(advance_to_local_decision(*session_, result))
			: process_result_to_dictionary(result);
}

godot::Dictionary YgoCoreBridge::submit_end_battle() {
	if (!session_ || !session_->is_active()) {
		return process_result_to_dictionary({false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}});
	}
	if (session_->winner() >= 0) {
		return process_result_to_dictionary({
				false, OCG_DUEL_STATUS_END, "决斗已经结束，不能继续提交动作",
				session_->pending_action()});
	}
	if (session_->pending_action().player != 0) {
		return process_result_to_dictionary({
				false, OCG_DUEL_STATUS_AWAITING, "当前不是本地玩家的操作回合",
				session_->pending_action()});
	}
	const ProcessResult result = session_->submit_end_battle();
	return result.ok
			? process_result_to_dictionary(advance_to_local_decision(*session_, result))
			: process_result_to_dictionary(result);
}

godot::Dictionary YgoCoreBridge::submit_idle_action(
		const godot::String &action_kind,
		const std::int64_t index) {
	if (!session_ || !session_->is_active()) {
		return process_result_to_dictionary({
				false,
				OCG_DUEL_STATUS_END,
				"决斗尚未创建",
				{},
		});
	}
	if (session_->winner() >= 0) {
		return process_result_to_dictionary({
				false, OCG_DUEL_STATUS_END, "决斗已经结束，不能继续提交动作",
				session_->pending_action()});
	}
	if (index < 0) {
		return process_result_to_dictionary({
				false,
				OCG_DUEL_STATUS_AWAITING,
				"动作索引不能为负数",
				session_->pending_action(),
		});
	}
	if (session_->pending_action().player != 0) {
		return process_result_to_dictionary({
				false,
				OCG_DUEL_STATUS_AWAITING,
				"当前不是本地玩家的操作回合",
				session_->pending_action(),
		});
	}

	const godot::CharString utf8 = action_kind.utf8();
	const std::string kind_name = utf8.get_data();
	IdleActionKind kind;
	if (kind_name == "normal_summon") {
		kind = IdleActionKind::NormalSummon;
	} else if (kind_name == "special_summon") {
		kind = IdleActionKind::SpecialSummon;
	} else if (kind_name == "reposition") {
		kind = IdleActionKind::Reposition;
	} else if (kind_name == "monster_set") {
		kind = IdleActionKind::MonsterSet;
	} else if (kind_name == "spell_trap_set") {
		kind = IdleActionKind::SpellTrapSet;
	} else if (kind_name == "activate") {
		kind = IdleActionKind::Activate;
	} else {
		return process_result_to_dictionary({
				false,
				OCG_DUEL_STATUS_AWAITING,
				"未知的空闲阶段动作类型",
				session_->pending_action(),
		});
	}
	const ProcessResult result =
			session_->submit_idle_action(kind, static_cast<std::size_t>(index));
	if (!result.ok) {
		return process_result_to_dictionary(result);
	}
	return process_result_to_dictionary(
			advance_to_local_decision(*session_, result));
}

godot::Dictionary YgoCoreBridge::submit_battle_action(
		const godot::String &action_kind,
		const std::int64_t index) {
	if (!session_ || !session_->is_active()) {
		return process_result_to_dictionary({false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}});
	}
	if (session_->winner() >= 0) {
		return process_result_to_dictionary({
				false, OCG_DUEL_STATUS_END, "决斗已经结束，不能继续提交动作",
				session_->pending_action()});
	}
	if (index < 0 || session_->pending_action().player != 0) {
		return process_result_to_dictionary({
				false,
				OCG_DUEL_STATUS_AWAITING,
				index < 0 ? "战斗动作索引不能为负数" : "当前不是本地玩家的操作回合",
				session_->pending_action(),
		});
	}
	const std::string kind_name = action_kind.utf8().get_data();
	BattleActionKind kind;
	if (kind_name == "battle_activate") {
		kind = BattleActionKind::Activate;
	} else if (kind_name == "attack") {
		kind = BattleActionKind::Attack;
	} else {
		return process_result_to_dictionary({
				false,
				OCG_DUEL_STATUS_AWAITING,
				"未知的战斗阶段动作类型",
				session_->pending_action(),
		});
	}
	const ProcessResult result =
			session_->submit_battle_action(kind, static_cast<std::size_t>(index));
	return result.ok
			? process_result_to_dictionary(advance_to_local_decision(*session_, result))
			: process_result_to_dictionary(result);
}

godot::Dictionary YgoCoreBridge::submit_yes_no(const bool accepted) {
	if (!session_ || !session_->is_active()) {
		return process_result_to_dictionary({
				false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}});
	}
	if (session_->winner() >= 0) {
		return process_result_to_dictionary({
				false, OCG_DUEL_STATUS_END, "决斗已经结束，不能继续提交动作",
				session_->pending_action()});
	}
	if (session_->pending_action().player != 0) {
		return process_result_to_dictionary({
				false, OCG_DUEL_STATUS_AWAITING, "当前不是本地玩家的操作回合",
				session_->pending_action()});
	}
	const ProcessResult result = session_->submit_yes_no(accepted);
	return result.ok
			? process_result_to_dictionary(advance_to_local_decision(*session_, result))
			: process_result_to_dictionary(result);
}

godot::Dictionary YgoCoreBridge::submit_card_selection(
		const std::int64_t index) {
	// Godot int 为有符号 64 位，Session 候选索引为 size_t。必须先拒绝
	// 负数，避免 -1 窄化成极大的合法无符号值后绕过边界诊断。
	if (index < 0) {
		return process_result_to_dictionary({
				false,
				OCG_DUEL_STATUS_AWAITING,
				"卡牌候选索引不能为负数",
				session_ ? session_->pending_action() : PendingAction{},
		});
	}
	if (!session_ || !session_->is_active()) {
		return process_result_to_dictionary({
				false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}});
	}
	if (session_->winner() >= 0) {
		return process_result_to_dictionary({
				false, OCG_DUEL_STATUS_END, "决斗已经结束，不能继续提交动作",
				session_->pending_action()});
	}
	if (session_->pending_action().player != 0) {
		return process_result_to_dictionary({
				false, OCG_DUEL_STATUS_AWAITING, "当前不是本地玩家的操作回合",
				session_->pending_action()});
	}
	const ProcessResult result =
			session_->submit_card_selection(static_cast<std::size_t>(index));
	return result.ok
			? process_result_to_dictionary(advance_to_local_decision(*session_, result))
			: process_result_to_dictionary(result);
}

godot::Dictionary YgoCoreBridge::cancel_card_selection() {
	if (!session_ || !session_->is_active()) {
		return process_result_to_dictionary({
				false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}});
	}
	if (session_->winner() >= 0) {
		return process_result_to_dictionary({
				false, OCG_DUEL_STATUS_END, "决斗已经结束，不能继续提交动作",
				session_->pending_action()});
	}
	if (session_->pending_action().player != 0) {
		return process_result_to_dictionary({
				false, OCG_DUEL_STATUS_AWAITING, "当前不是本地玩家的操作回合",
				session_->pending_action()});
	}
	const ProcessResult result = session_->cancel_card_selection();
	return result.ok
			? process_result_to_dictionary(advance_to_local_decision(*session_, result))
			: process_result_to_dictionary(result);
}

godot::Dictionary YgoCoreBridge::get_duel_state() const {
	godot::Dictionary response;
	if (!session_ || !session_->is_active()) {
		response["ok"] = false;
		response["message"] = godot::String("当前无活动决斗");
		return response;
	}

	auto collect_state = [this](std::uint8_t team) {
		godot::Dictionary state;
		state["lp"] = static_cast<std::int64_t>(session_->life_points(team));
		state["deck"] = static_cast<std::int64_t>(
				session_->query_count(team, LOCATION_DECK));
		state["hand"] = static_cast<std::int64_t>(
				session_->query_count(team, LOCATION_HAND));
		state["monster_zone"] = static_cast<std::int64_t>(
				session_->query_count(team, LOCATION_MZONE));
		state["spell_trap_zone"] = static_cast<std::int64_t>(
				session_->query_count(team, LOCATION_SZONE));
		state["graveyard"] = static_cast<std::int64_t>(
				session_->query_count(team, LOCATION_GRAVE));
		state["banished"] = static_cast<std::int64_t>(
				session_->query_count(team, LOCATION_REMOVED));
		state["extra"] = static_cast<std::int64_t>(
				session_->query_count(team, LOCATION_EXTRA));
		// 手牌身份只交给其控制方使用；当前原型固定玩家1为本地玩家，因此
		// 桥接层仅导出玩家1手牌，避免今后接入双端时意外泄漏对手隐藏信息。
		if (team == 0) {
			state["hand_cards"] = cards_to_array(
					*database_,
					session_->query_cards(team, LOCATION_HAND));
		}
		const auto monsters = session_->query_cards(team, LOCATION_MZONE);
		const auto spells = session_->query_cards(team, LOCATION_SZONE);
		state["monster_cards"] = team == 0
				? cards_to_array(*database_, monsters)
				: hidden_cards_to_array(monsters);
		state["spell_trap_cards"] = team == 0
				? cards_to_array(*database_, spells)
				: hidden_cards_to_array(spells);
		return state;
	};

	godot::Dictionary players;
	players["p1"] = collect_state(0);
	players["p2"] = collect_state(1);
	response["ok"] = true;
	response["message"] = godot::String("决斗状态读取成功");
	response["players"] = players;
	response["game_over"] = session_->winner() >= 0;
	response["winner"] = session_->winner();
	response["win_reason"] = session_->win_reason();
	return response;
}

void YgoCoreBridge::destroy_duel() {
	if (session_) {
		session_->destroy();
	}
}

bool YgoCoreBridge::is_duel_active() const {
	return session_ && session_->is_active();
}

void YgoCoreBridge::_bind_methods() {
	godot::ClassDB::bind_method(
			godot::D_METHOD("initialize_card_database", "project_root"),
			&YgoCoreBridge::initialize_card_database);
	godot::ClassDB::bind_method(
			godot::D_METHOD("get_card_count"),
			&YgoCoreBridge::get_card_count);
	godot::ClassDB::bind_method(
			godot::D_METHOD("get_card", "id"),
			&YgoCoreBridge::get_card);
	godot::ClassDB::bind_method(
			godot::D_METHOD("get_cache_state"),
			&YgoCoreBridge::get_cache_state);
	godot::ClassDB::bind_method(godot::D_METHOD("get_core_version"), &YgoCoreBridge::get_core_version);
	godot::ClassDB::bind_method(
			godot::D_METHOD("get_scripted_card_ids"),
			&YgoCoreBridge::get_scripted_card_ids);
	godot::ClassDB::bind_method(godot::D_METHOD("create_duel", "seed"), &YgoCoreBridge::create_duel);
	godot::ClassDB::bind_method(
			godot::D_METHOD("setup_duel", "player1_main", "player2_main", "seed"),
			&YgoCoreBridge::setup_duel);
	godot::ClassDB::bind_method(godot::D_METHOD("start_duel"), &YgoCoreBridge::start_duel);
	godot::ClassDB::bind_method(
			godot::D_METHOD("send_duel_response", "response"),
			&YgoCoreBridge::send_duel_response);
	godot::ClassDB::bind_method(
			godot::D_METHOD("get_pending_action"),
			&YgoCoreBridge::get_pending_action);
	godot::ClassDB::bind_method(
			godot::D_METHOD("submit_end_turn"),
			&YgoCoreBridge::submit_end_turn);
	godot::ClassDB::bind_method(
			godot::D_METHOD("submit_enter_battle"),
			&YgoCoreBridge::submit_enter_battle);
	godot::ClassDB::bind_method(
			godot::D_METHOD("submit_enter_main2"),
			&YgoCoreBridge::submit_enter_main2);
	godot::ClassDB::bind_method(
			godot::D_METHOD("submit_end_battle"),
			&YgoCoreBridge::submit_end_battle);
	godot::ClassDB::bind_method(
			godot::D_METHOD("submit_idle_action", "action_kind", "index"),
			&YgoCoreBridge::submit_idle_action);
	godot::ClassDB::bind_method(
			godot::D_METHOD("submit_battle_action", "action_kind", "index"),
			&YgoCoreBridge::submit_battle_action);
	godot::ClassDB::bind_method(
			godot::D_METHOD("submit_yes_no", "accepted"),
			&YgoCoreBridge::submit_yes_no);
	godot::ClassDB::bind_method(
			godot::D_METHOD("submit_card_selection", "index"),
			&YgoCoreBridge::submit_card_selection);
	godot::ClassDB::bind_method(
			godot::D_METHOD("cancel_card_selection"),
			&YgoCoreBridge::cancel_card_selection);
	godot::ClassDB::bind_method(
			godot::D_METHOD("get_duel_state"),
			&YgoCoreBridge::get_duel_state);
	godot::ClassDB::bind_method(godot::D_METHOD("destroy_duel"), &YgoCoreBridge::destroy_duel);
	godot::ClassDB::bind_method(godot::D_METHOD("is_duel_active"), &YgoCoreBridge::is_duel_active);
}

} // namespace ygo
