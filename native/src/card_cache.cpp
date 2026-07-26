#include "ygo/card_cache.hpp"

#include <array>
#include <cstring>
#include <fstream>
#include <limits>
#include <map>
#include <system_error>
#include <utility>
#include <vector>

namespace {

constexpr std::array<std::uint8_t, 8> MAGIC{'Y', 'G', 'O', 'C', 'A', 'R', 'D', '\0'};
constexpr std::uint32_t FORMAT_VERSION = 1;
constexpr std::uint32_t MAX_RECORDS = 100000;
constexpr std::uint32_t MAX_STRING_BYTES = 4U * 1024U * 1024U;
constexpr std::uint32_t MAX_SETCODES = 256;

class BinaryWriter final {
public:
	void write_u16(std::uint16_t value) {
		bytes_.push_back(static_cast<std::uint8_t>(value & 0xffU));
		bytes_.push_back(static_cast<std::uint8_t>((value >> 8U) & 0xffU));
	}

	void write_u32(std::uint32_t value) {
		for (unsigned int shift = 0; shift < 32; shift += 8) {
			bytes_.push_back(static_cast<std::uint8_t>((value >> shift) & 0xffU));
		}
	}

	void write_u64(std::uint64_t value) {
		for (unsigned int shift = 0; shift < 64; shift += 8) {
			bytes_.push_back(static_cast<std::uint8_t>((value >> shift) & 0xffU));
		}
	}

	void write_i32(std::int32_t value) {
		std::uint32_t bits = 0;
		std::memcpy(&bits, &value, sizeof(bits));
		write_u32(bits);
	}

	bool write_string(const std::string &value) {
		if (value.size() > std::numeric_limits<std::uint32_t>::max()) {
			return false;
		}
		write_u32(static_cast<std::uint32_t>(value.size()));
		bytes_.insert(bytes_.end(), value.begin(), value.end());
		return true;
	}

	void write_magic() {
		bytes_.insert(bytes_.end(), MAGIC.begin(), MAGIC.end());
	}

	[[nodiscard]] const std::vector<std::uint8_t> &bytes() const noexcept {
		return bytes_;
	}

private:
	std::vector<std::uint8_t> bytes_;
};

class CheckedReader final {
public:
	explicit CheckedReader(std::vector<std::uint8_t> bytes) :
			bytes_(std::move(bytes)) {
	}

	bool read_magic() {
		if (!has(MAGIC.size())) {
			return false;
		}
		const bool matches = std::equal(
				MAGIC.begin(), MAGIC.end(), bytes_.begin() + position_);
		position_ += MAGIC.size();
		return matches;
	}

	bool read_u16(std::uint16_t &value) {
		if (!has(2)) {
			return false;
		}
		value = static_cast<std::uint16_t>(bytes_[position_])
				| static_cast<std::uint16_t>(bytes_[position_ + 1]) << 8U;
		position_ += 2;
		return true;
	}

	bool read_u32(std::uint32_t &value) {
		if (!has(4)) {
			return false;
		}
		value = 0;
		for (unsigned int shift = 0; shift < 32; shift += 8) {
			value |= static_cast<std::uint32_t>(bytes_[position_++]) << shift;
		}
		return true;
	}

	bool read_u64(std::uint64_t &value) {
		if (!has(8)) {
			return false;
		}
		value = 0;
		for (unsigned int shift = 0; shift < 64; shift += 8) {
			value |= static_cast<std::uint64_t>(bytes_[position_++]) << shift;
		}
		return true;
	}

	bool read_i32(std::int32_t &value) {
		std::uint32_t bits = 0;
		if (!read_u32(bits)) {
			return false;
		}
		std::memcpy(&value, &bits, sizeof(value));
		return true;
	}

	bool read_string(std::string &value) {
		std::uint32_t length = 0;
		if (!read_u32(length) || length > MAX_STRING_BYTES || !has(length)) {
			return false;
		}
		value.assign(
				reinterpret_cast<const char *>(bytes_.data() + position_),
				length);
		position_ += length;
		return true;
	}

	[[nodiscard]] bool finished() const noexcept {
		return position_ == bytes_.size();
	}

private:
	[[nodiscard]] bool has(std::size_t count) const noexcept {
		return count <= bytes_.size() - position_;
	}

	std::vector<std::uint8_t> bytes_;
	std::size_t position_ = 0;
};

bool write_record(BinaryWriter &writer, const ygo::CardRecord &record) {
	writer.write_u32(record.display.cid);
	if (!writer.write_string(record.display.cn_name)
			|| !writer.write_string(record.display.types_text)
			|| !writer.write_string(record.display.pendulum_description)
			|| !writer.write_string(record.display.description)
			|| !writer.write_string(record.display.image_relative_path)) {
		return false;
	}

	writer.write_u32(record.rule.code);
	writer.write_u32(record.rule.alias);
	writer.write_u32(record.rule.type);
	writer.write_u32(record.rule.level);
	writer.write_u32(record.rule.attribute);
	writer.write_u64(record.rule.race);
	writer.write_i32(record.rule.attack);
	writer.write_i32(record.rule.defense);
	writer.write_u32(record.rule.left_scale);
	writer.write_u32(record.rule.right_scale);
	writer.write_u32(record.rule.link_marker);
	if (record.rule.setcodes.size() > MAX_SETCODES) {
		return false;
	}
	writer.write_u32(static_cast<std::uint32_t>(record.rule.setcodes.size()));
	for (const auto setcode : record.rule.setcodes) {
		writer.write_u16(setcode);
	}
	return true;
}

bool read_record(CheckedReader &reader, ygo::CardRecord &record) {
	std::uint32_t setcode_count = 0;
	if (!reader.read_u32(record.display.cid)
			|| !reader.read_string(record.display.cn_name)
			|| !reader.read_string(record.display.types_text)
			|| !reader.read_string(record.display.pendulum_description)
			|| !reader.read_string(record.display.description)
			|| !reader.read_string(record.display.image_relative_path)
			|| !reader.read_u32(record.rule.code)
			|| !reader.read_u32(record.rule.alias)
			|| !reader.read_u32(record.rule.type)
			|| !reader.read_u32(record.rule.level)
			|| !reader.read_u32(record.rule.attribute)
			|| !reader.read_u64(record.rule.race)
			|| !reader.read_i32(record.rule.attack)
			|| !reader.read_i32(record.rule.defense)
			|| !reader.read_u32(record.rule.left_scale)
			|| !reader.read_u32(record.rule.right_scale)
			|| !reader.read_u32(record.rule.link_marker)
			|| !reader.read_u32(setcode_count)
			|| setcode_count > MAX_SETCODES) {
		return false;
	}
	record.rule.setcodes.reserve(setcode_count);
	for (std::uint32_t index = 0; index < setcode_count; ++index) {
		std::uint16_t setcode = 0;
		if (!reader.read_u16(setcode)) {
			return false;
		}
		record.rule.setcodes.push_back(setcode);
	}
	return true;
}

std::vector<std::uint8_t> read_file(const std::filesystem::path &path) {
	std::ifstream input(path, std::ios::binary);
	if (!input) {
		return {};
	}
	return {
		std::istreambuf_iterator<char>(input),
		std::istreambuf_iterator<char>(),
	};
}

} // namespace

namespace ygo {

CacheWriteResult CardCache::write_atomic(
		const std::filesystem::path &cache_path,
		const CardDatabase &database,
		CardSourceFingerprint fingerprint) {
	if (database.size() > MAX_RECORDS) {
		return {false, "卡片数量超过缓存格式允许的上限"};
	}
	BinaryWriter writer;
	writer.write_magic();
	writer.write_u32(FORMAT_VERSION);
	writer.write_u64(fingerprint.json_hash);
	writer.write_u64(fingerprint.image_list_hash);
	writer.write_u32(static_cast<std::uint32_t>(database.size()));
	writer.write_u32(static_cast<std::uint32_t>(database.stats().json_records));
	writer.write_u32(static_cast<std::uint32_t>(database.stats().invalid_records));
	writer.write_u32(static_cast<std::uint32_t>(database.stats().missing_image_records));
	for (const auto &[id, record] : database.records()) {
		if (id != record.rule.code || !write_record(writer, record)) {
			return {false, "卡片数据无法编码到缓存"};
		}
	}

	std::error_code error;
	std::filesystem::create_directories(cache_path.parent_path(), error);
	if (error) {
		return {false, "无法创建卡片缓存目录：" + error.message()};
	}

	// 临时文件与目标缓存位于同一目录，rename 才能保持同一文件系统内的
	// 原子替换语义，避免程序中断后留下看似有效的半个缓存文件。
	const auto temporary_path = cache_path.string() + ".tmp";
	{
		std::ofstream output(temporary_path, std::ios::binary | std::ios::trunc);
		if (!output) {
			return {false, "无法创建卡片缓存临时文件"};
		}
		const auto &bytes = writer.bytes();
		output.write(
				reinterpret_cast<const char *>(bytes.data()),
				static_cast<std::streamsize>(bytes.size()));
		output.flush();
		if (!output) {
			std::filesystem::remove(temporary_path, error);
			return {false, "卡片缓存临时文件写入不完整"};
		}
	}

	std::filesystem::rename(temporary_path, cache_path, error);
	if (error) {
		const auto rename_message = error.message();
		std::error_code cleanup_error;
		std::filesystem::remove(temporary_path, cleanup_error);
		return {false, "无法替换卡片缓存文件：" + rename_message};
	}
	return {true, "卡片缓存写入成功"};
}

CacheReadResult CardCache::read(
		const std::filesystem::path &cache_path,
		CardSourceFingerprint expected_fingerprint) {
	auto bytes = read_file(cache_path);
	if (bytes.empty()) {
		return {false, "卡片缓存不存在或为空", nullptr};
	}
	CheckedReader reader(std::move(bytes));
	if (!reader.read_magic()) {
		return {false, "卡片缓存魔数无效", nullptr};
	}

	std::uint32_t version = 0;
	CardSourceFingerprint actual;
	std::uint32_t record_count = 0;
	std::uint32_t json_records = 0;
	std::uint32_t invalid_records = 0;
	std::uint32_t missing_image_records = 0;
	if (!reader.read_u32(version)
			|| !reader.read_u64(actual.json_hash)
			|| !reader.read_u64(actual.image_list_hash)
			|| !reader.read_u32(record_count)
			|| !reader.read_u32(json_records)
			|| !reader.read_u32(invalid_records)
			|| !reader.read_u32(missing_image_records)) {
		return {false, "卡片缓存已损坏：文件头不完整", nullptr};
	}
	if (version != FORMAT_VERSION) {
		return {false, "卡片缓存格式版本不兼容", nullptr};
	}
	if (!(actual == expected_fingerprint)) {
		return {false, "卡片缓存数据源指纹已变化", nullptr};
	}
	if (record_count > MAX_RECORDS) {
		return {false, "卡片缓存已损坏：记录数量超出限制", nullptr};
	}

	std::map<std::uint32_t, CardRecord> records;
	for (std::uint32_t index = 0; index < record_count; ++index) {
		CardRecord record;
		if (!read_record(reader, record)) {
			return {false, "卡片缓存已损坏：卡片记录不完整", nullptr};
		}
		const auto [iterator, inserted] = records.emplace(record.rule.code, std::move(record));
		if (!inserted) {
			return {false, "卡片缓存已损坏：存在重复规则卡号", nullptr};
		}
	}
	if (!reader.finished()) {
		return {false, "卡片缓存已损坏：文件末尾存在多余数据", nullptr};
	}

	CardDatabaseStats stats;
	stats.json_records = json_records;
	stats.accepted_records = record_count;
	stats.invalid_records = invalid_records;
	stats.missing_image_records = missing_image_records;
	return {
		true,
		"卡片缓存读取成功",
		CardDatabase::from_records(std::move(records), stats),
	};
}

} // namespace ygo
