#include "ygo/ygo_core_bridge.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <filesystem>
#include <limits>
#include <utility>

namespace ygo {

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
	godot::ClassDB::bind_method(godot::D_METHOD("create_duel", "seed"), &YgoCoreBridge::create_duel);
	godot::ClassDB::bind_method(godot::D_METHOD("destroy_duel"), &YgoCoreBridge::destroy_duel);
	godot::ClassDB::bind_method(godot::D_METHOD("is_duel_active"), &YgoCoreBridge::is_duel_active);
}

} // namespace ygo
