#pragma once

#include <cstdint>
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
	DuelSession() = default;
	~DuelSession();

	DuelSession(const DuelSession &) = delete;
	DuelSession &operator=(const DuelSession &) = delete;

	static std::pair<int, int> core_version();
	CreateResult create(std::uint64_t seed);
	void destroy() noexcept;
	[[nodiscard]] bool is_active() const noexcept;

private:
	void *duel_ = nullptr;
};

} // namespace ygo
