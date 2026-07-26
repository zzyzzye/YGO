#pragma once

#include "ygo/card_database.hpp"

#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>

namespace ygo {

struct CardSourceFingerprint {
	std::uint64_t json_hash = 0;
	std::uint64_t image_list_hash = 0;

	[[nodiscard]] bool operator==(const CardSourceFingerprint &other) const noexcept {
		return json_hash == other.json_hash && image_list_hash == other.image_list_hash;
	}
};

struct CacheWriteResult {
	bool ok = false;
	std::string message;
};

struct CacheReadResult {
	bool ok = false;
	std::string message;
	std::shared_ptr<CardDatabase> database;
};

class CardCache final {
public:
	static CacheWriteResult write_atomic(
			const std::filesystem::path &cache_path,
			const CardDatabase &database,
			CardSourceFingerprint fingerprint);

	static CacheReadResult read(
			const std::filesystem::path &cache_path,
			CardSourceFingerprint expected_fingerprint);
};

} // namespace ygo
