extends Control

@onready var status: Label = %Status


func _ready() -> void:
	status.text = "Native bridge not loaded"
