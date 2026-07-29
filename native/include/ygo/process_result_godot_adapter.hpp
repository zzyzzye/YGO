#pragma once

#include "ygo/duel_session.hpp"

#include <godot_cpp/variant/dictionary.hpp>

namespace ygo {

// 将 Session 已验证的推进结果转换为 Godot 值对象。转换必须同时保留
// response_rejected 与恢复后的 PendingAction，确保 MSG_RETRY 不会在桥接边界
// 丢失原选择上下文；该内部适配器不绑定 ClassDB，也不暴露 Session 或原始字节。
[[nodiscard]] godot::Dictionary process_result_to_dictionary(
		const ProcessResult &result);

} // namespace ygo
