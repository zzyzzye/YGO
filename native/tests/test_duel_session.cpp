#include "test_support.hpp"
#include "ygo/card_database.hpp"
#include "ygo/card_repository.hpp"
#include "ygo/duel_session.hpp"
#include "ygo/official_script_loader.hpp"

#include <cassert>
#include <cstdlib>
#include <filesystem>
#include <map>
#include <memory>

namespace {

std::shared_ptr<ygo::CardDatabase> create_database() {
	ygo::CardRecord record;
	record.display.cid = 4007;
	record.display.cn_name = "青眼白龙";
	record.rule.code = 89631139;
	record.rule.type = 17;
	record.rule.level = 8;
	record.rule.attack = 3000;
	record.rule.defense = 2500;

	std::map<std::uint32_t, ygo::CardRecord> records;
	records.emplace(record.rule.code, std::move(record));
	return ygo::CardDatabase::from_records(std::move(records), {});
}

void test_real_callbacks_create_and_destroy_duel() {
	ygo::test::TemporaryDirectory fixture;
	fixture.write_text("scripts/constant.lua", "");
	fixture.write_text("scripts/utility.lua", "");
	fixture.touch("scripts/official/.keep");

	auto scripts = std::make_shared<ygo::OfficialScriptLoader>(
			fixture.path("scripts"));
	ygo::DuelSession session(create_database(), scripts);
	assert(!session.is_active());

	const auto result = session.create(0x59474fULL);
	assert(result.ok);
	assert(result.message == "决斗创建成功");
	assert(session.is_active());

	const auto duplicate = session.create(0x59474fULL);
	assert(!duplicate.ok);
	assert(duplicate.message.find("已经存在") != std::string::npos);

	session.destroy();
	assert(!session.is_active());
	session.destroy();
	assert(!session.is_active());
}

void test_full_local_assets_when_requested() {
	const char *asset_root = std::getenv("YGO_TEST_ASSET_ROOT");
	const char *script_root = std::getenv("YGO_TEST_SCRIPT_ROOT");
	if (asset_root == nullptr || script_root == nullptr) {
		return;
	}

	ygo::test::TemporaryDirectory cache;
	ygo::CardRepository repository;
	const auto initialized = repository.initialize({
		std::filesystem::path(asset_root) / "data/cards.json",
		std::filesystem::path(asset_root) / "images",
		cache.path("card_database.bin"),
	});
	assert(initialized.ok);

	auto scripts = std::make_shared<ygo::OfficialScriptLoader>(script_root);
	ygo::DuelSession session(initialized.database, scripts);
	const auto created = session.create(0x59474fULL);
	assert(created.ok);
	session.destroy();
}

} // namespace

int main() {
	const auto [major, minor] = ygo::DuelSession::core_version();
	assert(major >= 0);
	assert(minor >= 0);
	test_real_callbacks_create_and_destroy_duel();
	test_full_local_assets_when_requested();
}
