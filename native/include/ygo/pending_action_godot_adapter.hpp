#pragma once

#include "ygo/duel_message_parser.hpp"

#include <godot_cpp/variant/dictionary.hpp>

namespace ygo {

// 将 C++ 已校验的决策快照转换为 Godot 可消费的 Dictionary。
// 该边界负责隐藏对手里侧卡号，并始终提供选择元数据的稳定缺省值；
// GDScript 只能展示这里公开的语义字段，不能读取或拼装 OCGCore 原始响应。
[[nodiscard]] godot::Dictionary pending_action_to_dictionary(
		const PendingAction &pending);

} // namespace ygo
