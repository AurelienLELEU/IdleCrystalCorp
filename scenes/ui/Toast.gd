class_name Toast
extends PanelContainer

## Message éphémère en haut de l'écran (succès débloqué, sauvegarde, achat).
## Les toasts se rangent automatiquement pour ne jamais se chevaucher.

const VISIBLE_TIME := 2.6
const SLIDE := 26.0

static var _stack: Array[Toast] = []


static func push(parent: CanvasLayer, text: String, kind: String = "info") -> Toast:
	var toast := Toast.new()
	toast._setup(text, kind)
	parent.add_child(toast)
	return toast


func _setup(text: String, kind: String) -> void:
	var color := UITheme.ACCENT
	match kind:
		"success":
			color = UITheme.SUCCESS
		"warn":
			color = UITheme.WARN
		"error":
			color = UITheme.ERROR
		"gold":
			color = UITheme.GOLD
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var sb := UITheme.box(Color(color.r, color.g, color.b, 0.16), 12, 12)
	sb.border_color = color
	sb.border_width_left = 4
	add_theme_stylebox_override("panel", sb)

	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", UITheme.TEXT)
	label.add_theme_font_size_override("font_size", 16)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)


func _ready() -> void:
	# Coin haut-centre, légèrement en dehors de l'écran pour pouvoir glisser.
	set_anchors_preset(Control.PRESET_CENTER_TOP)
	anchor_left = 0.5
	anchor_right = 0.5
	offset_left = -170
	offset_right = 170
	offset_top = -40
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stack.append(self)
	_relayout(false)
	_animate()


func _animate() -> void:
	var tween := create_tween()
	tween.tween_property(self, "offset_top", 8.0, 0.22)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_interval(VISIBLE_TIME)
	tween.tween_property(self, "offset_top", -40.0, 0.25)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.tween_callback(_on_gone)


func _on_gone() -> void:
	_stack.erase(self)
	queue_free()
	# Les toasts restants remontent pour combler le trou.
	for t in _stack:
		if is_instance_valid(t):
			t._relayout(true)


func _relayout(animate: bool) -> void:
	var target := 8.0 + float(_stack.find(self)) * 62.0
	if animate:
		var tween := create_tween()
		tween.tween_property(self, "offset_top", target, 0.2)\
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	else:
		offset_top = target
