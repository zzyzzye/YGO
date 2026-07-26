#pragma once

#include "ygo/duel_session.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <memory>

namespace ygo {

class YgoCoreBridge final : public godot::RefCounted {
	GDCLASS(YgoCoreBridge, godot::RefCounted)

public:
	YgoCoreBridge();
	~YgoCoreBridge() override = default;

	godot::Dictionary get_core_version() const;
	godot::Dictionary create_duel(std::int64_t seed);
	void destroy_duel();
	bool is_duel_active() const;

protected:
	static void _bind_methods();

private:
	std::unique_ptr<DuelSession> session_;
};

} // namespace ygo
