extends Control

@onready var status: Label = %Status

var bridge: Object


func _ready() -> void:
	assert(ClassDB.class_exists("YgoCoreBridge"))
	bridge = ClassDB.instantiate("YgoCoreBridge")
	var version: Dictionary = bridge.call("get_core_version")
	var created: Dictionary = bridge.call("create_duel", 0x59474f)
	if not created.ok:
		var message := "OCGCore duel creation failed (%s): %s" % [
			created.status,
			created.message,
		]
		status.text = message
		push_error(message)
		return

	assert(bridge.call("is_duel_active"))
	status.text = "Godot %s · OCGCore %s.%s · duel lifecycle OK" % [
		Engine.get_version_info().string,
		version.major,
		version.minor,
	]


func _exit_tree() -> void:
	if bridge != null and bridge.call("is_duel_active"):
		bridge.call("destroy_duel")
