class_name FloatingNumber
extends Label

## Petit chiffre qui monte et s'efface quand on récolte.
## C'est le feedback le plus important d'un idle game : sans lui, cliquer n'a
## aucune conséquence perçue.

const RISE := 62.0
const LIFETIME := 0.75

var _velocity := Vector2.ZERO


static func spawn(parent: Control, at: Vector2, text: String, color: Color, size: int = 20) -> FloatingNumber:
	var label := FloatingNumber.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0.02, 0.01, 0.06, 0.9))
	label.add_theme_constant_override("outline_size", 5)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.z_index = 10
	parent.add_child(label)
	label._place(at)
	label._animate()
	return label


func _place(at: Vector2) -> void:
	# Le Label est ajouté depuis un parent non encore layouté : on force sa taille
	# pour centrer correctement sur le point d'appui.
	custom_minimum_size = Vector2(160, 0)
	size = Vector2(160, 30)
	position = at - Vector2(80, 20)
	modulate.a = 0.0
	scale = Vector2(0.6, 0.6)
	pivot_offset = size * 0.5


func _animate() -> void:
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "position:y", position.y - RISE, LIFETIME)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "modulate:a", 1.0, 0.12)
	tween.tween_property(self, "scale", Vector2.ONE, 0.18)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.chain().tween_property(self, "modulate:a", 0.0, LIFETIME * 0.45)\
		.set_trans(Tween.TRANS_SINE)
	tween.chain().tween_callback(queue_free)
