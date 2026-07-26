#include "ygo/card_record.hpp"

#include <cassert>

int main() {
	ygo::CardRecord record;
	record.display.cid = 4007;
	record.display.cn_name = "青眼白龙";
	record.rule.code = 89631139;
	record.rule.attack = 3000;
	record.rule.setcodes = {0x10f3};

	assert(record.display.cid == 4007);
	assert(record.display.cn_name == "青眼白龙");
	assert(record.rule.code == 89631139);
	assert(record.rule.setcodes.front() == 0x10f3);
}
