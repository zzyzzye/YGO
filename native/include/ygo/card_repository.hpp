#pragma once

#include "ygo/card_cache.hpp"

#include <filesystem>
#include <memory>
#include <string>
#include <vector>

namespace ygo {

struct CardRepositoryPaths {
	std::filesystem::path cards_json;
	std::filesystem::path images_directory;
	std::filesystem::path cache_file;
};

enum class CacheState {
	Hit,
	Rebuilt,
};

struct RepositoryInitResult {
	bool ok = false;
	CacheState cache_state = CacheState::Rebuilt;
	std::string message;
	std::shared_ptr<CardDatabase> database;
	CardDatabaseStats stats;
	std::vector<std::string> warnings;
};

class CardRepository final {
public:
	RepositoryInitResult initialize(const CardRepositoryPaths &paths) const;
};

} // namespace ygo
