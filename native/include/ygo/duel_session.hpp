#pragma once

#include "ygo/ocg_card_data_adapter.hpp"
#include "ygo/duel_message_parser.hpp"
#include "ygo/official_script_loader.hpp"

#include <cstdint>
#include <array>
#include <vector>
#include <memory>
#include <string>
#include <utility>

namespace ygo {

struct CreateResult {
	bool ok = false;
	int status = -1;
	std::string message;
};

struct AddDeckResult {
	bool ok = false;
	std::size_t added = 0;
	std::string message;
};

struct ProcessResult {
	bool ok = false;
	int status = -1;
	std::string message;
	PendingAction pending_action;
};

// OCGCore 区域查询返回的最小可视快照。这里只保留界面渲染和动作校验所需的
// 稳定字段，不暴露 core 内部 card 指针；sequence 是该卡在目标区域中的槽位。
struct DuelCardSnapshot {
	std::uint32_t card_id = 0;
	std::uint32_t position = 0;
	std::uint32_t location = 0;
	std::uint32_t sequence = 0;
};

class DuelSession final {
public:
	DuelSession(
			std::shared_ptr<const CardDatabase> database,
			std::shared_ptr<OfficialScriptLoader> scripts);
	~DuelSession();

	DuelSession(const DuelSession &) = delete;
	DuelSession &operator=(const DuelSession &) = delete;

	static std::pair<int, int> core_version();
	CreateResult create(std::uint64_t seed);
	// 将一组卡号下发到指定队伍的某个区域（目前仅用于主卡组初始化）。
	// 返回已加入卡数和失败原因，便于诊断“缺卡脚本/非法卡号”等问题。
	[[nodiscard]] AddDeckResult add_deck_cards(
			std::uint8_t team,
			const std::vector<std::uint32_t> &codes,
			std::uint32_t location,
			std::uint8_t duelist = 0) const;

	// 启动或继续推进一次 OCGCore，并在内部缓冲区失效前同步解析本轮消息。
	[[nodiscard]] ProcessResult start();
	[[nodiscard]] ProcessResult step();
	// 玩家在等待决策阶段提交返回值（返回协议由 OCGCore 各 Processor 定义）。
	// 协议仅是字节序列，调用方负责按当前 Processor 的字段约定组包。
	void set_response(const void *response_data, std::size_t response_size);
	// 仅在解析器确认当前为空闲阶段且允许进入结束阶段时提交语义动作。
	// 校验失败不会向 OCGCore 写入任何响应。
	[[nodiscard]] ProcessResult submit_end_turn();
	// MSG_SELECT_IDLECMD 的 type=6 表示从主要阶段一进入战斗阶段。
	[[nodiscard]] ProcessResult submit_enter_battle();
	// 提交当前 MSG_SELECT_IDLECMD 快照中真实存在的候选。kind 和 index 必须
	// 同时匹配，防止界面使用过期索引或跨类别索引驱动 OCGCore。
	[[nodiscard]] ProcessResult submit_idle_action(
			IdleActionKind kind,
			std::size_t index);
	// 提交战斗阶段当前快照中的“发动”或“攻击”候选。
	[[nodiscard]] ProcessResult submit_battle_action(
			BattleActionKind kind,
			std::size_t index);
	// 是非与卡牌选择只接受当前解析快照中的语义输入。Session 独占协议组包
	// 和 OCGCore 提交，界面不能绕过候选、类型或取消能力门禁。
	[[nodiscard]] ProcessResult submit_yes_no(bool accepted);
	[[nodiscard]] ProcessResult submit_card_selection(std::size_t option_index);
	[[nodiscard]] ProcessResult cancel_card_selection();
	// 分别对应 MSG_SELECT_BATTLECMD 的 type=2（主要阶段二）和 type=3（结束）。
	[[nodiscard]] ProcessResult submit_enter_main2();
	[[nodiscard]] ProcessResult submit_end_battle();
	[[nodiscard]] const PendingAction &pending_action() const noexcept {
		return pending_action_;
	}
	[[nodiscard]] std::int32_t life_points(std::uint8_t team) const noexcept {
		return team < life_points_.size() ? life_points_[team] : 0;
	}
	[[nodiscard]] int winner() const noexcept {
		return winner_;
	}
	[[nodiscard]] int win_reason() const noexcept {
		return win_reason_;
	}

	// 查询某方某区域当前卡数。仅允许单区域查询（loc 需是 LOCATION_* 单位标志位）。
	[[nodiscard]] std::uint32_t query_count(std::uint8_t team, std::uint32_t location) const;
	// 查询某方单一区域的卡号、表示形式和槽位。返回值是同步复制的快照，
	// 因为 OCGCore 返回的查询缓冲区只保证在下一次 core 调用前有效。
	[[nodiscard]] std::vector<DuelCardSnapshot> query_cards(
			std::uint8_t team,
			std::uint32_t location) const;
	void destroy() noexcept;
	[[nodiscard]] bool is_active() const noexcept;

private:
	std::shared_ptr<const CardDatabase> database_;
	std::shared_ptr<OfficialScriptLoader> scripts_;
	OcgCardDataAdapter card_data_adapter_;
	void *duel_ = nullptr;
	PendingAction pending_action_;
	PendingAction last_submitted_action_;
	// 只有召唤/盖放动作的紧随后续区域选择才允许确定性自动选区。
	// 效果处理产生的选区必须交回上层，避免擅自替玩家决定效果目标。
	bool allow_auto_select_place_ = false;
	std::array<std::int32_t, 2> life_points_{8000, 8000};
	int winner_ = -1;
	int win_reason_ = -1;

	[[nodiscard]] ProcessResult process_once();
};

} // namespace ygo
