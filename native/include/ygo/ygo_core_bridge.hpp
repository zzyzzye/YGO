#pragma once

#include "ygo/card_repository.hpp"
#include "ygo/duel_session.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <memory>

namespace ygo {

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
	godot::Dictionary create_duel(std::int64_t seed);
	void destroy_duel();
	bool is_duel_active() const;

protected:
	static void _bind_methods();

private:
	// OCGCore 通过回调借用卡库和脚本加载器，因此两者必须比 DuelSession 活得更久。
	// 成员声明顺序配合显式重置顺序，保证活动决斗总是最先被销毁。
	std::shared_ptr<CardDatabase> database_;
	std::shared_ptr<OfficialScriptLoader> scripts_;
	std::unique_ptr<DuelSession> session_;
	// 保留最近一次初始化结果，供 Godot 不重复扫描素材即可查询缓存状态。
	RepositoryInitResult repository_status_;
};

} // namespace ygo
