class_name Modal
extends Control

## Boîte de dialogue modale réutilisable (fond assombri + carte centrée).
##
## Sert à tout : popup hors-ligne, confirmation d'achat, confirmation de reset.
## Un seul composant pour éviter d'avoir trois implémentations de « bouton du
## bas qui fait rien », et pour garantir que « Annuler » est toujours présent et
## toujours aussi visible que l'action principale.
##
## PIÈGE : `set_anchors_preset(PRESET_FULL_RECT)` ne fait PAS étirer un contrôle.
## Il fixe les ancres en conservant le rectangle courant : les offsets deviennent
## négatifs pour compenser, et la taille reste celle qu'elle était — zéro pour un
## contrôle neuf. Il faut `set_anchors_and_offsets_preset`, qui remet aussi les
## offsets à zéro. C'est la cause du popup ancré dans le coin haut-gauche au
## lieu d'être centré.

signal dismissed()

## Largeur maximale de la carte. Au-delà, une ligne de texte devient impossible
## à lire d'un coup d'œil sur un grand écran.
const CARD_MAX_WIDTH := 380.0

var _card: PanelContainer
var _title_label: Label
var _body_label: Label
var _buttons_box: VBoxContainer
var _on_primary: Callable = Callable()
var _dismissible: bool = true
var _safe: MarginContainer
var _scroll: ScrollContainer
var _stack: VBoxContainer
var _width_cap: MarginContainer


static func open(layer: CanvasLayer, title: String, body: String) -> Modal:
	var modal := Modal.new()
	layer.add_child(modal)
	modal.configure(title, body)
	return modal


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Le fond assombri couvre TOUT l'écran, encoche comprise : c'est une
	# surface, pas du texte, et une bande claire sous l'encoche trahirait le
	# rectangle de la fenêtre. Il reste donc en plein cadre, sans marge.
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.01, 0.06, 0.82)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	# Zone sûre : c'est elle qui empêche le haut du titre de finir sous l'encoche
	# et le bas des boutons sous l'indicateur d'accueil.
	_safe = MarginContainer.new()
	_safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_safe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_safe)
	SafeArea.bind(_safe)

	# Un ScrollContainer, et non un CenterContainer nu.
	#
	# Un CenterContainer centre son enfant à sa taille MINIMALE. Dès que la
	# carte dépasse la hauteur disponible, il la place à
	# (hauteur_écran - hauteur_carte) / 2, donc à un offset NÉGATIF : les deux
	# bouts sortent de l'écran, en haut et en bas, à parts égales. Sur un iPhone
	# le haut tombe sous l'encoche et le bas sous l'indicateur d'accueil. Le
	# texte paraît alors tronqué aux DEUX extrémités, ce qui est plus déroutant
	# qu'un texte simplement trop long : rien n'indique qu'il y en ait plus,
	# et le joueur cherche une ligne manquante qui n'existe pas.
	#
	# Le ScrollContainer impose à l'enfant la taille disponible, et ne cède que
	# le surplus. Le centrage se fait ensuite à l'intérieur.
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	_safe.add_child(_scroll)

	# `alignment = CENTER` centre les enfants verticalement quand il reste de la
	# place, et les laisse starting en haut quand il n'y en a pas : exactement le
	# comportement voulu, sans un seul calcul de position à la main.
	_stack = VBoxContainer.new()
	_stack.alignment = BoxContainer.ALIGNMENT_CENTER
	_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stack.add_theme_constant_override("separation", 0)
	_scroll.add_child(_stack)
	_scroll.resized.connect(_fill_scroll_height, CONNECT_DEFERRED)
	_fill_scroll_height()

	# Conteneur de largeur : il occupe toute la largeur de la zone sûre, et
	# l'espace restant est partagé en deux marges. C'est ce qui borne la carte à
	# CARD_MAX_WIDTH sur un grand écran, sans la laisser coller aux bords sur un
	# petit. Une largeur fixe de 330 px, elle, débordait sur un iPhone SE.
	_width_cap = MarginContainer.new()
	_width_cap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_width_cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_width_cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stack.add_child(_width_cap)
	_width_cap.resized.connect(_clamp_width, CONNECT_DEFERRED)
	_clamp_width()

	_card = PanelContainer.new()
	_card.mouse_filter = Control.MOUSE_FILTER_STOP
	_width_cap.add_child(_card)

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


## Donne à la pile la hauteur de la fenêtre de défilement.
##
## Deuxième piège, et il est moins évident que le premier : un `ScrollContainer`
## n'étire son enfant que dans l'axe où le défilement est DÉSACTIVÉ. Avec un
## défilement vertical automatique, la pile se contente de sa hauteur MINIMALE —
## donc il ne lui reste aucune place en trop, et `ALIGNMENT_CENTER` n'a rien à
## centrer. La carte se retrouvait collée en haut.
##
## On impose donc explicitement cette hauteur minimale. Il n'y a pas de boucle de
## rappel : `_scroll` est dimensionné par le `MarginContainer` parent, jamais par
## son contenu, donc la valeur ne peut pas se feed-backer elle-même. Et quand la
## carte dépasse, la hauteur minimale du contenu reste la plus grande des deux :
## le défilement prend le relais.
func _fill_scroll_height() -> void:
	if _scroll == null or _stack == null:
		return
	var available := _scroll.size.y
	if available > 0.0:
		_stack.custom_minimum_size = Vector2(0, available)


## Répartit l'espace horizontal restant en deux marges égales, pour que la carte
## ne dépasse jamais CARD_MAX_WIDTH tout en restant centrée.
func _clamp_width() -> void:
	if _width_cap == null:
		return
	var available := _width_cap.size.x
	if available <= 0.0:
		return
	var slack: float = maxf(0.0, (available - CARD_MAX_WIDTH) * 0.5)
	var side := int(round(slack))
	_width_cap.add_theme_constant_override("margin_left", side)
	_width_cap.add_theme_constant_override("margin_right", side)


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
