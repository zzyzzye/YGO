extends Control

@onready var status: Label = %Status
@onready var godot_status: Label = %GodotStatus
@onready var core_status: Label = %CoreStatus
@onready var card_status: Label = %CardStatus
@onready var cache_status: Label = %CacheStatus
@onready var test_card_status: Label = %TestCardStatus
@onready var lua_status: Label = %LuaStatus

var bridge: Object


func _ready() -> void:
	assert(ClassDB.class_exists("YgoCoreBridge"))
	bridge = ClassDB.instantiate("YgoCoreBridge")

	# Godot 只提供当前项目根目录；卡库、缓存和 Lua 的相对位置由 C++ 统一管理，
	# 因此移动整个仓库后不需要修改机器相关的绝对路径。
	var initialized: Dictionary = bridge.call(
		"initialize_card_database",
		ProjectSettings.globalize_path("res://")
	)
	assert(initialized.ok)
	# 启动期集成哨兵同时验证“JSON 与卡图交集”、中文名主字段和卡图映射。
	# 素材集发生有意变更时应同步调整预期，不能让缺卡或字段错配静默通过。
	assert(bridge.call("get_card_count") == 14110)

	var blue_eyes: Dictionary = bridge.call("get_card", 89631139)
	assert(blue_eyes.ok)
	assert(blue_eyes.cn_name == "青眼白龙")
	assert(blue_eyes.image_path == "res://images/89631139.webp")

	var version: Dictionary = bridge.call("get_core_version")
	var created: Dictionary = bridge.call("create_duel", 0x59474f)
	assert(created.ok)
	assert(bridge.call("is_duel_active"))

	status.text = "卡片数据库与规则脚本已就绪"
	godot_status.text = "Godot：%s" % Engine.get_version_info().string
	core_status.text = "OCGCore：%s.%s" % [version.major, version.minor]
	card_status.text = "正式卡片：%s" % initialized.card_count
	cache_status.text = "缓存：%s" % initialized.cache_state
	test_card_status.text = "测试卡片：%s（%s）" % [blue_eyes.cn_name, blue_eyes.id]
	lua_status.text = "Lua 规则：已连接"


func _exit_tree() -> void:
	if bridge != null and bridge.call("is_duel_active"):
		bridge.call("destroy_duel")
