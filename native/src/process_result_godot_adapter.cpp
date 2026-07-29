#include "ygo/process_result_godot_adapter.hpp"

#include "ygo/pending_action_godot_adapter.hpp"

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace ygo {

godot::Dictionary process_result_to_dictionary(const ProcessResult &result) {
	godot::Dictionary response;
	response["ok"] = result.ok;
	response["status"] = result.status;
	response["message"] = godot::String::utf8(result.message.c_str());
	response["pending_action"] =
			pending_action_to_dictionary(result.pending_action);
	response["response_rejected"] = result.response_rejected;
	return response;
}

} // namespace ygo
