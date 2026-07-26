#include "ygo/card_repository.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr std::uint64_t FNV_OFFSET = 14695981039346656037ULL;
constexpr std::uint64_t FNV_PRIME = 1099511628211ULL;

void hash_byte(std::uint64_t &hash, std::uint8_t byte) {
	hash ^= byte;
	hash *= FNV_PRIME;
}

void hash_u64(std::uint64_t &hash, std::uint64_t value) {
	for (unsigned int shift = 0; shift < 64; shift += 8) {
		hash_byte(hash, static_cast<std::uint8_t>((value >> shift) & 0xffU));
	}
}

std::optional<std::uint64_t> hash_file(
		const std::filesystem::path &path,
		std::string &error_message) {
	std::ifstream input(path, std::ios::binary);
	if (!input) {
		error_message = "无法读取卡片 JSON：" + path.string();
		return std::nullopt;
	}
	std::uint64_t hash = FNV_OFFSET;
	std::array<char, 64 * 1024> buffer{};
	while (input) {
		input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
		const auto count = input.gcount();
		for (std::streamsize index = 0; index < count; ++index) {
			hash_byte(hash, static_cast<std::uint8_t>(buffer[index]));
		}
	}
	if (!input.eof()) {
		error_message = "读取卡片 JSON 时发生错误：" + path.string();
		return std::nullopt;
	}
	return hash;
}

std::optional<std::uint64_t> hash_image_list(
		const std::filesystem::path &directory,
		std::string &error_message) {
	if (!std::filesystem::is_directory(directory)) {
		error_message = "卡图目录不存在：" + directory.string();
		return std::nullopt;
	}

	std::vector<std::pair<std::string, std::uint64_t>> images;
	std::error_code error;
	for (const auto &entry : std::filesystem::directory_iterator(directory, error)) {
		if (error) {
			error_message = "读取卡图目录失败：" + error.message();
			return std::nullopt;
		}
		const auto name = entry.path().filename().string();
		if (name.rfind("._", 0) == 0 || entry.path().extension() != ".webp"
				|| !entry.is_regular_file()) {
			continue;
		}
		const auto size = entry.file_size(error);
		if (error) {
			error_message = "读取卡图大小失败：" + entry.path().string();
			return std::nullopt;
		}
		images.emplace_back(name, size);
	}
	std::sort(images.begin(), images.end());

	// 文件名后散列零分隔符，再以固定小端序散列文件大小，避免
	// ["12", "3"] 与 ["1", "23"] 一类边界组合产生相同字节流。
	std::uint64_t hash = FNV_OFFSET;
	for (const auto &[name, size] : images) {
		for (const unsigned char byte : name) {
			hash_byte(hash, byte);
		}
		hash_byte(hash, 0);
		hash_u64(hash, size);
	}
	return hash;
}

std::optional<ygo::CardSourceFingerprint> calculate_fingerprint(
		const ygo::CardRepositoryPaths &paths,
		std::string &error_message) {
	const auto json_hash = hash_file(paths.cards_json, error_message);
	if (!json_hash) {
		return std::nullopt;
	}
	const auto image_hash = hash_image_list(paths.images_directory, error_message);
	if (!image_hash) {
		return std::nullopt;
	}
	return ygo::CardSourceFingerprint{*json_hash, *image_hash};
}

} // namespace

namespace ygo {

RepositoryInitResult CardRepository::initialize(
		const CardRepositoryPaths &paths) const {
	RepositoryInitResult result;
	const auto fingerprint = calculate_fingerprint(paths, result.message);
	if (!fingerprint) {
		return result;
	}

	const bool cache_existed = std::filesystem::is_regular_file(paths.cache_file);
	const auto cached = CardCache::read(paths.cache_file, *fingerprint);
	if (cached.ok) {
		result.ok = true;
		result.cache_state = CacheState::Hit;
		result.message = "卡片缓存命中";
		result.database = cached.database;
		result.stats = cached.database->stats();
		return result;
	}
	if (cache_existed) {
		result.warnings.push_back("现有卡片缓存不可用，将自动重建：" + cached.message);
	}

	const auto loaded = CardDatabase::load_json_intersection(
			paths.cards_json, paths.images_directory);
	if (!loaded.ok) {
		result.message = loaded.message;
		return result;
	}
	const auto written = CardCache::write_atomic(
			paths.cache_file, *loaded.database, *fingerprint);
	if (!written.ok) {
		result.message = written.message;
		return result;
	}

	result.ok = true;
	result.cache_state = CacheState::Rebuilt;
	result.message = "卡片缓存已重建";
	result.database = loaded.database;
	result.stats = loaded.stats;
	return result;
}

} // namespace ygo
