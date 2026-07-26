#pragma once

#include "ygo/ocg_card_data_adapter.hpp"
#include "ygo/official_script_loader.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <utility>

namespace ygo {

struct CreateResult {
	bool ok = false;
	int status = -1;
	std::string message;
};

class DuelSession final {
public:
	DuelSession(
			std::shared_ptr<const CardDatabase> database,
			std::shared_ptr<OfficialScriptLoader> scripts);
	~DuelSession();

	DuelSession(const DuelSession &) = delete;
	DuelSession &operator=(const DuelSession &) = delete;

	static std::pair<int, int> core_version();
	CreateResult create(std::uint64_t seed);
	void destroy() noexcept;
	[[nodiscard]] bool is_active() const noexcept;

private:
	std::shared_ptr<const CardDatabase> database_;
	std::shared_ptr<OfficialScriptLoader> scripts_;
	OcgCardDataAdapter card_data_adapter_;
	void *duel_ = nullptr;
};

} // namespace ygo
