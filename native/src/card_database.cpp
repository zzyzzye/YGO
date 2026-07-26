#include "ygo/card_database.hpp"

#include <nlohmann/json.hpp>

#include <fstream>
#include <optional>
#include <sstream>
#include <utility>

namespace {

constexpr std::uint32_t TYPE_LINK = 0x04000000U;

template <typename T>
std::optional<T> required_number(const nlohmann::json &object, const char *key) {
	const auto iterator = object.find(key);
	if (iterator == object.end() || !iterator->is_number_integer()) {
		return std::nullopt;
	}
	try {
		return iterator->get<T>();
	} catch (const nlohmann::json::exception &) {
		return std::nullopt;
	}
}

std::string optional_string(
		const nlohmann::json &object,
		const char *key) {
	const auto iterator = object.find(key);
	if (iterator == object.end() || !iterator->is_string()) {
		return {};
	}
	return iterator->get<std::string>();
}

std::vector<std::uint16_t> split_setcodes(std::uint64_t packed) {
	std::vector<std::uint16_t> result;
	while (packed != 0) {
		const auto value = static_cast<std::uint16_t>(packed & 0xffffU);
		if (value != 0) {
			result.push_back(value);
		}
		packed >>= 16U;
	}
	return result;
}

std::optional<ygo::CardRecord> parse_record(
		const nlohmann::json &source,
		const std::filesystem::path &images_directory,
		ygo::CardDatabaseStats &stats) {
	if (!source.is_object()) {
		++stats.invalid_records;
		return std::nullopt;
	}

	const auto id = required_number<std::uint32_t>(source, "id");
	const auto cid = required_number<std::uint32_t>(source, "cid");
	const auto name = optional_string(source, "cn_name");
	const auto data_iterator = source.find("data");
	const auto text_iterator = source.find("text");
	if (!id || *id == 0 || !cid || name.empty()
			|| data_iterator == source.end() || !data_iterator->is_object()) {
		++stats.invalid_records;
		return std::nullopt;
	}

	const auto &data = *data_iterator;
	const auto type = required_number<std::uint32_t>(data, "type");
	const auto attack = required_number<std::int32_t>(data, "atk");
	const auto defense = required_number<std::int32_t>(data, "def");
	const auto packed_level = required_number<std::uint32_t>(data, "level");
	const auto race = required_number<std::uint64_t>(data, "race");
	const auto attribute = required_number<std::uint32_t>(data, "attribute");
	const auto setcode = required_number<std::uint64_t>(data, "setcode");
	if (!type || !attack || !defense || !packed_level || !race || !attribute || !setcode) {
		++stats.invalid_records;
		return std::nullopt;
	}

	const auto image_name = std::to_string(*id) + ".webp";
	if (!std::filesystem::is_regular_file(images_directory / image_name)) {
		++stats.missing_image_records;
		return std::nullopt;
	}

	ygo::CardRecord record;
	record.display.cid = *cid;
	record.display.cn_name = name;
	record.display.image_relative_path = "images/" + image_name;
	if (text_iterator != source.end() && text_iterator->is_object()) {
		record.display.types_text = optional_string(*text_iterator, "types");
		record.display.pendulum_description = optional_string(*text_iterator, "pdesc");
		record.display.description = optional_string(*text_iterator, "desc");
	}

	record.rule.code = *id;
	record.rule.type = *type;
	record.rule.level = *packed_level & 0xffU;
	record.rule.right_scale = (*packed_level >> 16U) & 0xffU;
	record.rule.left_scale = (*packed_level >> 24U) & 0xffU;
	record.rule.attribute = *attribute;
	record.rule.race = *race;
	record.rule.attack = *attack;
	record.rule.setcodes = split_setcodes(*setcode);

	// YGOPro 数据库把 Link Marker 复用在 def 字段中。OCGCore 则要求把
	// Marker 和守备力分开放置，因此 Link 怪兽不能沿用普通怪兽的映射。
	if ((*type & TYPE_LINK) != 0) {
		record.rule.defense = 0;
		record.rule.link_marker = static_cast<std::uint32_t>(*defense);
	} else {
		record.rule.defense = *defense;
	}

	return record;
}

} // namespace

namespace ygo {

CardDatabaseLoadResult CardDatabase::load_json_intersection(
		const std::filesystem::path &cards_json,
		const std::filesystem::path &images_directory) {
	CardDatabaseLoadResult result;
	std::ifstream input(cards_json, std::ios::binary);
	if (!input) {
		result.message = "无法读取卡片 JSON：" + cards_json.string();
		return result;
	}
	if (!std::filesystem::is_directory(images_directory)) {
		result.message = "卡图目录不存在：" + images_directory.string();
		return result;
	}

	nlohmann::json document;
	try {
		input >> document;
	} catch (const nlohmann::json::exception &error) {
		result.message = "解析卡片 JSON 失败：" + std::string(error.what());
		return result;
	}
	if (!document.is_object()) {
		result.message = "解析卡片 JSON 失败：根节点必须是对象";
		return result;
	}

	auto database = std::make_shared<CardDatabase>();
	database->stats_.json_records = document.size();
	for (const auto &[source_key, source] : document.items()) {
		auto record = parse_record(source, images_directory, database->stats_);
		if (!record) {
			continue;
		}
		const auto id = record->rule.code;
		const auto [iterator, inserted] = database->records_.emplace(id, std::move(*record));
		if (!inserted) {
			result.message = "卡片 JSON 存在重复规则卡号：" + std::to_string(id)
					+ "（来源键：" + source_key + "）";
			return result;
		}
	}
	database->stats_.accepted_records = database->records_.size();

	result.ok = true;
	result.message = "卡片数据库加载成功";
	result.stats = database->stats_;
	result.database = std::move(database);
	return result;
}

std::shared_ptr<CardDatabase> CardDatabase::from_records(
		std::map<std::uint32_t, CardRecord> records,
		CardDatabaseStats stats) {
	auto database = std::make_shared<CardDatabase>();
	database->records_ = std::move(records);
	database->stats_ = stats;
	database->stats_.accepted_records = database->records_.size();
	return database;
}

const CardRecord *CardDatabase::find(std::uint32_t id) const noexcept {
	const auto iterator = records_.find(id);
	return iterator == records_.end() ? nullptr : &iterator->second;
}

std::size_t CardDatabase::size() const noexcept {
	return records_.size();
}

const CardDatabaseStats &CardDatabase::stats() const noexcept {
	return stats_;
}

const std::map<std::uint32_t, CardRecord> &CardDatabase::records() const noexcept {
	return records_;
}

} // namespace ygo
