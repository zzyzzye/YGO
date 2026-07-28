#include "ygo/duel_session.hpp"
#include "ygo/duel_response.hpp"

#include "ocgapi.h"
#include "ocgapi_constants.h"

#include <algorithm>
#include <limits>

namespace {

void read_card(void *payload, std::uint32_t code, OCG_CardData *data) {
	static_cast<ygo::OcgCardDataAdapter *>(payload)->read(code, data);
}

void finish_reading_card(void *payload, OCG_CardData *data) {
	static_cast<ygo::OcgCardDataAdapter *>(payload)->done(data);
}

int read_script(void *payload, OCG_Duel duel, const char *name) {
	if (name == nullptr) {
		return 0;
	}
	return static_cast<ygo::OfficialScriptLoader *>(payload)
			->load_requested(duel, name);
}

void discard_log(void *, const char *, int) {
}

std::uint64_t next_seed(std::uint64_t &state) {
	state += 0x9e3779b97f4a7c15ULL;
	std::uint64_t value = state;
	value = (value ^ (value >> 30U)) * 0xbf58476d1ce4e5b9ULL;
	value = (value ^ (value >> 27U)) * 0x94d049bb133111ebULL;
	return value ^ (value >> 31U);
}

const char *creation_message(int status) {
	switch (status) {
	case OCG_DUEL_CREATION_SUCCESS:
		return "决斗创建成功";
	case OCG_DUEL_CREATION_NO_OUTPUT:
		return "OCGCore 未返回决斗实例";
	case OCG_DUEL_CREATION_NOT_CREATED:
		return "OCGCore 无法创建决斗";
	case OCG_DUEL_CREATION_NULL_DATA_READER:
		return "缺少卡片数据读取器";
	case OCG_DUEL_CREATION_NULL_SCRIPT_READER:
		return "缺少 Lua 脚本读取器";
	case OCG_DUEL_CREATION_INCOMPATIBLE_LUA_API:
		return "OCGCore 使用的 Lua API 不兼容";
	case OCG_DUEL_CREATION_NULL_RNG_SEED:
		return "缺少 OCGCore 随机数种子";
	default:
		return "未知的 OCGCore 决斗创建状态";
	}
}

} // namespace

namespace ygo {

DuelSession::DuelSession(
		std::shared_ptr<const CardDatabase> database,
		std::shared_ptr<OfficialScriptLoader> scripts) :
		database_(std::move(database)),
		scripts_(std::move(scripts)),
		card_data_adapter_(database_) {
}

DuelSession::~DuelSession() {
	destroy();
}

std::pair<int, int> DuelSession::core_version() {
	int major = 0;
	int minor = 0;
	OCG_GetVersion(&major, &minor);
	return {major, minor};
}

CreateResult DuelSession::create(std::uint64_t seed) {
	if (is_active()) {
		return {false, OCG_DUEL_CREATION_NOT_CREATED, "决斗实例已经存在"};
	}
	if (!database_) {
		return {false, OCG_DUEL_CREATION_NOT_CREATED, "卡片数据库尚未初始化"};
	}
	if (!scripts_) {
		return {false, OCG_DUEL_CREATION_NOT_CREATED, "Lua 脚本加载器尚未初始化"};
	}

	OCG_DuelOptions options{};
	options.team1.startingLP = 8000;
	options.team1.startingDrawCount = 5;
	options.team1.drawCountPerTurn = 1;
	options.team2.startingLP = 8000;
	options.team2.startingDrawCount = 5;
	options.team2.drawCountPerTurn = 1;
	for (auto &value : options.seed) {
		value = next_seed(seed);
	}
	options.cardReader = read_card;
	options.payload1 = &card_data_adapter_;
	options.scriptReader = read_script;
	options.payload2 = scripts_.get();
	options.logHandler = discard_log;
	options.cardReaderDone = finish_reading_card;
	options.payload4 = &card_data_adapter_;

	OCG_Duel duel = nullptr;
	const int status = OCG_CreateDuel(&duel, &options);
	if (status != OCG_DUEL_CREATION_SUCCESS || duel == nullptr) {
		return {false, status, creation_message(status)};
	}

	duel_ = duel;
	life_points_ = {8000, 8000};
	winner_ = -1;
	win_reason_ = -1;
	const auto bootstrap = scripts_->load_bootstrap(duel);
	if (!bootstrap.ok) {
		destroy();
		return {false, OCG_DUEL_CREATION_NOT_CREATED, bootstrap.message};
	}
	return {true, status, creation_message(status)};
}

AddDeckResult DuelSession::add_deck_cards(
		const std::uint8_t team,
		const std::vector<std::uint32_t> &codes,
		const std::uint32_t location,
		const std::uint8_t duelist) const {
	if (!is_active()) {
		return {false, 0, "决斗尚未创建"};
	}
	if (team > 1) {
		return {false, 0, "队伍编号只能是 0 或 1"};
	}
	if (location != LOCATION_DECK && location != LOCATION_EXTRA) {
		return {false, 0, "当前仅支持主卡组和额外卡组下发"};
	}

	std::size_t added = 0;
	for (const auto code : codes) {
		if (database_->find(code) == nullptr) {
			continue;
		}
		const OCG_NewCardInfo info{
				team,
				duelist,
				code,
				team,
				location,
				static_cast<std::uint32_t>(added),
				0,
		};
		// OCGCore 规定 duelist=0 写入当前出战玩家的真实区域，此时 con 决定
		// 控制方；大于 0 才按 team 写入换人决斗备用列表。普通双方对局必须
		// 使用默认值 0 且 con=team，否则卡会进入错误玩家或区域查询为零。
		OCG_DuelNewCard(static_cast<OCG_Duel>(duel_), &info);
		++added;
	}
	return {added > 0, added, "下发卡片完成：请求 " + std::to_string(codes.size())
												  + " 张，实际加入 "
												  + std::to_string(added) + " 张"};
}

ProcessResult DuelSession::start() {
	if (!is_active()) {
		return {false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}};
	}
	OCG_StartDuel(static_cast<OCG_Duel>(duel_));
	return process_once();
}

ProcessResult DuelSession::step() {
	if (!is_active()) {
		return {false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}};
	}
	if (pending_action_.kind != PendingActionKind::None) {
		return {
				false,
				OCG_DUEL_STATUS_AWAITING,
				"当前正在等待玩家决策，不能直接推进规则引擎",
				pending_action_,
		};
	}
	return process_once();
}

ProcessResult DuelSession::process_once() {
	int status = OCG_DUEL_STATUS_CONTINUE;
	bool response_rejected = false;
	constexpr int max_auto_pass_count = 32;
	for (int pass_index = 0; pass_index < max_auto_pass_count; ++pass_index) {
		status = OCG_DuelProcess(static_cast<OCG_Duel>(duel_));
		std::uint32_t message_size = 0;
		const auto *message_data = static_cast<const std::uint8_t *>(
				OCG_DuelGetMessage(static_cast<OCG_Duel>(duel_), &message_size));
		pending_action_ = parse_pending_action(message_data, message_size);
		for (const LifePointEvent &event : pending_action_.life_point_events) {
			if (event.player >= life_points_.size()) {
				continue;
			}
			const std::int64_t current = life_points_[event.player];
			std::int64_t next = static_cast<std::int64_t>(event.amount);
			if (event.kind == LifePointEventKind::Damage) {
				next = current - static_cast<std::int64_t>(event.amount);
			} else if (event.kind == LifePointEventKind::Recover) {
				next = current + static_cast<std::int64_t>(event.amount);
			}
			life_points_[event.player] = static_cast<std::int32_t>(
					std::clamp<std::int64_t>(
							next,
							0,
							std::numeric_limits<std::int32_t>::max()));
		}
		if (pending_action_.winner >= 0) {
			winner_ = pending_action_.winner;
			win_reason_ = pending_action_.win_reason;
		}
		if (pending_action_.kind == PendingActionKind::AutoSelectPlace
				&& !allow_auto_select_place_) {
			pending_action_ = {
					PendingActionKind::Unsupported,
					pending_action_.player,
					false,
					MSG_SELECT_PLACE,
					"当前区域选择不属于召唤或盖放后续步骤，需要玩家明确选择",
			};
		}
		if (pending_action_.kind == PendingActionKind::Retry
				&& last_submitted_action_.kind != PendingActionKind::None) {
			// MSG_RETRY 本身不重复携带原决策字段。必须恢复提交前的完整
			// 不可变快照，尤其是 SelectCard 候选与取消约束；否则界面既
			// 无法重新展示合法选择，也可能用过期索引绕过语义门禁。
			pending_action_ = last_submitted_action_;
			response_rejected = true;
		} else if (pending_action_.kind != PendingActionKind::None
				&& pending_action_.kind != PendingActionKind::AutoPassChain) {
			last_submitted_action_ = {};
		}
		if (pending_action_.kind != PendingActionKind::AutoPassChain
				&& pending_action_.kind != PendingActionKind::AutoSelectPlace) {
			break;
		}

		if (pending_action_.kind == PendingActionKind::AutoPassChain) {
			// 非强制且无候选项的连锁窗口没有用户可做的选择。按上游
			// SelectChain 协议提交 int32(-1)，避免把协议维护步骤暴露给界面。
			const std::uint8_t pass_response[4]{0xff, 0xff, 0xff, 0xff};
			OCG_DuelSetResponse(
					static_cast<OCG_Duel>(duel_),
					pass_response,
					sizeof(pass_response));
		} else {
			// 首版功能场确定性使用第一个合法区域。候选列表仍保留在解析模型中，
			// 后续可直接改为由前端高亮并提交具体区域，而无需重新解释位掩码。
			const PlaceOption &place = pending_action_.place_options.front();
			const std::uint8_t place_response[3]{
					place.player,
					place.location,
					place.sequence,
			};
			OCG_DuelSetResponse(
					static_cast<OCG_Duel>(duel_),
					place_response,
					sizeof(place_response));
			allow_auto_select_place_ = false;
		}
		pending_action_ = {};
	}
	if (pending_action_.kind == PendingActionKind::AutoPassChain
			|| pending_action_.kind == PendingActionKind::AutoSelectPlace) {
		pending_action_ = {
				PendingActionKind::Malformed,
				-1,
				false,
				MSG_SELECT_CHAIN,
				"自动跳过空连锁次数超过安全上限",
		};
	}

	std::string message;
	switch (status) {
	case OCG_DUEL_STATUS_END:
		message = "对局已结束";
		break;
	case OCG_DUEL_STATUS_AWAITING:
		message = "等待玩家决策输入";
		break;
	case OCG_DUEL_STATUS_CONTINUE:
		message = "规则引擎可继续推进";
		break;
	default:
		message = "OCGCore 返回未知处理状态";
		break;
	}
	if (status == OCG_DUEL_STATUS_AWAITING
			&& pending_action_.kind == PendingActionKind::None) {
		pending_action_ = {
				PendingActionKind::Malformed,
				-1,
				false,
				-1,
				"OCGCore 等待输入，但本轮消息中没有可识别的玩家决策",
		};
	}
	return {true, status, std::move(message), pending_action_, response_rejected};
}

void DuelSession::set_response(const void *response_data, std::size_t response_size) {
	if (!is_active()) {
		return;
	}
	// legacy 原始响应入口仍必须遵守会话状态机：响应对应当前 pending 快照，
	// 写入 OCGCore 后将该快照保存为重试上下文并清空当前决策，step() 才能
	// 消费响应。否则引擎已收到字节而会话仍认为用户尚未作答，兼容入口永远
	// 无法推进。原始入口不授权后续区域自动选择，避免跨过另一个玩家决策。
	last_submitted_action_ = pending_action_;
	pending_action_ = {};
	allow_auto_select_place_ = false;
	OCG_DuelSetResponse(
			static_cast<OCG_Duel>(duel_),
			response_data,
			static_cast<std::uint32_t>(response_size));
}

ProcessResult DuelSession::submit_end_turn() {
	if (!is_active()) {
		return {false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}};
	}
	if (pending_action_.kind != PendingActionKind::Idle
			|| !pending_action_.can_end_turn) {
		return {false, OCG_DUEL_STATUS_AWAITING, "当前不是可结束回合的空闲阶段", pending_action_};
	}

	// SelectIdleCmd 返回协议是一个小端 int32：低 16 位 type=7 表示进入 EP，
	// 高 16 位索引在此动作中固定为 0。
	const std::uint8_t response[4]{7, 0, 0, 0};
	last_submitted_action_ = pending_action_;
	allow_auto_select_place_ = false;
	OCG_DuelSetResponse(static_cast<OCG_Duel>(duel_), response, sizeof(response));
	pending_action_ = {};
	return process_once();
}

ProcessResult DuelSession::submit_enter_battle() {
	if (!is_active()) {
		return {false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}};
	}
	if (pending_action_.kind != PendingActionKind::Idle
			|| !pending_action_.can_enter_battle) {
		return {false, OCG_DUEL_STATUS_AWAITING, "当前不能进入战斗阶段", pending_action_};
	}
	const std::uint8_t response[4]{6, 0, 0, 0};
	last_submitted_action_ = pending_action_;
	allow_auto_select_place_ = false;
	OCG_DuelSetResponse(static_cast<OCG_Duel>(duel_), response, sizeof(response));
	pending_action_ = {};
	return process_once();
}

ProcessResult DuelSession::submit_idle_action(
		const IdleActionKind kind,
		const std::size_t index) {
	if (!is_active()) {
		return {false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}};
	}
	if (pending_action_.kind != PendingActionKind::Idle) {
		return {false, OCG_DUEL_STATUS_AWAITING, "当前不是空闲阶段动作选择", pending_action_};
	}
	const auto candidate = std::find_if(
			pending_action_.idle_actions.begin(),
			pending_action_.idle_actions.end(),
			[kind, index](const IdleAction &action) {
				return action.kind == kind && action.index == index;
			});
	if (candidate == pending_action_.idle_actions.end()) {
		return {false, OCG_DUEL_STATUS_AWAITING, "动作不属于当前 OCGCore 候选列表", pending_action_};
	}
	if (index > 0xffffU) {
		return {false, OCG_DUEL_STATUS_AWAITING, "动作索引超出 OCGCore 协议范围", pending_action_};
	}

	std::uint32_t action_type = 0;
	switch (kind) {
	case IdleActionKind::NormalSummon:
		action_type = 0;
		break;
	case IdleActionKind::SpecialSummon:
		action_type = 1;
		break;
	case IdleActionKind::Reposition:
		action_type = 2;
		break;
	case IdleActionKind::MonsterSet:
		action_type = 3;
		break;
	case IdleActionKind::SpellTrapSet:
		action_type = 4;
		break;
	case IdleActionKind::Activate:
		action_type = 5;
		break;
	}
	const std::uint32_t packed =
			(static_cast<std::uint32_t>(index) << 16U) | action_type;
	const std::uint8_t response[4]{
			static_cast<std::uint8_t>(packed & 0xffU),
			static_cast<std::uint8_t>((packed >> 8U) & 0xffU),
			static_cast<std::uint8_t>((packed >> 16U) & 0xffU),
			static_cast<std::uint8_t>((packed >> 24U) & 0xffU),
	};
	last_submitted_action_ = pending_action_;
	allow_auto_select_place_ =
			kind == IdleActionKind::NormalSummon
			|| kind == IdleActionKind::SpecialSummon
			|| kind == IdleActionKind::MonsterSet
			|| kind == IdleActionKind::SpellTrapSet;
	OCG_DuelSetResponse(static_cast<OCG_Duel>(duel_), response, sizeof(response));
	pending_action_ = {};
	return process_once();
}

ProcessResult DuelSession::submit_battle_action(
		const BattleActionKind kind,
		const std::size_t index) {
	if (!is_active()) {
		return {false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}};
	}
	if (pending_action_.kind != PendingActionKind::Battle) {
		return {false, OCG_DUEL_STATUS_AWAITING, "当前不是战斗阶段动作选择", pending_action_};
	}
	const auto candidate = std::find_if(
			pending_action_.battle_actions.begin(),
			pending_action_.battle_actions.end(),
			[kind, index](const BattleAction &action) {
				return action.kind == kind && action.index == index;
			});
	if (candidate == pending_action_.battle_actions.end() || index > 0xffffU) {
		return {false, OCG_DUEL_STATUS_AWAITING, "战斗动作不属于当前 OCGCore 候选列表", pending_action_};
	}
	const std::uint32_t action_type =
			kind == BattleActionKind::Activate ? 0U : 1U;
	const std::uint32_t packed =
			(static_cast<std::uint32_t>(index) << 16U) | action_type;
	const std::uint8_t response[4]{
			static_cast<std::uint8_t>(packed & 0xffU),
			static_cast<std::uint8_t>((packed >> 8U) & 0xffU),
			static_cast<std::uint8_t>((packed >> 16U) & 0xffU),
			static_cast<std::uint8_t>((packed >> 24U) & 0xffU),
	};
	last_submitted_action_ = pending_action_;
	allow_auto_select_place_ = false;
	OCG_DuelSetResponse(static_cast<OCG_Duel>(duel_), response, sizeof(response));
	pending_action_ = {};
	return process_once();
}

ProcessResult DuelSession::submit_yes_no(const bool accepted) {
	if (!is_active()) {
		return {false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}};
	}
	const DuelResponse response =
			build_yes_no_response(pending_action_, accepted);
	if (!response.ok) {
		return {
				false,
				OCG_DUEL_STATUS_AWAITING,
				response.message,
				pending_action_,
		};
	}

	last_submitted_action_ = pending_action_;
	allow_auto_select_place_ = false;
	OCG_DuelSetResponse(
			static_cast<OCG_Duel>(duel_),
			response.bytes.data(),
			static_cast<std::uint32_t>(response.bytes.size()));
	pending_action_ = {};
	return process_once();
}

ProcessResult DuelSession::submit_card_selection(
		const std::size_t option_index) {
	if (!is_active()) {
		return {false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}};
	}
	const DuelResponse response =
			build_card_selection_response(pending_action_, option_index);
	if (!response.ok) {
		return {
				false,
				OCG_DUEL_STATUS_AWAITING,
				response.message,
				pending_action_,
		};
	}

	last_submitted_action_ = pending_action_;
	allow_auto_select_place_ = false;
	OCG_DuelSetResponse(
			static_cast<OCG_Duel>(duel_),
			response.bytes.data(),
			static_cast<std::uint32_t>(response.bytes.size()));
	pending_action_ = {};
	return process_once();
}

ProcessResult DuelSession::cancel_card_selection() {
	if (!is_active()) {
		return {false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}};
	}
	const DuelResponse response =
			build_card_selection_cancel_response(pending_action_);
	if (!response.ok) {
		return {
				false,
				OCG_DUEL_STATUS_AWAITING,
				response.message,
				pending_action_,
		};
	}

	last_submitted_action_ = pending_action_;
	allow_auto_select_place_ = false;
	OCG_DuelSetResponse(
			static_cast<OCG_Duel>(duel_),
			response.bytes.data(),
			static_cast<std::uint32_t>(response.bytes.size()));
	pending_action_ = {};
	return process_once();
}

ProcessResult DuelSession::submit_position(const std::uint32_t position) {
	if (!is_active()) {
		return {false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}};
	}
	const DuelResponse response =
			build_position_response(pending_action_, position);
	if (!response.ok) {
		return {
				false,
				OCG_DUEL_STATUS_AWAITING,
				response.message,
				pending_action_,
		};
	}

	last_submitted_action_ = pending_action_;
	allow_auto_select_place_ = false;
	OCG_DuelSetResponse(
			static_cast<OCG_Duel>(duel_),
			response.bytes.data(),
			static_cast<std::uint32_t>(response.bytes.size()));
	pending_action_ = {};
	return process_once();
}

ProcessResult DuelSession::submit_enter_main2() {
	if (!is_active()) {
		return {false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}};
	}
	if (pending_action_.kind != PendingActionKind::Battle
			|| !pending_action_.can_enter_main2) {
		return {false, OCG_DUEL_STATUS_AWAITING, "当前不能进入主要阶段二", pending_action_};
	}
	const std::uint8_t response[4]{2, 0, 0, 0};
	last_submitted_action_ = pending_action_;
	OCG_DuelSetResponse(static_cast<OCG_Duel>(duel_), response, sizeof(response));
	pending_action_ = {};
	return process_once();
}

ProcessResult DuelSession::submit_end_battle() {
	if (!is_active()) {
		return {false, OCG_DUEL_STATUS_END, "决斗尚未创建", {}};
	}
	if (pending_action_.kind != PendingActionKind::Battle
			|| !pending_action_.can_end_battle) {
		return {false, OCG_DUEL_STATUS_AWAITING, "当前不能结束战斗阶段", pending_action_};
	}
	const std::uint8_t response[4]{3, 0, 0, 0};
	last_submitted_action_ = pending_action_;
	OCG_DuelSetResponse(static_cast<OCG_Duel>(duel_), response, sizeof(response));
	pending_action_ = {};
	return process_once();
}

std::uint32_t DuelSession::query_count(
		const std::uint8_t team,
		const std::uint32_t location) const {
	if (!is_active() || team > 1) {
		return 0;
	}
	return OCG_DuelQueryCount(static_cast<OCG_Duel>(duel_), team, location);
}

std::vector<DuelCardSnapshot> DuelSession::query_cards(
		const std::uint8_t team,
		const std::uint32_t location) const {
	std::vector<DuelCardSnapshot> cards;
	if (!is_active() || team > 1 || location == 0
			|| (location & (location - 1U)) != 0) {
		return cards;
	}

	const OCG_QueryInfo query{
			QUERY_CODE | QUERY_POSITION,
			team,
			location,
			0,
			0,
	};
	std::uint32_t length = 0;
	const auto *buffer = static_cast<const std::uint8_t *>(
			OCG_DuelQueryLocation(
					static_cast<OCG_Duel>(duel_),
					&length,
					&query));
	if (buffer == nullptr || length < sizeof(std::uint32_t)) {
		return cards;
	}

	auto read_u16 = [](const std::uint8_t *data) {
		return static_cast<std::uint16_t>(data[0])
				| (static_cast<std::uint16_t>(data[1]) << 8U);
	};
	auto read_u32 = [](const std::uint8_t *data) {
		return static_cast<std::uint32_t>(data[0])
				| (static_cast<std::uint32_t>(data[1]) << 8U)
				| (static_cast<std::uint32_t>(data[2]) << 16U)
				| (static_cast<std::uint32_t>(data[3]) << 24U);
	};

	// QueryLocation 的首个 uint32 是其后负载长度。每个槽位由若干
	// “uint16 块长 + uint32 查询标志 + 值”组成，并以 QUERY_END 结束。
	// 任意越界或未知短块都使查询整体失败，避免把损坏数据展示为合法卡片。
	const std::uint32_t payload_size = read_u32(buffer);
	if (payload_size > length - sizeof(std::uint32_t)) {
		return {};
	}
	std::size_t offset = sizeof(std::uint32_t);
	const std::size_t end = offset + payload_size;
	std::uint32_t sequence = 0;
	DuelCardSnapshot card{0, 0, location, 0};
	while (offset < end) {
		if (end - offset < sizeof(std::uint16_t)) {
			return {};
		}
		const std::uint16_t chunk_size = read_u16(buffer + offset);
		offset += sizeof(std::uint16_t);
		if (chunk_size == 0) {
			++sequence;
			card = {0, 0, location, sequence};
			continue;
		}
		if (chunk_size < sizeof(std::uint32_t) || chunk_size > end - offset) {
			return {};
		}
		const std::uint32_t flag = read_u32(buffer + offset);
		if (flag == QUERY_END) {
			if (card.card_id != 0) {
				card.sequence = sequence;
				cards.push_back(card);
			}
			++sequence;
			card = {0, 0, location, sequence};
		} else if (chunk_size >= 2 * sizeof(std::uint32_t)) {
			const std::uint32_t value =
					read_u32(buffer + offset + sizeof(std::uint32_t));
			if (flag == QUERY_CODE) {
				card.card_id = value;
			} else if (flag == QUERY_POSITION) {
				card.position = value;
			}
		}
		offset += chunk_size;
	}
	return cards;
}

void DuelSession::destroy() noexcept {
	if (duel_ == nullptr) {
		return;
	}
	OCG_DestroyDuel(static_cast<OCG_Duel>(duel_));
	duel_ = nullptr;
	pending_action_ = {};
	last_submitted_action_ = {};
	allow_auto_select_place_ = false;
}

bool DuelSession::is_active() const noexcept {
	return duel_ != nullptr;
}

} // namespace ygo
