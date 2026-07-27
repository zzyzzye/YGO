class_name CardView
extends TextureButton

signal card_selected(card_data: Dictionary)
signal card_hovered(card_data: Dictionary)

var card_data: Dictionary = {}
var face_down := false
var selected := false


func _ready() -> void:
	# 手牌以 1080P 为设计基准；父级场区可在节点进入树后覆盖为紧凑尺寸。
	# 依赖容器的最小尺寸而非屏幕坐标，使 2K、4K 下仍可等比扩展。
	custom_minimum_size = Vector2(102, 149)
	ignore_texture_size = true
	stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	pressed.connect(_on_pressed)
	mouse_entered.connect(_on_mouse_entered)


func configure(data: Dictionary, show_back := false) -> void:
	card_data = data
	face_down = show_back
	texture_normal = null
	tooltip_text = "对手手牌" if show_back else str(data.get("cn_name", data.get("card_id", "未知卡片")))
	if !show_back:
		var image_path := str(data.get("image_path", ""))
		texture_normal = _load_external_texture(image_path)
	queue_redraw()


func set_selected(value: bool) -> void:
	selected = value
	queue_redraw()


func _draw() -> void:
	var bounds := Rect2(Vector2.ZERO, size)
	if face_down:
		draw_rect(bounds, Color("#111111"), true)
		draw_rect(bounds.grow(-5), Color("#2d2d2d"), true)
	elif texture_normal == null:
		draw_rect(bounds, Color("#242424"), true)
	draw_rect(bounds.grow(-1), Color.WHITE if selected else Color("#aaaaaa"), false, 3.0 if selected else 1.0)
	if face_down:
		draw_string(
			ThemeDB.fallback_font,
			Vector2(17, size.y * 0.54),
			"CARD",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			18,
			Color.WHITE
		)


func _on_pressed() -> void:
	if !face_down:
		card_selected.emit(card_data)


func _on_mouse_entered() -> void:
	if !face_down:
		card_hovered.emit(card_data)


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
