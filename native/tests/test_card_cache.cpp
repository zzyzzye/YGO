#include "test_support.hpp"
#include "ygo/card_cache.hpp"
#include "ygo/card_database.hpp"

#include <cassert>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <vector>

namespace {

std::shared_ptr<ygo::CardDatabase> create_database(
		const ygo::test::TemporaryDirectory &fixture) {
	fixture.write_text("cards.json", R"JSON({
	  "4007": {
	    "cid": 4007, "id": 89631139, "cn_name": "青眼白龙",
	    "text": {"types": "[怪兽|通常]", "pdesc": "", "desc": "传说中的龙。"},
	    "data": {"ot": 3, "setcode": 4339, "type": 17, "atk": 3000, "def": 2500,
	             "level": 8, "race": 8192, "attribute": 16}
	  }
	})JSON");
	fixture.touch("images/89631139.webp");
	const auto loaded = ygo::CardDatabase::load_json_intersection(
			fixture.path("cards.json"), fixture.path("images"));
	assert(loaded.ok);
	return loaded.database;
}

std::vector<std::uint8_t> read_bytes(const std::filesystem::path &path) {
	std::ifstream input(path, std::ios::binary);
	return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}

void write_bytes(
		const std::filesystem::path &path,
		const std::vector<std::uint8_t> &bytes) {
	std::ofstream output(path, std::ios::binary | std::ios::trunc);
	output.write(
			reinterpret_cast<const char *>(bytes.data()),
			static_cast<std::streamsize>(bytes.size()));
}

void test_round_trip_preserves_records_and_stats() {
	ygo::test::TemporaryDirectory fixture;
	const auto database = create_database(fixture);
	const ygo::CardSourceFingerprint fingerprint{
		0x1122334455667788ULL,
		0x8877665544332211ULL,
	};
	const auto cache_path = fixture.path("cache/cards.bin");

	const auto written = ygo::CardCache::write_atomic(
			cache_path, *database, fingerprint);
	assert(written.ok);

	const auto read = ygo::CardCache::read(cache_path, fingerprint);
	assert(read.ok);
	assert(read.database != nullptr);
	assert(read.database->size() == 1);
	assert(read.database->stats().json_records == 1);
	const auto *card = read.database->find(89631139);
	assert(card != nullptr);
	assert(card->display.cn_name == "青眼白龙");
	assert(card->display.description == "传说中的龙。");
	assert(card->rule.attack == 3000);
	assert(card->rule.setcodes.size() == 1);
	assert(card->rule.setcodes.front() == 0x10f3);
}

void test_rejects_changed_fingerprint() {
	ygo::test::TemporaryDirectory fixture;
	const auto database = create_database(fixture);
	const ygo::CardSourceFingerprint original{1, 2};
	const auto cache_path = fixture.path("cards.bin");
	assert(ygo::CardCache::write_atomic(cache_path, *database, original).ok);

	const auto changed_json = ygo::CardCache::read(cache_path, {3, 2});
	assert(!changed_json.ok);
	assert(changed_json.message.find("指纹") != std::string::npos);

	const auto changed_images = ygo::CardCache::read(cache_path, {1, 4});
	assert(!changed_images.ok);
	assert(changed_images.message.find("指纹") != std::string::npos);
}

void test_rejects_truncated_and_invalid_header() {
	ygo::test::TemporaryDirectory fixture;
	const auto database = create_database(fixture);
	const ygo::CardSourceFingerprint fingerprint{1, 2};
	const auto cache_path = fixture.path("cards.bin");
	assert(ygo::CardCache::write_atomic(cache_path, *database, fingerprint).ok);

	auto bytes = read_bytes(cache_path);
	bytes.resize(8);
	write_bytes(cache_path, bytes);
	const auto truncated = ygo::CardCache::read(cache_path, fingerprint);
	assert(!truncated.ok);
	assert(truncated.message.find("损坏") != std::string::npos);

	assert(ygo::CardCache::write_atomic(cache_path, *database, fingerprint).ok);
	bytes = read_bytes(cache_path);
	bytes[0] = 'X';
	write_bytes(cache_path, bytes);
	const auto invalid_magic = ygo::CardCache::read(cache_path, fingerprint);
	assert(!invalid_magic.ok);
	assert(invalid_magic.message.find("魔数") != std::string::npos);

	assert(ygo::CardCache::write_atomic(cache_path, *database, fingerprint).ok);
	bytes = read_bytes(cache_path);
	bytes[8] = 2;
	write_bytes(cache_path, bytes);
	const auto invalid_version = ygo::CardCache::read(cache_path, fingerprint);
	assert(!invalid_version.ok);
	assert(invalid_version.message.find("版本") != std::string::npos);

	assert(ygo::CardCache::write_atomic(cache_path, *database, fingerprint).ok);
	bytes = read_bytes(cache_path);
	// 44 字节文件头和 4 字节 cid 之后是第一段字符串的长度。把它改为
	// 0xffffffff，验证读取器会在分配内存前拒绝恶意长度。
	bytes[48] = 0xff;
	bytes[49] = 0xff;
	bytes[50] = 0xff;
	bytes[51] = 0xff;
	write_bytes(cache_path, bytes);
	const auto invalid_length = ygo::CardCache::read(cache_path, fingerprint);
	assert(!invalid_length.ok);
	assert(invalid_length.message.find("损坏") != std::string::npos);
}

} // namespace

int main() {
	test_round_trip_preserves_records_and_stats();
	test_rejects_changed_fingerprint();
	test_rejects_truncated_and_invalid_header();
}
