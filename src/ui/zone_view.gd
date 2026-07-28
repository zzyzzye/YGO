class_name ZoneView
extends PanelContainer

# ZoneView 与 HandView 共用 CardView 原生场景，避免创建缺少固定视觉节点的裸脚本实例。
const CARD_VIEW_SCENE = preload("res://src/ui/card_view.tscn")

signal card_selected(card_data: Dictionary)
signal card_hovered(card_data: Dictionary)
signal card_unhovered(card_data: Dictionary)
# 空卡位没有 CardView 可转发输入，因此由 ZoneView 自己发布当前规则代次。
# controller/location/sequence 仍由持有四组卡位语义的 DuelBoard 补齐，ZoneView
# 不猜测自己在场景树中的协议位置。
signal place_requested(decision_generation: int)

var zone_label := ""
var _attack_target_preview := false
var _targetable := false
var _target_selected := false
var _card_selected := false
var _chain_candidate := false
var _place_candidate := false
var _place_decision_generation := -1
# 这些固定节点由 zone_view.tscn 持有；脚本只绑定节点，避免运行时拼装稳定界面。
@onready var card_container: CenterContainer = %CardContainer
@onready var title_label: Label = %TitleLabel
@onready var target_highlight: Panel = %TargetHighlight


func _ready() -> void:
	# DuelBoard 会在区域加入场景树前设置标题；原生节点就绪后需回填缓存值，
	# 才不会因 @onready 尚未绑定 Label 而丢失首帧区域名称。
	title_label.text = zone_label
	gui_input.connect(_on_gui_input)


func configure(label_text: String) -> void:
	zone_label = label_text
	if title_label:
		title_label.text = label_text


func set_attack_target_preview(value: bool) -> void:
	# 预览只表达“可请求 OCGCore 进入怪兽目标选择”，不代表该卡位已被规则层
	# 判定为合法目标；合法候选到达后由 set_targetable() 以更强样式覆盖。
	_attack_target_preview = value
	_refresh_target_highlight()


func set_targetable(value: bool) -> void:
	# 已选目标必然来自合法目标集合；一旦候选失效，同时清除选中态，避免旧快照
	# 留下更强的高亮却已不能提交。
	_targetable = value
	if !value:
		_target_selected = false
	_refresh_target_highlight()


func set_target_selected(value: bool) -> void:
	_target_selected = value and _targetable
	_refresh_target_highlight()


func set_chain_candidate(value: bool) -> void:
	# 连锁候选拥有独立状态与 Theme variation，不借用攻击目标的 targetable。
	# 规则快照切换时 DuelBoard 会统一传 false，避免旧卡位残留发动提示。
	_chain_candidate = value
	_refresh_target_highlight()


func set_place_candidate(value: bool, decision_generation := -1) -> void:
	# PlaceCandidate 只允许 DuelBoard 在全量映射成功后发布。关闭时同步擦除
	# 代次，确保 Retry 重建前的旧输入或测试保留信号无法命中新决策。
	_place_candidate = value
	_place_decision_generation = decision_generation if value else -1
	_refresh_target_highlight()


func set_card_selected(value: bool) -> void:
	# DuelBoard 只传递展示状态，真正的规则选择仍由 OCGCore 候选动作决定。
	_card_selected = value
	for child in card_container.get_children():
		if child is CardView:
			child.set_selected(value)


func show_card(card_data: Dictionary, show_back := false) -> void:
	for child in card_container.get_children():
		_retire_card(child)
	var card: CardView = CARD_VIEW_SCENE.instantiate()
	card_container.add_child(card)
	# CardView 在 _ready() 中建立手牌默认尺寸，因此必须在进入树后覆盖，
	# 才能让场区卡保持紧凑并避免两行区域挤压手牌。
	card.custom_minimum_size = Vector2(72, 105)
	card.configure(card_data, show_back)
	card.set_selected(_card_selected)
	card.card_selected.connect(_forward_card_selected)
	card.card_hovered.connect(_forward_card_hovered)
	card.card_unhovered.connect(_forward_card_unhovered)


func clear_card() -> void:
	_card_selected = false
	for child in card_container.get_children():
		_retire_card(child)


func _refresh_target_highlight() -> void:
	target_highlight.visible = (
		_attack_target_preview
		or _targetable
		or _chain_candidate
		or _place_candidate
	)
	if _target_selected:
		target_highlight.theme_type_variation = &"TargetSelectedHighlight"
	elif _targetable:
		target_highlight.theme_type_variation = &"TargetHighlight"
	elif _chain_candidate:
		target_highlight.theme_type_variation = &"ChainCandidateHighlight"
	elif _place_candidate:
		target_highlight.theme_type_variation = &"PlaceCandidate"
	else:
		target_highlight.theme_type_variation = &"AttackTargetPreview"


func _on_gui_input(event: InputEvent) -> void:
	if (
		!_place_candidate
		or !(event is InputEventMouseButton)
		or event.button_index != MOUSE_BUTTON_LEFT
		or !event.pressed
		or event.double_click
	):
		return
	# 先退休本节点再发信号：同步 Main/Bridge 调用或同帧双击都只能看到入口已
	# 关闭。其余候选由 DuelBoard 在收到该信号后、向 Main 转发前原子退休。
	var decision_generation := _place_decision_generation
	set_place_candidate(false)
	place_requested.emit(decision_generation)


func _forward_card_selected(card_data: Dictionary) -> void:
	card_selected.emit(card_data)


func _forward_card_hovered(card_data: Dictionary) -> void:
	card_hovered.emit(card_data)


func _forward_card_unhovered(card_data: Dictionary) -> void:
	card_unhovered.emit(card_data)


func _retire_card(child: Node) -> void:
	# 旧实例在帧末前仍可能被外部持有；只撤销 ZoneView 建立的转发，既阻止
	# 过期选择进入决斗板，也不破坏卡牌自身的其他观察者。
	if child is CardView:
		child.disabled = true
		child.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if child.card_selected.is_connected(_forward_card_selected):
			child.card_selected.disconnect(_forward_card_selected)
		if child.card_hovered.is_connected(_forward_card_hovered):
			child.card_hovered.disconnect(_forward_card_hovered)
		if child.card_unhovered.is_connected(_forward_card_unhovered):
			child.card_unhovered.disconnect(_forward_card_unhovered)
	card_container.remove_child(child)
	child.queue_free()
