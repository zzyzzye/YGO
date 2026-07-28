// 本文件只会被 test_pending_action_godot_adapter 目标编译。先以正常访问控制
// 加载 Godot、C++ 标准库与 DuelSession 的全部依赖，再仅在载入 Bridge 头时把
// private 临时改为 public；因此宏不会污染 shipped headers、标准库或 Godot。
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <array>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "ygo/card_repository.hpp"
#include "ygo/duel_message_parser.hpp"
#include "ygo/ocg_card_data_adapter.hpp"
#include "ygo/official_script_loader.hpp"

#define private public
#include "ygo/ygo_core_bridge.hpp"
#undef private

#include "ocgapi_constants.h"

namespace ygo::test_access {

DuelSession &install_controlled_session(YgoCoreBridge &bridge) {
	bridge.session_ = std::make_unique<DuelSession>(nullptr, nullptr);
	return *bridge.session_;
}

void set_active(DuelSession &session) {
	session.duel_ = reinterpret_cast<void *>(static_cast<std::uintptr_t>(1));
}

void set_pending_place(
		DuelSession &session,
		const int player,
		const int winner) {
	session.pending_action_.kind = PendingActionKind::SelectPlace;
	session.pending_action_.player = player;
	// 受控门禁用例提交 sequence=3，而快照只允许 4；若未来有人错误绕过
	// Bridge 的玩家/终局门禁，Session 仍会在写入 OCGCore 前拒绝该值，
	// 避免伪活动句柄被触发，同时让测试观察到错误的错误路径。
	session.pending_action_.place_options = {{0, LOCATION_MZONE, 4}};
	session.winner_ = winner;
}

const PendingAction &pending(const DuelSession &session) {
	return session.pending_action_;
}

void remove_controlled_session(YgoCoreBridge &bridge) {
	bridge.session_->duel_ = nullptr;
	bridge.session_.reset();
}

} // namespace ygo::test_access
