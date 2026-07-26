#pragma once

#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>
#include <string_view>

#include <chrono>

namespace ygo::test {

class TemporaryDirectory final {
public:
	TemporaryDirectory() {
		// create_directory 只有在候选路径尚不存在时才成功，因此循环能够
		// 原子取得当前测试专属的目录。析构函数只清理这个已确认创建成功
		// 的路径，避免测试误删用户目录。
		const auto seed = std::chrono::steady_clock::now().time_since_epoch().count();
		for (int attempt = 0; attempt < 100; ++attempt) {
			const auto name = "ygo-native-test-" + std::to_string(seed) + "-"
					+ std::to_string(attempt);
			root_ = std::filesystem::temp_directory_path() / name;
			std::error_code error;
			if (std::filesystem::create_directory(root_, error)) {
				return;
			}
		}
		throw std::runtime_error("无法创建测试临时目录");
	}

	~TemporaryDirectory() {
		std::error_code error;
		std::filesystem::remove_all(root_, error);
	}

	TemporaryDirectory(const TemporaryDirectory &) = delete;
	TemporaryDirectory &operator=(const TemporaryDirectory &) = delete;

	[[nodiscard]] std::filesystem::path path(std::string_view relative = {}) const {
		return relative.empty() ? root_ : root_ / relative;
	}

	void write_text(std::string_view relative, std::string_view contents) const {
		const auto target = path(relative);
		std::filesystem::create_directories(target.parent_path());
		std::ofstream output(target, std::ios::binary);
		if (!output) {
			throw std::runtime_error("无法写入测试文件");
		}
		output.write(contents.data(), static_cast<std::streamsize>(contents.size()));
		if (!output) {
			throw std::runtime_error("测试文件写入不完整");
		}
	}

	void touch(std::string_view relative) const {
		write_text(relative, "");
	}

private:
	std::filesystem::path root_;
};

} // namespace ygo::test
