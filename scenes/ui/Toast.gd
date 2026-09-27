class_name Toast
extends PanelContainer

## Message éphémère sous l'en-tête fixe (succès débloqué, sauvegarde, achat).
## Les toasts se rangent automatiquement pour ne jamais se chevaucher.

const VISIBLE_TIME := 2.6
const SLIDE := 26.0

static var _stack: Array[Toast] = []

## Distance du haut de la zone sûre, plus le repos de 8 px. Ce n'est pas une
## constante : c'est l'encoche, la barre d'état et la marge de confort, prises
## en compte au moment où le toast apparaît. Un repos codé en dur à 8 px placerait
## le message sous l'encoche, et l'utilisateur le lirait entièrement sans
## jamais voir la première ligne.
var _rest_top: float = 8.0

## Position du toast lorsqu'il est hors de l'écran, au-dessus de son repos.
const HIDDEN_OFFSET := -48.0


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
	# Le toast est créé depuis MainUI._ready(), avant que VBoxContainer ait
	# dimensionné la barre haute et le panneau de ressources. Reporter la mesure à
	# la fin de l'image évite de calculer sa place avec une hauteur nulle, et
	# garantit qu'il ne masque pas les boutons du header, notamment sous une encoche.
	call_deferred("_start_after_layout")


func _start_after_layout() -> void:
	if not is_inside_tree():
		return
	_rest_top = _safe_top_below_header()
	_relayout(false)
	_animate()


## Le notch réserve une zone HAUTE, mais le header du jeu occupe la zone sûre
## juste en dessous. Placer un toast seulement à `safe_top + 8` recouvrait donc
## le titre et les boutons, qui sont eux aussi à `safe_top`. On place les toasts
## sous le panneau de ressources, au début de la zone de jeu : ainsi ils
## n'empêchent jamais de lire ou d'atteindre la navigation, et restent sous la
## safe area après rotation.
func _safe_top_below_header() -> float:
	var top := 8.0 + float(SafeArea.insets_for(get_viewport())["top"])
	var canvas_layer := get_parent() as CanvasLayer
	var ui := canvas_layer.get_parent() as Control if canvas_layer != null else null
	if ui == null:
		return top
	var resource_panel := ui.get_node_or_null("Root/Layout/ResourcePanel") as Control
	if resource_panel == null or resource_panel.size.y <= 0.0:
		return top
	var panel_bottom := resource_panel.global_position.y + resource_panel.size.y \
		- ui.global_position.y
	return maxf(top, panel_bottom + 8.0)


func _animate() -> void:
	var tween := create_tween()
	tween.tween_property(self, "offset_top", _rest_top, 0.22)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_interval(VISIBLE_TIME)
	tween.tween_property(self, "offset_top", _rest_top + HIDDEN_OFFSET, 0.25)\
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
	var target := _rest_top + float(_stack.find(self)) * 62.0
	if animate:
		var tween := create_tween()
		tween.tween_property(self, "offset_top", target, 0.2)\
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	else:
		offset_top = target
