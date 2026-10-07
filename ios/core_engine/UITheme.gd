class_name UITheme
extends RefCounted

## Thème construit en code.
##
## Un .tres aurait été plus rapide à écrire, mais il n'est ni versionnable dans un
## diff lisible, ni paramétrable. Ici les couleurs sont des constantes en un seul
## endroit, et l'adaptation au mode clair/au daltonisme reste possible.

const BG := Color("10191d")
const BG_DEEP := Color("090f13")
const PANEL := Color("19282f")
const PANEL_ALT := Color("233740")
const ACCENT := Color("74e0cc")
const ACCENT_DARK := Color("237c70")
const GOLD := Color("ffd166")
const TEXT := Color("f2f7f6")
const MUTED := Color("afc1c7")
const SUCCESS := Color("4ade80")
const WARN := Color("fbbf24")
const ERROR := Color("f87171")
const DISABLED := Color("28353c")


static func build() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = 24

	# -- Labels
	theme.set_color("font_color", "Label", TEXT)
	theme.set_color("font_outline_color", "Label", BG_DEEP)
	theme.set_constant("outline_size", "Label", 0)
	theme.set_font_size("font_size", "Label", 24)

	# -- Fond
	theme.set_stylebox("panel", "Panel", box(BG_DEEP, 0, 0))
	theme.set_stylebox("panel", "PanelContainer", box(PANEL, 8, 16))

	# -- Boutons
	var normal := box(PANEL_ALT, 8, 14)
	normal.border_color = ACCENT.darkened(0.45)
	normal.border_width_bottom = 2
	var hover := box(PANEL_ALT.lightened(0.10), 8, 14)
	hover.border_color = ACCENT
	hover.border_width_bottom = 2
	var pressed := box(ACCENT_DARK, 8, 14)
	pressed.border_color = GOLD
	pressed.border_width_bottom = 2
	var disabled := box(DISABLED, 8, 14)
	theme.set_stylebox("normal", "Button", normal)
	theme.set_stylebox("hover", "Button", hover)
	theme.set_stylebox("pressed", "Button", pressed)
	var focus := box(Color(0, 0, 0, 0), 8, 14)
	focus.border_color = ACCENT
	focus.set_border_width_all(2)
	theme.set_stylebox("focus", "Button", focus)
	theme.set_stylebox("disabled", "Button", disabled)
	theme.set_color("font_color", "Button", TEXT)
	theme.set_color("font_hover_color", "Button", Color.WHITE)
	theme.set_color("font_pressed_color", "Button", TEXT)
	theme.set_color("font_disabled_color", "Button", MUTED)
	theme.set_font_size("font_size", "Button", 24)

	# -- Barres de progression
	theme.set_stylebox("background", "ProgressBar", box(DISABLED, 6, 0))
	var fill := box(ACCENT, 6, 0)
	theme.set_stylebox("fill", "ProgressBar", fill)
	theme.set_color("font_color", "ProgressBar", TEXT)

	# -- Onglets
	theme.set_stylebox("tab_selected", "TabBar", box(ACCENT, 10, 8))
	theme.set_stylebox("tab_unselected", "TabBar", box(PANEL, 10, 8))

	# -- Séparateurs de liste
	theme.set_constant("separation", "VBoxContainer", 10)
	theme.set_constant("separation", "HBoxContainer", 8)

	return theme


## StyleBox plat arrondi, prêt à l'emploi.
static func box(color: Color, radius: int, padding: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = padding + 2
	sb.content_margin_right = padding + 2
	sb.content_margin_top = padding
	sb.content_margin_bottom = padding
	sb.anti_aliasing = true
	return sb


## Carte de liste (bouton d'achat d'un bâtiment, d'une recherche...).
static func card(accent: Color = ACCENT) -> StyleBoxFlat:
	var sb := box(PANEL_ALT, 8, 16)
	sb.border_color = accent.darkened(0.5)
	sb.border_width_left = 4
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	return sb


static func card_disabled(accent: Color = ACCENT) -> StyleBoxFlat:
	var sb := card(accent)
	sb.bg_color = DISABLED
	sb.border_color = Color(0, 0, 0, 0)
	return sb
