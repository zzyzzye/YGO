#include "test_support.hpp"
#include "ygo/card_database.hpp"

#include <cassert>
#include <cstdlib>
#include <filesystem>

namespace {

void test_loads_only_valid_records_with_images() {
	ygo::test::TemporaryDirectory fixture;
	fixture.write_text("cards.json", R"JSON({
	  "4007": {
	    "cid": 4007,
	    "id": 89631139,
	    "cn_name": "青眼白龙",
	    "text": {"types": "[怪兽|通常]", "pdesc": "", "desc": "传说中的龙。"},
	    "data": {"ot": 3, "setcode": 0, "type": 17, "atk": 3000, "def": 2500,
	             "level": 8, "race": 8192, "attribute": 16}
	  },
	  "link": {
	    "cid": 13085,
	    "id": 41999284,
	    "cn_name": "解码语者",
	    "text": {"types": "[怪兽|效果|连接]", "pdesc": "", "desc": "测试文本"},
	    "data": {"ot": 3, "setcode": 0, "type": 67108897, "atk": 2300, "def": 42,
	             "level": 3, "race": 16777216, "attribute": 32}
	  },
	  "pendulum": {
	    "cid": 12000,
	    "id": 16178681,
	    "cn_name": "灵摆测试卡",
	    "text": {"types": "[怪兽|效果|灵摆]", "pdesc": "灵摆描述", "desc": "怪兽描述"},
	    "data": {"ot": 3, "setcode": 19992819, "type": 16777249,
	             "atk": -2, "def": 1000, "level": 84017156,
	             "race": 1, "attribute": 4}
	  },
	  "invalid": {"cid": 999, "id": 0, "cn_name": "无效记录", "data": {}},
	  "missing_image": {
	    "cid": 5000,
	    "id": 12345678,
	    "cn_name": "缺图测试卡",
	    "text": {"types": "", "pdesc": "", "desc": ""},
	    "data": {"ot": 3, "setcode": 0, "type": 17, "atk": 0, "def": 0,
	             "level": 1, "race": 1, "attribute": 1}
	  }
	})JSON");
	fixture.touch("images/89631139.webp");
	fixture.touch("images/41999284.webp");
	fixture.touch("images/16178681.webp");

	const auto result = ygo::CardDatabase::load_json_intersection(
			fixture.path("cards.json"), fixture.path("images"));
	assert(result.ok);
	assert(result.database != nullptr);
	assert(result.database->size() == 3);
	assert(result.stats.json_records == 5);
	assert(result.stats.accepted_records == 3);
	assert(result.stats.invalid_records == 1);
	assert(result.stats.missing_image_records == 1);

	const auto *blue_eyes = result.database->find(89631139);
	assert(blue_eyes != nullptr);
	assert(blue_eyes->display.cid == 4007);
	assert(blue_eyes->display.cn_name == "青眼白龙");
	assert(blue_eyes->display.image_relative_path == "images/89631139.webp");
	assert(blue_eyes->rule.level == 8);
	assert(blue_eyes->rule.attack == 3000);

	const auto *decode_talker = result.database->find(41999284);
	assert(decode_talker != nullptr);
	assert(decode_talker->rule.defense == 0);
	assert(decode_talker->rule.link_marker == 42);

	const auto *pendulum = result.database->find(16178681);
	assert(pendulum != nullptr);
	assert(pendulum->rule.level == 4);
	assert(pendulum->rule.left_scale == 5);
	assert(pendulum->rule.right_scale == 2);
	assert(pendulum->rule.setcodes.size() == 2);
	assert(pendulum->rule.setcodes[0] == 0x10f3);
	assert(pendulum->rule.setcodes[1] == 0x0131);

	assert(result.database->find(12345678) == nullptr);
}

void test_rejects_malformed_json_with_chinese_error() {
	ygo::test::TemporaryDirectory fixture;
	fixture.write_text("cards.json", "{");
	std::filesystem::create_directories(fixture.path("images"));

	const auto result = ygo::CardDatabase::load_json_intersection(
			fixture.path("cards.json"), fixture.path("images"));
	assert(!result.ok);
	assert(result.message.find("解析") != std::string::npos);
}

void test_rejects_duplicate_rule_ids() {
	ygo::test::TemporaryDirectory fixture;
	fixture.write_text("cards.json", R"JSON({
	  "first": {
	    "cid": 1, "id": 89631139, "cn_name": "第一条",
	    "text": {"types": "", "pdesc": "", "desc": ""},
	    "data": {"ot": 3, "setcode": 0, "type": 17, "atk": 3000, "def": 2500,
	             "level": 8, "race": 8192, "attribute": 16}
	  },
	  "second": {
	    "cid": 2, "id": 89631139, "cn_name": "第二条",
	    "text": {"types": "", "pdesc": "", "desc": ""},
	    "data": {"ot": 3, "setcode": 0, "type": 17, "atk": 3000, "def": 2500,
	             "level": 8, "race": 8192, "attribute": 16}
	  }
	})JSON");
	fixture.touch("images/89631139.webp");

	const auto result = ygo::CardDatabase::load_json_intersection(
			fixture.path("cards.json"), fixture.path("images"));
	assert(!result.ok);
	assert(result.message.find("重复规则卡号") != std::string::npos);
}

void test_full_local_assets_when_requested() {
	const char *root = std::getenv("YGO_TEST_ASSET_ROOT");
	if (root == nullptr) {
		return;
	}

	const auto result = ygo::CardDatabase::load_json_intersection(
			std::filesystem::path(root) / "data/cards.json",
			std::filesystem::path(root) / "images");
	assert(result.ok);
	assert(result.database->size() == 14110);
	assert(result.stats.invalid_records == 42);
	assert(result.stats.missing_image_records == 96);
	assert(result.database->find(89631139)->display.cn_name == "青眼白龙");
}

} // namespace

int main() {
	test_loads_only_valid_records_with_images();
	test_rejects_malformed_json_with_chinese_error();
	test_rejects_duplicate_rule_ids();
	test_full_local_assets_when_requested();
}
