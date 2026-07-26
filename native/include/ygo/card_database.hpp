#pragma once

#include "ygo/card_record.hpp"

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <map>
#include <memory>
#include <string>

namespace ygo {

struct CardDatabaseStats {
	std::size_t json_records = 0;
	std::size_t accepted_records = 0;
	std::size_t invalid_records = 0;
	std::size_t missing_image_records = 0;
};

class CardDatabase;

struct CardDatabaseLoadResult {
	bool ok = false;
	std::string message;
	std::shared_ptr<CardDatabase> database;
	CardDatabaseStats stats;
};

class CardDatabase final {
public:
	static CardDatabaseLoadResult load_json_intersection(
			const std::filesystem::path &cards_json,
			const std::filesystem::path &images_directory);

	[[nodiscard]] const CardRecord *find(std::uint32_t id) const noexcept;
	[[nodiscard]] std::size_t size() const noexcept;
	[[nodiscard]] const CardDatabaseStats &stats() const noexcept;
	[[nodiscard]] const std::map<std::uint32_t, CardRecord> &records() const noexcept;

private:
	std::map<std::uint32_t, CardRecord> records_;
	CardDatabaseStats stats_;
};

} // namespace ygo
