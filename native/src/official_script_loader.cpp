#include "ygo/official_script_loader.hpp"

#include "ocgapi.h"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <iterator>
#include <limits>
#include <optional>
#include <utility>

namespace {

bool is_safe_root_script(std::string_view name) {
	constexpr std::string_view suffix = ".lua";
	if (name.size() <= suffix.size()
			|| name.substr(name.size() - suffix.size()) != suffix) {
		return false;
	}
	const auto stem = name.substr(0, name.size() - suffix.size());
	return std::all_of(stem.begin(), stem.end(), [](unsigned char character) {
		return std::isalnum(character) != 0 || character == '_';
	});
}

bool is_card_script(std::string_view name) {
	constexpr std::string_view suffix = ".lua";
	if (name.size() <= 1 + suffix.size() || name.front() != 'c'
			|| name.substr(name.size() - suffix.size()) != suffix) {
		return false;
	}
	const auto digits = name.substr(1, name.size() - 1 - suffix.size());
	return std::all_of(digits.begin(), digits.end(), [](unsigned char character) {
		return std::isdigit(character) != 0;
	});
}

bool contains_forbidden_path_syntax(std::string_view name) {
	return name.find('\0') != std::string_view::npos
			|| name.find('/') != std::string_view::npos
			|| name.find('\\') != std::string_view::npos
			|| name.find(':') != std::string_view::npos
			|| name.find("..") != std::string_view::npos;
}

std::optional<std::string> read_file(const std::filesystem::path &path) {
	std::ifstream input(path, std::ios::binary);
	if (!input) {
		return std::nullopt;
	}
	return std::string{
		std::istreambuf_iterator<char>(input),
		std::istreambuf_iterator<char>(),
	};
}

} // namespace

namespace ygo {

OfficialScriptLoader::OfficialScriptLoader(std::filesystem::path scripts_root) :
		scripts_root_(std::move(scripts_root)) {
}

ScriptLoadResult OfficialScriptLoader::validate() const {
	if (!std::filesystem::is_directory(scripts_root_)) {
		return {false, "Lua 脚本根目录不存在：" + scripts_root_.string(), {}};
	}
	for (const char *required : {"constant.lua", "utility.lua"}) {
		if (!std::filesystem::is_regular_file(scripts_root_ / required)) {
			return {false, "缺少必需的 Lua 基础脚本：" + std::string(required), {}};
		}
	}
	if (!std::filesystem::is_directory(scripts_root_ / "official")) {
		return {false, "正式卡 Lua 脚本目录不存在：official", {}};
	}
	return {true, "Lua 脚本目录校验成功", {}};
}

ScriptLoadResult OfficialScriptLoader::read_requested(std::string_view name) const {
	if (name.empty() || contains_forbidden_path_syntax(name)) {
		return {false, "已拒绝越界或非法 Lua 脚本请求：" + std::string(name), {}};
	}

	std::filesystem::path path;
	if (is_card_script(name)) {
		path = scripts_root_ / "official" / std::string(name);
	} else if (is_safe_root_script(name)) {
		path = scripts_root_ / std::string(name);
	} else {
		return {false, "已拒绝非白名单 Lua 脚本请求：" + std::string(name), {}};
	}

	const auto bytes = read_file(path);
	if (!bytes) {
		return {false, "无法读取 Lua 脚本：" + path.string(), {}};
	}
	return {true, "Lua 脚本读取成功", *bytes};
}

int OfficialScriptLoader::load_requested(OCG_Duel duel, std::string_view name) {
	const auto script = read_requested(name);
	if (!script.ok) {
		last_error_ = script.message;
		return 0;
	}
	if (script.bytes.size() > std::numeric_limits<std::uint32_t>::max()) {
		last_error_ = "Lua 脚本过大，无法交给 OCGCore：" + std::string(name);
		return 0;
	}

	// OCGCore 要求脚本名称为空字符结尾，因此这里构造独立字符串，不能
	// 直接把可能来自任意 string_view 的 data() 传入 C 接口。
	const std::string owned_name(name);
	const int status = OCG_LoadScript(
			duel,
			script.bytes.data(),
			static_cast<std::uint32_t>(script.bytes.size()),
			owned_name.c_str());
	if (status == 0) {
		last_error_ = "OCGCore 加载 Lua 脚本失败：" + owned_name;
	}
	return status;
}

ScriptLoadResult OfficialScriptLoader::load_bootstrap(OCG_Duel duel) {
	for (const char *name : {"constant.lua", "utility.lua"}) {
		if (load_requested(duel, name) == 0) {
			return {false, last_error_, {}};
		}
	}
	return {true, "Lua 基础脚本加载成功", {}};
}

const std::string &OfficialScriptLoader::last_error() const noexcept {
	return last_error_;
}

} // namespace ygo
