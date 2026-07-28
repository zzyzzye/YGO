class_name CardView
extends TextureButton

signal card_selected(card_data: Dictionary)
signal card_hovered(card_data: Dictionary)
signal card_unhovered(card_data: Dictionary)

var card_data: Dictionary = {}
var face_down := false
var selected := false

@onready var selection_frame: Panel = %SelectionFrame
@onready var face_down_label: Label = %FaceDownLabel
@onready var animator: AnimationPlayer = %AnimationPlayer


func _ready() -> void:
	# 手牌以 1080P 为设计基准；父级场区可在节点进入树后覆盖为紧凑尺寸，容器仍可据此自适应重排。
	custom_minimum_size = Vector2(102, 149)
	ignore_texture_size = true
	stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	pressed.connect(_on_pressed)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)


func configure(data: Dictionary, show_back := false) -> void:
	card_data = data
	face_down = show_back
	texture_normal = null
	face_down_label.visible = show_back
	tooltip_text = "对手手牌" if show_back else str(data.get("cn_name", data.get("card_id", "未知卡片")))
	if !show_back:
		texture_normal = _load_external_texture(str(data.get("image_path", "")))


func set_selected(value: bool) -> void:
	selected = value
	selection_frame.visible = value
	animator.play("select" if value else "reset")


func _on_pressed() -> void:
	if !face_down:
		card_selected.emit(card_data)


func _on_mouse_entered() -> void:
	if !face_down:
		animator.play("hover_in")
		card_hovered.emit(card_data)


func _on_mouse_exited() -> void:
	if !face_down:
		animator.play("hover_out")
		card_unhovered.emit(card_data)


func _load_external_texture(resource_path: String) -> Texture2D:
	if resource_path.is_empty():
		return null
	var absolute_path := ProjectSettings.globalize_path(resource_path)
	if !FileAccess.file_exists(absolute_path):
		return null
	var image := Image.load_from_file(absolute_path)
	if image == null or image.is_empty():
		return null
	return ImageTexture.create_from_image(image)
