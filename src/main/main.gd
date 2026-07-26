extends Control

func _ready() -> void:
	assert(ClassDB.class_exists("YgoCoreBridge"))
	var bridge: Object = ClassDB.instantiate("YgoCoreBridge")
	var version: Dictionary = bridge.call("get_core_version")
	assert(version.has("major"))
	assert(version.has("minor"))

	var created: Dictionary = bridge.call("create_duel", 0x59474f)
	assert(created.ok)
	assert(bridge.call("is_duel_active"))

	bridge.call("destroy_duel")
	assert(not bridge.call("is_duel_active"))
	get_tree().quit()
