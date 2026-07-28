class_name CardView
extends TextureButton

signal card_selected(card_data: Dictionary)
signal card_hovered(card_data: Dictionary)
signal card_unhovered(card_data: Dictionary)

var card_data: Dictionary = {}
var face_down := false
var selected := false

@onready var selection_frame: Panel = %SelectionFrame
@onready var card_back_panel: Panel = %CardBackPanel
@onready var face_down_label: Label = %FaceDownLabel
@onready var face_up_placeholder: Panel = %FaceUpPlaceholder
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
	resized.connect(_update_scale_pivot)
	_update_scale_pivot()


func _update_scale_pivot() -> void:
	# 手牌底边会贴齐 SafeArea。以默认左上角缩放会把选中反馈扩到安全区外；
	# 随 Container 最终分配尺寸更新为底边中心后，动画只向上和两侧展开，
	# 同时兼容场区覆盖后的紧凑 CardView 尺寸。
	pivot_offset = Vector2(size.x * 0.5, size.y)


func configure(data: Dictionary, show_back := false) -> void:
	card_data = data
	face_down = show_back
	texture_normal = null
	# 卡背的底纹与文字必须同步切换；只显示文字会让透明 TextureButton 在无贴图时失去可辨识的卡牌边界。
	card_back_panel.visible = show_back
	face_down_label.visible = show_back
	tooltip_text = "对手手牌" if show_back else str(data.get("cn_name", data.get("card_id", "未知卡片")))
	if !show_back:
		texture_normal = _load_external_texture(str(data.get("image_path", "")))
	# 正面卡图来自项目外部文件，缺失或损坏都属于可恢复展示问题。原生占位只在
	# 正面且纹理加载失败时出现；卡背与有效卡图必须保持各自唯一的视觉来源。
	face_up_placeholder.visible = !show_back and texture_normal == null


func set_selected(value: bool) -> void:
	# 新快照会为每张未选卡重复写入 false；无状态变化时不得播放 reset，
	# 否则所有卡牌都会先从选中缩放回落，响应式布局也无法及时稳定。
	if selected == value and selection_frame.visible == value:
		return
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
