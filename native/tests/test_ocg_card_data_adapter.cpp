#include "ygo/ocg_card_data_adapter.hpp"

#include <cassert>
#include <map>
#include <memory>

namespace {

std::shared_ptr<ygo::CardDatabase> database_with_blue_eyes() {
	ygo::CardRecord record;
	record.display.cid = 4007;
	record.display.cn_name = "青眼白龙";
	record.rule.code = 89631139;
	record.rule.type = 17;
	record.rule.level = 8;
	record.rule.attribute = 16;
	record.rule.race = 8192;
	record.rule.attack = 3000;
	record.rule.defense = 2500;
	record.rule.setcodes = {0x10f3};

	std::map<std::uint32_t, ygo::CardRecord> records;
	records.emplace(record.rule.code, std::move(record));
	ygo::CardDatabaseStats stats;
	stats.json_records = 1;
	return ygo::CardDatabase::from_records(std::move(records), stats);
}

void test_adapts_card_and_terminates_setcodes() {
	ygo::OcgCardDataAdapter adapter(database_with_blue_eyes());
	OCG_CardData data{};

	adapter.read(89631139, &data);
	assert(data.code == 89631139);
	assert(data.attack == 3000);
	assert(data.defense == 2500);
	assert(data.level == 8);
	assert(data.setcodes != nullptr);
	assert(data.setcodes[0] == 0x10f3);
	assert(data.setcodes[1] == 0);

	adapter.done(&data);
	assert(data.setcodes == nullptr);
}

void test_missing_card_returns_safe_zero_record() {
	ygo::OcgCardDataAdapter adapter(database_with_blue_eyes());
	OCG_CardData data{};
	data.attack = 123;

	adapter.read(12345678, &data);
	assert(data.code == 12345678);
	assert(data.attack == 0);
	assert(data.setcodes == nullptr);
	adapter.done(&data);
}

} // namespace

int main() {
	test_adapts_card_and_terminates_setcodes();
	test_missing_card_returns_safe_zero_record();
}
