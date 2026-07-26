#pragma once

#include "ocgapi_types.h"

#include <filesystem>
#include <string>
#include <string_view>

namespace ygo {

struct ScriptLoadResult {
	bool ok = false;
	std::string message;
	std::string bytes;
};

class OfficialScriptLoader final {
public:
	explicit OfficialScriptLoader(std::filesystem::path scripts_root);

	[[nodiscard]] ScriptLoadResult validate() const;
	[[nodiscard]] ScriptLoadResult read_requested(std::string_view name) const;
	int load_requested(OCG_Duel duel, std::string_view name);
	[[nodiscard]] ScriptLoadResult load_bootstrap(OCG_Duel duel);
	[[nodiscard]] const std::string &last_error() const noexcept;

private:
	std::filesystem::path scripts_root_;
	std::string last_error_;
};

} // namespace ygo
