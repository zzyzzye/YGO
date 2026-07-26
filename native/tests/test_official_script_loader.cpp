#include "test_support.hpp"
#include "ygo/official_script_loader.hpp"

#include <cassert>
#include <cstdlib>
#include <filesystem>

namespace {

void test_reads_only_root_helpers_and_official_card_scripts() {
	ygo::test::TemporaryDirectory fixture;
	fixture.write_text("scripts/constant.lua", "CONST");
	fixture.write_text("scripts/utility.lua", "UTILITY");
	fixture.write_text("scripts/proc_link.lua", "LINK");
	fixture.write_text("scripts/official/c89631139.lua", "BLUE_EYES");
	fixture.write_text("scripts/unofficial/c1.lua", "FORBIDDEN");

	ygo::OfficialScriptLoader loader(fixture.path("scripts"));
	assert(loader.validate().ok);
	assert(loader.read_requested("constant.lua").bytes == "CONST");
	assert(loader.read_requested("proc_link.lua").bytes == "LINK");
	assert(loader.read_requested("c89631139.lua").bytes == "BLUE_EYES");

	for (const char *request : {
				"../constant.lua",
				"/tmp/c1.lua",
				"unofficial/c1.lua",
				"official/../unofficial/c1.lua",
				"c1.lua/extra",
			}) {
		const auto rejected = loader.read_requested(request);
		assert(!rejected.ok);
		assert(rejected.message.find("拒绝") != std::string::npos);
	}

	const auto missing_safe_root_script = loader.read_requested("cabc.lua");
	assert(!missing_safe_root_script.ok);
	assert(missing_safe_root_script.message.find("无法读取") != std::string::npos);
}

void test_reports_missing_required_scripts_in_chinese() {
	ygo::test::TemporaryDirectory fixture;
	fixture.write_text("scripts/constant.lua", "");
	ygo::OfficialScriptLoader loader(fixture.path("scripts"));
	const auto result = loader.validate();
	assert(!result.ok);
	assert(result.message.find("utility.lua") != std::string::npos);
}

void test_real_script_root_when_requested() {
	const char *root = std::getenv("YGO_TEST_SCRIPT_ROOT");
	if (root == nullptr) {
		return;
	}
	ygo::OfficialScriptLoader loader(root);
	assert(loader.validate().ok);
	assert(loader.read_requested("constant.lua").ok);
	assert(loader.read_requested("utility.lua").ok);
	assert(loader.read_requested("c3113836.lua").ok);
}

} // namespace

int main() {
	test_reads_only_root_helpers_and_official_card_scripts();
	test_reports_missing_required_scripts_in_chinese();
	test_real_script_root_when_requested();
}
