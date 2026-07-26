#include "ygo/duel_session.hpp"

#include "ocgapi.h"

namespace {

void read_card(void *payload, std::uint32_t code, OCG_CardData *data) {
	static_cast<ygo::OcgCardDataAdapter *>(payload)->read(code, data);
}

void finish_reading_card(void *payload, OCG_CardData *data) {
	static_cast<ygo::OcgCardDataAdapter *>(payload)->done(data);
}

int read_script(void *payload, OCG_Duel duel, const char *name) {
	if (name == nullptr) {
		return 0;
	}
	return static_cast<ygo::OfficialScriptLoader *>(payload)
			->load_requested(duel, name);
}

void discard_log(void *, const char *, int) {
}

std::uint64_t next_seed(std::uint64_t &state) {
	state += 0x9e3779b97f4a7c15ULL;
	std::uint64_t value = state;
	value = (value ^ (value >> 30U)) * 0xbf58476d1ce4e5b9ULL;
	value = (value ^ (value >> 27U)) * 0x94d049bb133111ebULL;
	return value ^ (value >> 31U);
}

const char *creation_message(int status) {
	switch (status) {
	case OCG_DUEL_CREATION_SUCCESS:
		return "决斗创建成功";
	case OCG_DUEL_CREATION_NO_OUTPUT:
		return "OCGCore 未返回决斗实例";
	case OCG_DUEL_CREATION_NOT_CREATED:
		return "OCGCore 无法创建决斗";
	case OCG_DUEL_CREATION_NULL_DATA_READER:
		return "缺少卡片数据读取器";
	case OCG_DUEL_CREATION_NULL_SCRIPT_READER:
		return "缺少 Lua 脚本读取器";
	case OCG_DUEL_CREATION_INCOMPATIBLE_LUA_API:
		return "OCGCore 使用的 Lua API 不兼容";
	case OCG_DUEL_CREATION_NULL_RNG_SEED:
		return "缺少 OCGCore 随机数种子";
	default:
		return "未知的 OCGCore 决斗创建状态";
	}
}

} // namespace

namespace ygo {

DuelSession::DuelSession(
		std::shared_ptr<const CardDatabase> database,
		std::shared_ptr<OfficialScriptLoader> scripts) :
		database_(std::move(database)),
		scripts_(std::move(scripts)),
		card_data_adapter_(database_) {
}

DuelSession::~DuelSession() {
	destroy();
}

std::pair<int, int> DuelSession::core_version() {
	int major = 0;
	int minor = 0;
	OCG_GetVersion(&major, &minor);
	return {major, minor};
}

CreateResult DuelSession::create(std::uint64_t seed) {
	if (is_active()) {
		return {false, OCG_DUEL_CREATION_NOT_CREATED, "决斗实例已经存在"};
	}
	if (!database_) {
		return {false, OCG_DUEL_CREATION_NOT_CREATED, "卡片数据库尚未初始化"};
	}
	if (!scripts_) {
		return {false, OCG_DUEL_CREATION_NOT_CREATED, "Lua 脚本加载器尚未初始化"};
	}

	OCG_DuelOptions options{};
	for (auto &value : options.seed) {
		value = next_seed(seed);
	}
	options.cardReader = read_card;
	options.payload1 = &card_data_adapter_;
	options.scriptReader = read_script;
	options.payload2 = scripts_.get();
	options.logHandler = discard_log;
	options.cardReaderDone = finish_reading_card;
	options.payload4 = &card_data_adapter_;

	OCG_Duel duel = nullptr;
	const int status = OCG_CreateDuel(&duel, &options);
	if (status != OCG_DUEL_CREATION_SUCCESS || duel == nullptr) {
		return {false, status, creation_message(status)};
	}

	duel_ = duel;
	const auto bootstrap = scripts_->load_bootstrap(duel);
	if (!bootstrap.ok) {
		destroy();
		return {false, OCG_DUEL_CREATION_NOT_CREATED, bootstrap.message};
	}
	return {true, status, creation_message(status)};
}

void DuelSession::destroy() noexcept {
	if (duel_ == nullptr) {
		return;
	}
	OCG_DestroyDuel(static_cast<OCG_Duel>(duel_));
	duel_ = nullptr;
}

bool DuelSession::is_active() const noexcept {
	return duel_ != nullptr;
}

} // namespace ygo
