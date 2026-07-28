#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace ygo {

enum class PendingActionKind {
	None,
	Idle,
	Battle,
	YesNo,
	SelectCard,
	SelectPosition,
	SelectChain,
	AutoPassChain,
	SelectPlace,
	Retry,
	Unsupported,
	Malformed,
};

enum class BattleActionKind {
	Activate,
	Attack,
};

enum class IdleActionKind {
	NormalSummon,
	SpecialSummon,
	Reposition,
	MonsterSet,
	SpellTrapSet,
	Activate,
};

// 对应 MSG_SELECT_IDLECMD 六类候选中的一项。index 是该类别内部的下标，
// 不是合并列表下标；提交响应时必须与 kind 一起使用。
struct IdleAction {
	IdleActionKind kind = IdleActionKind::NormalSummon;
	std::size_t index = 0;
	std::uint32_t card_id = 0;
	std::uint8_t controller = 0;
	std::uint8_t location = 0;
	std::uint32_t sequence = 0;
	std::uint64_t description = 0;
	std::uint8_t client_mode = 0;
};

// MSG_SELECT_PLACE 的一个已经验证的单区域候选。OCGCore forbidden 位图的
// 低 16 位属于决策玩家、高 16 位属于另一方；解析器在此完成位到语义三元组的
// 转换，后续 Godot 和响应层只能使用这些值，不能重新解释原始位掩码。
struct PlaceOption {
	std::uint8_t player = 0;
	std::uint8_t location = 0;
	std::uint8_t sequence = 0;
};

// 对应 MSG_SELECT_CARD 的一项候选。index 是 OCGCore 候选表中的稳定下标，
// 响应层只能提交该下标，不能根据卡片编号或场上位置自行重新匹配候选。
struct CardSelectionOption {
	std::size_t index = 0;
	std::uint32_t card_id = 0;
	std::uint8_t controller = 0;
	std::uint8_t location = 0;
	std::uint32_t sequence = 0;
	std::uint32_t position = 0;
};

// 对应 MSG_SELECT_CHAIN 的一个可发动效果。index 保持 OCGCore 在当前响应
// 窗口给出的候选顺序：同一张卡可以因不同效果出现多次，响应层不得按卡片
// 编号去重，必须仅提交经解析确认的 index。
struct ChainOption {
	std::size_t index = 0;
	std::uint32_t card_id = 0;
	std::uint8_t controller = 0;
	std::uint8_t location = 0;
	std::uint32_t sequence = 0;
	std::uint32_t position = 0;
	std::uint64_t description = 0;
	std::uint8_t client_mode = 0;
};

// 对应 MSG_SELECT_BATTLECMD 中的可发动效果或可攻击怪兽。攻击动作的
// direct_attackable 只说明该攻击者具备直接攻击能力，具体目标仍由后续
// OCGCore 消息决定，不能由界面提前推断。
struct BattleAction {
	BattleActionKind kind = BattleActionKind::Attack;
	std::size_t index = 0;
	std::uint32_t card_id = 0;
	std::uint8_t controller = 0;
	std::uint8_t location = 0;
	std::uint32_t sequence = 0;
	std::uint64_t description = 0;
	std::uint8_t client_mode = 0;
	bool direct_attackable = false;
};

enum class LifePointEventKind {
	Damage,
	Recover,
	Set,
};

// OCGCore 只通过通知消息公布 LP 变化，没有独立的公开 LP 查询接口。
// 会话层按消息顺序应用这些事件，因此解析器必须保留原始玩家、数值和语义。
struct LifePointEvent {
	LifePointEventKind kind = LifePointEventKind::Set;
	std::uint8_t player = 0;
	std::uint32_t amount = 0;
};

// 描述 OCGCore 当前等待的玩家决策。该值类型不暴露原始缓冲区，调用方只能
// 根据已经验证的语义字段决定是否显示或提交动作。
struct PendingAction {
	PendingActionKind kind = PendingActionKind::None;
	int player = -1;
	bool can_end_turn = false;
	int message_type = -1;
	std::string message = "当前没有待处理的玩家决策";
	std::vector<IdleAction> idle_actions;
	// SelectPlace 的完整合法区域表。只有 count=1 且报文无尾随字节时才发布；
	// 空表或解析失败均以 Malformed 返回，避免调用方把默认位置误提交给核心。
	std::vector<PlaceOption> place_options;
	std::vector<BattleAction> battle_actions;
	bool can_enter_battle = false;
	bool can_enter_main2 = false;
	bool can_end_battle = false;
	std::vector<LifePointEvent> life_point_events;
	int winner = -1;
	int win_reason = -1;
	// MSG_SELECT_YESNO 的 OCGCore 描述编号。其语义由上层文案表解释，0 是
	// 未携带描述的默认值，不能与任意具体问题混用。
	std::uint64_t description = 0;
	// MSG_SELECT_CARD 的协议选择约束。只有 SelectCard 时这些字段才有意义；
	// 解析失败不会暴露半成品候选，调用方可据此安全地拒绝响应。
	bool cancelable = false;
	std::uint32_t min_select = 0;
	std::uint32_t max_select = 0;
	std::vector<CardSelectionOption> card_options;
	// MSG_SELECT_CHAIN 的 forced 字段只接受 0/1。为 true 时协议禁止提交
	// int32(-1) 跳过；chain_options 中每项都对应核心原始候选索引。
	bool chain_forced = false;
	std::vector<ChainOption> chain_options;
	// MSG_SELECT_POSITION 的 card_id 用于说明正在选择表示形式的规则卡牌；
	// position_options 已将核心位掩码拆成合法单值，Godot 不得自行解释掩码。
	std::uint32_t selection_card_id = 0;
	std::vector<std::uint32_t> position_options;
};

// 解析 OCGCore_DuelGetMessage 返回的完整缓冲区。缓冲区由若干
// “4 字节小端长度 + 消息正文”帧组成；函数不持有传入内存。
[[nodiscard]] PendingAction parse_pending_action(
		const std::uint8_t *data,
		std::size_t size);

} // namespace ygo
