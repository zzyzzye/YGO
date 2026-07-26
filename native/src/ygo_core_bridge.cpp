#include "ygo/ygo_core_bridge.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string.hpp>

namespace ygo {

YgoCoreBridge::YgoCoreBridge() :
		session_(std::make_unique<DuelSession>()) {
}

godot::Dictionary YgoCoreBridge::get_core_version() const {
	const auto [major, minor] = DuelSession::core_version();
	godot::Dictionary version;
	version["major"] = major;
	version["minor"] = minor;
	return version;
}

godot::Dictionary YgoCoreBridge::create_duel(std::int64_t seed) {
	const CreateResult result = session_->create(static_cast<std::uint64_t>(seed));
	godot::Dictionary response;
	response["ok"] = result.ok;
	response["status"] = result.status;
	response["message"] = godot::String(result.message.c_str());
	return response;
}

void YgoCoreBridge::destroy_duel() {
	session_->destroy();
}

bool YgoCoreBridge::is_duel_active() const {
	return session_->is_active();
}

void YgoCoreBridge::_bind_methods() {
	godot::ClassDB::bind_method(godot::D_METHOD("get_core_version"), &YgoCoreBridge::get_core_version);
	godot::ClassDB::bind_method(godot::D_METHOD("create_duel", "seed"), &YgoCoreBridge::create_duel);
	godot::ClassDB::bind_method(godot::D_METHOD("destroy_duel"), &YgoCoreBridge::destroy_duel);
	godot::ClassDB::bind_method(godot::D_METHOD("is_duel_active"), &YgoCoreBridge::is_duel_active);
}

} // namespace ygo
