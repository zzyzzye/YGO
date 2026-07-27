#pragma once

#include "ygo/ocg_card_data_adapter.hpp"
#include "ygo/duel_message_parser.hpp"
#include "ygo/official_script_loader.hpp"

#include <cstdint>
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
	[[nodiscard]] const PendingAction &pending_action() const noexcept {
		return pending_action_;
	}

	// 查询某方某区域当前卡数。仅允许单区域查询（loc 需是 LOCATION_* 单位标志位）。
	[[nodiscard]] std::uint32_t query_count(std::uint8_t team, std::uint32_t location) const;
	void destroy() noexcept;
	[[nodiscard]] bool is_active() const noexcept;

private:
	std::shared_ptr<const CardDatabase> database_;
	std::shared_ptr<OfficialScriptLoader> scripts_;
	OcgCardDataAdapter card_data_adapter_;
	void *duel_ = nullptr;
	PendingAction pending_action_;
	PendingAction last_submitted_action_;

	[[nodiscard]] ProcessResult process_once();
};

} // namespace ygo
