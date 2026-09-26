class_name Modal
extends Control

## Boîte de dialogue modale réutilisable (fond assombri + carte centrée).
##
## Sert à tout : popup hors-ligne, confirmation d'achat, confirmation de reset.
## Un seul composant pour éviter d'avoir trois implémentations de « bouton du
## bas qui fait rien », et pour garantir que « Annuler » est toujours présent et
## toujours aussi visible que l'action principale.

signal dismissed()

var _card: PanelContainer
var _title_label: Label
var _body_label: Label
var _buttons_box: VBoxContainer
var _on_primary: Callable = Callable()
var _dismissible: bool = true


static func open(layer: CanvasLayer, title: String, body: String) -> Modal:
	var modal := Modal.new()
	layer.add_child(modal)
	modal.configure(title, body)
	return modal


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.01, 0.06, 0.82)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_card = PanelContainer.new()
	_card.custom_minimum_size = Vector2(330, 0)
	_card.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(_card)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	_card.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	margin.add_child(box)

	_title_label = Label.new()
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title_label.add_theme_font_size_override("font_size", 24)
	box.add_child(_title_label)

	_body_label = Label.new()
	_body_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body_label.add_theme_color_override("font_color", UITheme.MUTED)
	_body_label.add_theme_font_size_override("font_size", 16)
	box.add_child(_body_label)

	_buttons_box = VBoxContainer.new()
	_buttons_box.add_theme_constant_override("separation", 8)
	box.add_child(_buttons_box)


func configure(title: String, body: String) -> void:
	if _title_label == null:
		await ready
	_title_label.text = title
	_body_label.text = body


func set_dismissible(value: bool) -> void:
	_dismissible = value


## Ajoute un bouton pleine largeur. `accent` : couleur de fond.
func add_button(text: String, callback: Callable, accent: Color = UITheme.ACCENT) -> Button:
	if _buttons_box == null:
		await ready
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 52)
	btn.add_theme_stylebox_override("normal", UITheme.box(accent, 12, 10))
	btn.add_theme_stylebox_override("hover", UITheme.box(accent.lightened(0.12), 12, 10))
	btn.add_theme_stylebox_override("pressed", UITheme.box(accent.darkened(0.15), 12, 10))
	btn.pressed.connect(func() -> void:
		if callback.is_valid():
			callback.call()
	)
	_buttons_box.add_child(btn)
	return btn


func close() -> void:
	dismissed.emit()
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if not _dismissible or not visible:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		accept_event()
		close()
