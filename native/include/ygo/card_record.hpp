#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace ygo {

// 这些类型只保存卡片的稳定值，不持有 JSON 节点、文件句柄、Godot 对象或
// OCGCore 指针。数据库、二进制缓存和决斗规则层因此可以共享同一份字段
// 定义，而不会把某个解析器或运行时的生命周期泄漏到其他模块。
struct CardDisplayData {
	std::uint32_t cid = 0;
	std::string cn_name;
	std::string types_text;
	std::string pendulum_description;
	std::string description;
	std::string image_relative_path;
};

struct CardRuleData {
	std::uint32_t code = 0;
	std::uint32_t alias = 0;
	std::uint32_t type = 0;
	std::uint32_t level = 0;
	std::uint32_t attribute = 0;
	std::uint64_t race = 0;
	std::int32_t attack = 0;
	std::int32_t defense = 0;
	std::uint32_t left_scale = 0;
	std::uint32_t right_scale = 0;
	std::uint32_t link_marker = 0;
	std::vector<std::uint16_t> setcodes;
};

struct CardRecord {
	CardDisplayData display;
	CardRuleData rule;
};

} // namespace ygo
