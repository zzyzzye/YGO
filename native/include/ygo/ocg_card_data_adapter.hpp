#pragma once

#include "ygo/card_database.hpp"

#include "ocgapi_types.h"

#include <cstdint>
#include <memory>
#include <vector>

namespace ygo {

class OcgCardDataAdapter final {
public:
	explicit OcgCardDataAdapter(std::shared_ptr<const CardDatabase> database);

	void read(std::uint32_t code, OCG_CardData *data);
	void done(OCG_CardData *data) noexcept;

private:
	std::shared_ptr<const CardDatabase> database_;
	std::vector<std::uint16_t> callback_setcodes_;
};

} // namespace ygo
