#include "ygo/duel_session.hpp"

#include "ocgapi.h"

namespace {

void read_empty_card(void *, std::uint32_t code, OCG_CardData *data) {
	*data = {};
	data->code = code;
}

void finish_reading_card(void *, OCG_CardData *) {
}

int reject_missing_script(void *, OCG_Duel, const char *) {
	return 0;
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
		return "duel created";
	case OCG_DUEL_CREATION_NO_OUTPUT:
		return "ocgcore did not return a duel";
	case OCG_DUEL_CREATION_NOT_CREATED:
		return "ocgcore could not create the duel";
	case OCG_DUEL_CREATION_NULL_DATA_READER:
		return "card data reader is required";
	case OCG_DUEL_CREATION_NULL_SCRIPT_READER:
		return "script reader is required";
	case OCG_DUEL_CREATION_INCOMPATIBLE_LUA_API:
		return "ocgcore Lua API is incompatible";
	case OCG_DUEL_CREATION_NULL_RNG_SEED:
		return "ocgcore RNG seed is required";
	default:
		return "unknown ocgcore creation status";
	}
}

} // namespace

namespace ygo {

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
		return {false, OCG_DUEL_CREATION_NOT_CREATED, "a duel is already active"};
	}

	OCG_DuelOptions options{};
	for (auto &value : options.seed) {
		value = next_seed(seed);
	}
	options.cardReader = read_empty_card;
	options.scriptReader = reject_missing_script;
	options.logHandler = discard_log;
	options.cardReaderDone = finish_reading_card;

	OCG_Duel duel = nullptr;
	const int status = OCG_CreateDuel(&duel, &options);
	if (status != OCG_DUEL_CREATION_SUCCESS || duel == nullptr) {
		return {false, status, creation_message(status)};
	}

	duel_ = duel;
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
