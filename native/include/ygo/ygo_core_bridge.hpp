#pragma once

#include "ygo/card_repository.hpp"
#include "ygo/duel_session.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

#include <filesystem>
#include <memory>
#include <vector>

namespace ygo {

// 仅用于原生契约测试构造 Bridge 层在公开单机流程中不可稳定复现的状态门禁。
// 它不是 Godot ClassDB 接口，也不提供 OCGCore 原始响应访问能力。
struct YgoCoreBridgeTestAccess;

class YgoCoreBridge final : public godot::RefCounted {
	GDCLASS(YgoCoreBridge, godot::RefCounted)

public:
	YgoCoreBridge();
	~YgoCoreBridge() override = default;

	// 以 Godot 全局化后的项目根目录为唯一入口初始化数据层。桥接层在这里统一派生
	// JSON、卡图、缓存和 Lua 目录，避免 GDScript 或 C++ 写死某台机器的绝对路径。
	// 返回 Dictionary 是为了让诊断界面同时展示结果、统计和中文错误。
	godot::Dictionary initialize_card_database(const godot::String &project_root);
	std::int64_t get_card_count() const;
	godot::Dictionary get_card(std::int64_t id) const;
	godot::Dictionary get_cache_state() const;
	godot::Dictionary get_core_version() const;
	// 扫描数据库与 Lua official/c<id>.lua 的交集，返回供最小闭环使用的
	// 通常主卡组卡号；必要时确定性重复卡号补足 40 张。此诊断牌组不应用禁限表。
	godot::PackedInt64Array get_scripted_card_ids() const;
	godot::Dictionary create_duel(std::int64_t seed);
	// 以给定两个主卡组（数组每个元素为规则卡号）重建一次决斗。
	// 重放性来自 seed，起始手牌由 OCGCore 规则按该 seed 决定。
	godot::Dictionary setup_duel(
			const godot::PackedInt64Array &player1_main,
			const godot::PackedInt64Array &player2_main,
			std::int64_t seed);
	// 对已启动对局执行下一次 OCGCore 处理，通常用于按钮触发的单步推进。
	godot::Dictionary start_duel();
	// 旧版原始响应兼容入口；新界面不得使用，后续动作应逐个增加语义接口。
	godot::Dictionary send_duel_response(const godot::PackedByteArray &response);
	// 返回 C++ 已验证的语义决策，Godot 不接触 OCGCore 原始消息。
	godot::Dictionary get_pending_action() const;
	// 仅在当前空闲阶段允许进入结束阶段时提交动作，并推进到下一个决策点。
	godot::Dictionary submit_end_turn();
	godot::Dictionary submit_enter_battle();
	godot::Dictionary submit_enter_main2();
	godot::Dictionary submit_end_battle();
	// 提交当前空闲阶段真实候选；action_kind 使用稳定英文协议标识，
	// 用户可见按钮文字仍由 Godot 以中文显示。
	godot::Dictionary submit_idle_action(
			const godot::String &action_kind,
			std::int64_t index);
	godot::Dictionary submit_battle_action(
			const godot::String &action_kind,
			std::int64_t index);
	// 是非与卡牌选择只传递稳定语义参数；成功后继续自动推进对手决策，
	// 返回下一个本地决策快照。负索引在任何无符号窄化前由 Bridge 拒绝。
	godot::Dictionary submit_yes_no(bool accepted);
	godot::Dictionary submit_card_selection(std::int64_t index);
	godot::Dictionary cancel_card_selection();
	godot::Dictionary submit_position(std::int64_t position);
	// 连锁候选只能通过本次快照中的稳定索引提交；跳过由 C++ 调用
	// DuelSession::pass_chain() 构造 int32(-1) 协议响应，Godot 不得拼装原始字节。
	// 两个入口都会拒绝非本地玩家、终局和无活动会话，submit_chain 还会在
	// 转为 size_t 前拒绝负索引，防止不可信 Godot 参数发生无符号窄化。
	godot::Dictionary submit_chain(std::int64_t index);
	godot::Dictionary pass_chain();
	// 区域选择只接收 PendingAction::place_options 已发布的三元组。Bridge 在
	// 窄化为 OCGCore 的 uint8 协议字段前验证范围，并以当前 pending player
	// 作为本地玩家门禁；Godot 不能借此构造或发送任意原始响应字节。
	godot::Dictionary submit_place(
			std::int64_t controller,
			std::int64_t location,
			std::int64_t sequence);
	// 返回当前双方场上状态计数（卡组/手牌/怪兽区/魔陷区/墓地/除外区）。
	godot::Dictionary get_duel_state() const;
	void destroy_duel();
	bool is_duel_active() const;

protected:
	static void _bind_methods();

private:
	friend struct YgoCoreBridgeTestAccess;
	// OCGCore 通过回调借用卡库和脚本加载器，因此两者必须比 DuelSession 活得更久。
	// 成员声明顺序配合显式重置顺序，保证活动决斗总是最先被销毁。
	std::shared_ptr<CardDatabase> database_;
	std::shared_ptr<OfficialScriptLoader> scripts_;
	std::unique_ptr<DuelSession> session_;
	std::filesystem::path scripts_root_;
	// 保留最近一次初始化结果，供 Godot 不重复扫描素材即可查询缓存状态。
	RepositoryInitResult repository_status_;
};

} // namespace ygo
