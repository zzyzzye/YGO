#include "ygo/ocg_card_data_adapter.hpp"

#include <utility>

namespace ygo {

OcgCardDataAdapter::OcgCardDataAdapter(
		std::shared_ptr<const CardDatabase> database) :
		database_(std::move(database)) {
}

void OcgCardDataAdapter::read(std::uint32_t code, OCG_CardData *data) {
	if (data == nullptr) {
		return;
	}
	*data = {};
	data->code = code;
	callback_setcodes_.clear();
	if (!database_) {
		return;
	}

	const CardRecord *record = database_->find(code);
	if (record == nullptr) {
		return;
	}
	const auto &rule = record->rule;
	data->code = rule.code;
	data->alias = rule.alias;
	data->type = rule.type;
	data->level = rule.level;
	data->attribute = rule.attribute;
	data->race = rule.race;
	data->attack = rule.attack;
	data->defense = rule.defense;
	data->lscale = rule.left_scale;
	data->rscale = rule.right_scale;
	data->link_marker = rule.link_marker;

	if (!rule.setcodes.empty()) {
		callback_setcodes_ = rule.setcodes;
		callback_setcodes_.push_back(0);
		data->setcodes = callback_setcodes_.data();
	}
}

void OcgCardDataAdapter::done(OCG_CardData *data) noexcept {
	// 当前 OCGCore 会在 cardReader 返回后同步构造内部 card_data，并在调用
	// cardReaderDone 前复制完整的零结尾 setcode 数组。完成回调之后外部
	// 指针不再有效，因此立即清空指针和每个 DuelSession 独占的缓冲区。
	if (data != nullptr) {
		data->setcodes = nullptr;
	}
	callback_setcodes_.clear();
}

} // namespace ygo
