class_name UITheme
extends RefCounted

## Thème construit en code.
##
## Un .tres aurait été plus rapide à écrire, mais il n'est ni versionnable dans un
## diff lisible, ni paramétrable. Ici les couleurs sont des constantes en un seul
## endroit, et l'adaptation au mode clair/au daltonisme reste possible.

const BG := Color("0d0b1a")
const BG_DEEP := Color("07060f")
const PANEL := Color("1c1836")
const PANEL_ALT := Color("262046")
const ACCENT := Color("7b6cf6")
const ACCENT_DARK := Color("5a4bd6")
const GOLD := Color("ffd166")
const TEXT := Color("f2f0ff")
const MUTED := Color("8f89ad")
const SUCCESS := Color("4ade80")
const WARN := Color("fbbf24")
const ERROR := Color("f87171")
const DISABLED := Color("3a3556")


static func build() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = 17

	# -- Labels
	theme.set_color("font_color", "Label", TEXT)
	theme.set_color("font_outline_color", "Label", BG_DEEP)
	theme.set_constant("outline_size", "Label", 0)
	theme.set_font_size("font_size", "Label", 17)

	# -- Fond
	theme.set_stylebox("panel", "Panel", box(BG_DEEP, 0, 0))
	theme.set_stylebox("panel", "PanelContainer", box(PANEL, 14, 12))

	# -- Boutons
	var normal := box(PANEL_ALT, 12, 10)
	normal.border_color = ACCENT.darkened(0.45)
	normal.border_width_bottom = 2
	var hover := box(PANEL_ALT.lightened(0.10), 12, 10)
	hover.border_color = ACCENT
	hover.border_width_bottom = 2
	var pressed := box(ACCENT_DARK, 12, 10)
	pressed.border_color = GOLD
	pressed.border_width_bottom = 2
	var disabled := box(DISABLED, 12, 10)
	theme.set_stylebox("normal", "Button", normal)
	theme.set_stylebox("hover", "Button", hover)
	theme.set_stylebox("pressed", "Button", pressed)
	theme.set_stylebox("focus", "Button", box(Color(0, 0, 0, 0), 12, 10))
	theme.set_stylebox("disabled", "Button", disabled)
	theme.set_color("font_color", "Button", TEXT)
	theme.set_color("font_hover_color", "Button", Color.WHITE)
	theme.set_color("font_pressed_color", "Button", BG_DEEP)
	theme.set_color("font_disabled_color", "Button", MUTED.darkened(0.2))
	theme.set_font_size("font_size", "Button", 17)

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
	var sb := box(PANEL_ALT, 12, 12)
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
