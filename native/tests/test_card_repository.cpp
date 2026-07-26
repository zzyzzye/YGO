#include "test_support.hpp"
#include "ygo/card_repository.hpp"

#include <cassert>
#include <cstdlib>
#include <filesystem>

namespace {

void write_fixture(const ygo::test::TemporaryDirectory &fixture) {
	fixture.write_text("data/cards.json", R"JSON({
	  "4007": {
	    "cid": 4007, "id": 89631139, "cn_name": "青眼白龙",
	    "text": {"types": "[怪兽|通常]", "pdesc": "", "desc": "传说中的龙。"},
	    "data": {"ot": 3, "setcode": 0, "type": 17, "atk": 3000, "def": 2500,
	             "level": 8, "race": 8192, "attribute": 16}
	  }
	})JSON");
	fixture.touch("images/89631139.webp");
}

ygo::CardRepositoryPaths paths_for(const ygo::test::TemporaryDirectory &fixture) {
	return {
		fixture.path("data/cards.json"),
		fixture.path("images"),
		fixture.path(".cache/cards/card_database.bin"),
	};
}

void test_rebuilds_then_hits_cache() {
	ygo::test::TemporaryDirectory fixture;
	write_fixture(fixture);
	ygo::CardRepository repository;

	const auto first = repository.initialize(paths_for(fixture));
	assert(first.ok);
	assert(first.cache_state == ygo::CacheState::Rebuilt);
	assert(first.database->size() == 1);

	const auto second = repository.initialize(paths_for(fixture));
	assert(second.ok);
	assert(second.cache_state == ygo::CacheState::Hit);
	assert(second.database->find(89631139) != nullptr);
}

void test_source_changes_force_rebuild() {
	ygo::test::TemporaryDirectory fixture;
	write_fixture(fixture);
	ygo::CardRepository repository;
	assert(repository.initialize(paths_for(fixture)).ok);

	fixture.write_text("data/cards.json", R"JSON({
	  "4007": {
	    "cid": 4007, "id": 89631139, "cn_name": "青眼白龙",
	    "text": {"types": "[怪兽|通常]", "pdesc": "", "desc": "已修改描述"},
	    "data": {"ot": 3, "setcode": 0, "type": 17, "atk": 3000, "def": 2500,
	             "level": 8, "race": 8192, "attribute": 16}
	  }
	})JSON");
	const auto json_changed = repository.initialize(paths_for(fixture));
	assert(json_changed.ok);
	assert(json_changed.cache_state == ygo::CacheState::Rebuilt);
	assert(json_changed.database->find(89631139)->display.description == "已修改描述");

	fixture.touch("images/123.webp");
	const auto images_changed = repository.initialize(paths_for(fixture));
	assert(images_changed.ok);
	assert(images_changed.cache_state == ygo::CacheState::Rebuilt);
}

void test_corrupt_cache_is_rebuilt_with_warning() {
	ygo::test::TemporaryDirectory fixture;
	write_fixture(fixture);
	ygo::CardRepository repository;
	const auto paths = paths_for(fixture);
	assert(repository.initialize(paths).ok);
	fixture.write_text(".cache/cards/card_database.bin", "损坏");

	const auto recovered = repository.initialize(paths);
	assert(recovered.ok);
	assert(recovered.cache_state == ygo::CacheState::Rebuilt);
	assert(!recovered.warnings.empty());
	assert(recovered.database->find(89631139) != nullptr);
}

void test_missing_sources_return_chinese_errors() {
	ygo::test::TemporaryDirectory fixture;
	ygo::CardRepository repository;
	const auto missing_json = repository.initialize(paths_for(fixture));
	assert(!missing_json.ok);
	assert(missing_json.message.find("JSON") != std::string::npos);

	fixture.write_text("data/cards.json", "{}");
	const auto missing_images = repository.initialize(paths_for(fixture));
	assert(!missing_images.ok);
	assert(missing_images.message.find("卡图目录") != std::string::npos);
}

void test_full_assets_without_writing_project_cache() {
	const char *root = std::getenv("YGO_TEST_ASSET_ROOT");
	if (root == nullptr) {
		return;
	}
	ygo::test::TemporaryDirectory cache;
	ygo::CardRepository repository;
	const ygo::CardRepositoryPaths paths{
		std::filesystem::path(root) / "data/cards.json",
		std::filesystem::path(root) / "images",
		cache.path("card_database.bin"),
	};
	const auto first = repository.initialize(paths);
	const auto second = repository.initialize(paths);
	assert(first.ok && second.ok);
	assert(first.cache_state == ygo::CacheState::Rebuilt);
	assert(second.cache_state == ygo::CacheState::Hit);
	assert(second.database->size() == 14110);
}

} // namespace

int main() {
	test_rebuilds_then_hits_cache();
	test_source_changes_force_rebuild();
	test_corrupt_cache_is_rebuilt_with_warning();
	test_missing_sources_return_chinese_errors();
	test_full_assets_without_writing_project_cache();
}
