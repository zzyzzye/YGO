#include "ygo/duel_session.hpp"

#include <cassert>


int main() {
	const auto [major, minor] = ygo::DuelSession::core_version();
	assert(major >= 0);
	assert(minor >= 0);

	ygo::DuelSession session;
	assert(!session.is_active());

	const auto result = session.create(0x59474fULL);
	assert(result.ok);
	assert(session.is_active());

	session.destroy();
	assert(!session.is_active());

	session.destroy();
	assert(!session.is_active());
}
