extends Control

## Écran principal.
##
## Ce script ne contient aucune règle de jeu : il lit l'état, il écrit des
## libellés, il relaie des clics. Trois principes :
##
##   1. aucun rafraîchissement dans _process — tout passe par le signal
##      resources_changed émis à 10 Hz par GameManager ;
##   2. seule la page visible est rafraîchie, et seulement 3 fois par seconde
##      (les libellés de coût changent bien plus lentement que le compteur
##      principal, qui reste lui à 10 Hz) ;
##   3. les pages sont construites une fois, puis seul leur texte est mis à jour.

const PAGE_BUILDINGS := "buildings"
const PAGE_CLICKS := "clicks"
const PAGE_RESEARCH := "research"
const PAGE_PRESTIGE := "prestige"
const PAGE_ACHIEVEMENTS := "achievements"
const PAGE_STORE := "store"
const PAGE_SETTINGS := "settings"

## Un rafraîchissement de page toutes les 3 impulsions de 10 Hz (~3,3 Hz).
const PAGE_REFRESH_EVERY := 3

const BOOST_AD_MULTIPLIER := 10.0
const BOOST_AD_MINUTES := 30.0
const FREE_CRYSTALS_AD_SECONDS := 300.0

## Taille du compteur de combo flottant, en unités de mise en page, et écart
## avec la barre basse. Constantes pour que le test puisse vérifier la position
## sans dupliquer les valeurs.
const COMBO_LABEL_HEIGHT := 28.0
const COMBO_LABEL_GAP := 4.0

## Hauteur minimale de la barre basse. Partagée par les boutons de navigation,
## le bouton de récolte et le positionnement du compteur de combo.
const BOTTOM_BAR_HEIGHT := 66.0

@onready var _root_margin: MarginContainer = $Root
@onready var _title_label: Label = $Root/Layout/TitleLabel
@onready var _resource_label: Label = $Root/Layout/ResourcePanel/ResourceBox/ResourceLabel
@onready var _rate_label: Label = $Root/Layout/ResourcePanel/ResourceBox/RateLabel
@onready var _boost_bar: ProgressBar = $Root/Layout/ResourcePanel/ResourceBox/BonusBar
@onready var _page_host: Control = $Root/Layout/Pages/PageHost
@onready var _top_bar: HBoxContainer = $Root/Layout/TopBar
@onready var _bottom_bar: HBoxContainer = $Root/Layout/BottomBar
@onready var _toast_layer: CanvasLayer = $ToastLayer
@onready var _floating_layer: Control = $FloatingLayer
@onready var _overlay_layer: CanvasLayer = $OverlayLayer

var _pages: Dictionary = {}
var _page_data: Dictionary = {}
var _current_page: String = ""
var _nav_buttons: Dictionary = {}
var _harvest_button: Button
var _daily_bonus_available_state := false
var _combo_label: Label
## Support du compteur de combo : un `Control` transparent pleine page, enfant du
## `MarginContainer` de zone sûre. Voir `_build_bottom_bar()`.
var _combo_holder: Control
var _achievements_button: Button
var _settings_rows: Dictionary = {}
var _tick_count: int = 0


class Row extends RefCounted:
	var id: String = ""
	var root: PanelContainer
	var title: Label
	var subtitle: Label
	var button: Button
	## Second bouton facultatif, pour les lignes qui offering deux actions
	## concurrentes (encaisser le bonus, ou le doubler contre une pub). `null`
	## sur toutes les autres lignes : absent, il ne coûte rien en code de
	## rafraîchissement, `if row.extra_button != null` suffit.
	var extra_button: Button


# ===================================================================== démarrage

func _ready() -> void:
	theme = UITheme.build()

	# Les marges de la scène (12/10) sont un plancher de mise en page ; la zone
	# sûre s'y ajoute. Sans cela, le compteur et le bouton de récolte passent
	# sous l'encoche et sous l'indicateur d'accueil : le joueur ne voit plus son
	# score, et le bouton le plus important de l'app devient inatteignable.
	SafeArea.bind(_root_margin)

	_build_pages()
	_build_top_bar()
	_build_bottom_bar()
	_connect_signals()

	_title_label.text = GameManager.config.title
	_resource_label.add_theme_color_override("font_color", UITheme.GOLD)

	# Une page fermée laisse toute la place au compteur et au bouton de récolte.
	_switch_page("")

	# Le compteur de succès doit être à jour avant la première interaction.
	_refresh_achievements()
	_refresh_header()
	_daily_bonus_available_state = GameManager.is_daily_bonus_available()

	if GameManager.has_pending_offline():
		_show_offline_popup()
	elif _daily_bonus_available_state:
		Toast.push(_toast_layer, "🎁 Bonus quotidien disponible dans Réglages", "gold")


func _connect_signals() -> void:
	# Le rythme de rafraîchissement vient de GameManager, pas d'un _process ici :
	# le coût par image est ainsi explicite et mesurable.
	GameManager.resources_changed.connect(_on_tick)
	GameManager.message.connect(_on_message)
	GameManager.achievement_unlocked.connect(_on_achievement_unlocked)
	GameManager.combo_changed.connect(_on_combo_changed)
	GameManager.game_reset.connect(_on_game_reset)
	GameManager.daily_bonus_changed.connect(_on_daily_bonus_changed)
	# Sans cette connexion, le signal partait dans le vide : revenir au premier
	# plan — le geste le plus courant d'un joueur mobile — calculait les gains
	# hors-ligne, remplissait `pending_offline`, et n'affichait rien. Le joueur
	# jouait normalement, convaincu que le jeu n'avait pas calculé ses gains,
	# étaient perdus à la fermeture suivante.
	GameManager.offline_gains_pending.connect(_on_offline_gains_pending)
	Store.purchase_requested.connect(_show_purchase_confirm)
	Store.purchase_completed.connect(_on_purchase_completed)
	Store.purchase_failed.connect(_on_purchase_failed)
	Store.products_loaded.connect(_on_store_products_loaded)
	Ads.ad_completed.connect(_on_ad_completed)
	Ads.ad_failed.connect(_on_ad_failed)


func _on_tick(_total: BigNum, _per_sec: BigNum) -> void:
	_refresh_header()
	_tick_count += 1
	if _current_page != "" and _tick_count % PAGE_REFRESH_EVERY == 0:
		_refresh_page(_current_page)


# ======================================================================== pages

func _build_pages() -> void:
	for page_name in [PAGE_BUILDINGS, PAGE_CLICKS, PAGE_RESEARCH, PAGE_PRESTIGE,
			PAGE_ACHIEVEMENTS, PAGE_STORE, PAGE_SETTINGS]:
		var scroll := ScrollContainer.new()
		scroll.name = "Page_%s" % page_name
		# ..._and_offsets_ : sans cela la page garde la taille qu'elle avait,
		# soit zéro, et le ScrollContainer n'affiche rien.
		scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.visible = false
		_page_host.add_child(scroll)

		var box := VBoxContainer.new()
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_theme_constant_override("separation", 8)
		scroll.add_child(box)

		_pages[page_name] = scroll
		_page_data[page_name] = {}

	_build_buildings_page()
	_build_clicks_page()
	_build_research_page()
	_build_prestige_page()
	_build_achievements_page()
	_build_store_page()
	_build_settings_page()


func _switch_page(page_name: String) -> void:
	# Recliquer sur l'onglet ouvert le referme : sur mobile, l'écran doit pouvoir
	# se consacrer entièrement à la récolte.
	_current_page = "" if _current_page == page_name else page_name
	for name in _pages:
		var scroll: ScrollContainer = _pages[name]
		scroll.visible = (name == _current_page)
	for name in _nav_buttons:
		var btn: Button = _nav_buttons[name]
		btn.modulate = Color.WHITE if name == _current_page else Color(1, 1, 1, 0.6)
	if _current_page != "":
		var scroll: ScrollContainer = _pages[_current_page]
		scroll.scroll_vertical = 0
		_refresh_page(_current_page)


func _refresh_page(page_name: String) -> void:
	match page_name:
		PAGE_BUILDINGS:
			_refresh_buildings()
		PAGE_CLICKS:
			_refresh_clicks()
		PAGE_RESEARCH:
			_refresh_research()
		PAGE_PRESTIGE:
			_refresh_prestige()
		PAGE_ACHIEVEMENTS:
			_refresh_achievements()
		PAGE_STORE:
			_refresh_store()
		PAGE_SETTINGS:
			_refresh_settings()


# ----------------------------------------------------------------- barre haute

func _build_top_bar() -> void:
	var version := Label.new()
	version.text = "v%s" % str(ProjectSettings.get_setting("application/config/version", "1.0.0"))
	version.add_theme_color_override("font_color", UITheme.MUTED)
	version.add_theme_font_size_override("font_size", 13)
	version.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	version.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_top_bar.add_child(version)

	_achievements_button = _small_button("🏆 Succès", func() -> void: _switch_page(PAGE_ACHIEVEMENTS))
	_top_bar.add_child(_achievements_button)
	_top_bar.add_child(_small_button("💎 Boutique", func() -> void: _switch_page(PAGE_STORE)))
	_top_bar.add_child(_small_button("⚙️", func() -> void: _switch_page(PAGE_SETTINGS)))


func _small_button(text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.add_theme_font_size_override("font_size", 14)
	btn.custom_minimum_size = Vector2(0, 40)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.pressed.connect(callback)
	return btn


# ----------------------------------------------------------------- barre basse

func _build_bottom_bar() -> void:
	_build_combo_label()

	_nav_buttons[PAGE_BUILDINGS] = _nav_button("🏗️ Bâtiments", PAGE_BUILDINGS)
	_nav_buttons[PAGE_CLICKS] = _nav_button("⚡ Clics", PAGE_CLICKS)
	_bottom_bar.add_child(_nav_buttons[PAGE_BUILDINGS])
	_bottom_bar.add_child(_nav_buttons[PAGE_CLICKS])

	_harvest_button = Button.new()
	_harvest_button.text = "⛏️ RÉCOLTER"
	_harvest_button.custom_minimum_size = Vector2(0, BOTTOM_BAR_HEIGHT)
	_harvest_button.add_theme_font_size_override("font_size", 16)
	_harvest_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_harvest_button.size_flags_stretch_ratio = 1.5
	_harvest_button.add_theme_stylebox_override("normal", UITheme.box(UITheme.GOLD.darkened(0.15), 14, 10))
	_harvest_button.add_theme_stylebox_override("hover", UITheme.box(UITheme.GOLD, 14, 10))
	_harvest_button.add_theme_stylebox_override("pressed", UITheme.box(UITheme.GOLD.darkened(0.32), 14, 10))
	_harvest_button.pressed.connect(_on_harvest_pressed)
	_bottom_bar.add_child(_harvest_button)

	_nav_buttons[PAGE_RESEARCH] = _nav_button("🔬 R&D", PAGE_RESEARCH)
	_nav_buttons[PAGE_PRESTIGE] = _nav_button("🌀 Asc.", PAGE_PRESTIGE)
	_bottom_bar.add_child(_nav_buttons[PAGE_RESEARCH])
	_bottom_bar.add_child(_nav_buttons[PAGE_PRESTIGE])


## Le compteur était un enfant direct de la racine, hors de la zone sûre : sur
## iPhone, il se retrouvait sous l'indicateur d'accueil. Ce support transparent
## occupe la zone sûre et porte le libellé; marges et rotations sont donc gérées
## par le `MarginContainer`, sans recalcul séparé des insets.
func _build_combo_label() -> void:
	_combo_holder = Control.new()
	_combo_holder.name = "ComboHolder"
	_combo_holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_combo_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root_margin.add_child(_combo_holder)

	_combo_label = Label.new()
	_combo_label.name = "ComboLabel"
	_combo_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_combo_label.offset_bottom = -(BOTTOM_BAR_HEIGHT + COMBO_LABEL_GAP)
	_combo_label.offset_top = _combo_label.offset_bottom - COMBO_LABEL_HEIGHT
	_combo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_combo_label.add_theme_color_override("font_color", UITheme.GOLD)
	_combo_label.add_theme_font_size_override("font_size", 15)
	_combo_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_combo_label.visible = false
	_combo_holder.add_child(_combo_label)


func _nav_button(text: String, page_name: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.add_theme_font_size_override("font_size", 13)
	btn.custom_minimum_size = Vector2(0, BOTTOM_BAR_HEIGHT)
	btn.clip_text = true
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(func() -> void: _switch_page(page_name))
	return btn


# ======================================================================= récolte

func _on_harvest_pressed() -> void:
	var gained := GameManager.harvest()
	Audio.play("click", randf_range(0.94, 1.08))
	if GameManager.combo_stacks >= 3:
		Audio.play("combo", 1.0 + 0.02 * float(GameManager.combo_stacks))
	_spawn_floater(gained)
	_refresh_header()


func _spawn_floater(gained: BigNum) -> void:
	var at := _harvest_button.global_position + _harvest_button.size * Vector2(0.5, 0.2)
	var big := GameManager.combo_stacks >= 10
	FloatingNumber.spawn(
		_floating_layer, at, "+%s" % gained.format_short(), UITheme.GOLD, 26 if big else 21)


# =============================================================== page bâtiments

func _build_buildings_page() -> void:
	var box: VBoxContainer = _page_boxes(PAGE_BUILDINGS)
	box.add_child(_section_header("Production",
		"Chaque bâtiment travaille pour vous. Tous les 10 exemplaires, sa production est doublée."))
	var rows: Dictionary = {}
	for b in GameManager.config.buildings:
		var id := str(b.get("id", ""))
		var row := _make_row(id)
		row.title.text = "%s %s" % [str(b.get("icon", "")), str(b.get("name", id))]
		row.subtitle.text = str(b.get("desc", ""))
		row.button.pressed.connect(func() -> void:
			if GameManager.buy_building(id, 1) > 0:
				Audio.play("purchase")
			else:
				Audio.play("error")
			_refresh_buildings()
		)
		box.add_child(row.root)
		rows[id] = row
	_page_data[PAGE_BUILDINGS] = {"rows": rows}


func _refresh_buildings() -> void:
	var rows: Dictionary = _page_data[PAGE_BUILDINGS].get("rows", {})
	for b in GameManager.config.buildings:
		var id := str(b.get("id", ""))
		var row: Row = rows.get(id)
		if row == null:
			continue
		if not GameManager.is_building_unlocked(id):
			row.root.visible = false
			continue
		row.root.visible = true

		var count := GameManager.get_building_count(id)
		var cost := GameManager.get_building_cost(id)
		var can_afford: bool = GameManager.current_resources.gte(cost)
		var every := int(b.get("milestone_every", 0))
		var per_unit := BigNum.from_float(float(b.get("production_per_sec", 0.0)))
		var to_milestone := 0
		if every > 0:
			to_milestone = every - (count % every)
			row.subtitle.text = "+%s/s  ·  encore %d pour ×%s\nPossédé : %d" % [
				per_unit.format_short(), to_milestone,
				Fmt.number(float(b.get("milestone_mult", 2.0))), count]
		else:
			row.subtitle.text = "+%s/s\nPossédé : %d" % [per_unit.format_short(), count]
		row.button.text = cost.format_short(1)
		row.button.disabled = not can_afford
		row.root.add_theme_stylebox_override("panel",
			UITheme.card() if can_afford else UITheme.card_disabled())


# ===================================================================== page clics

func _build_clicks_page() -> void:
	var box: VBoxContainer = _page_boxes(PAGE_CLICKS)
	var max_mult := Fmt.multiplier(1.0 + float(GameManager.config.combo.get("max_stacks", 25))
		* float(GameManager.config.combo.get("power_per_stack", 0.04)))
	box.add_child(_section_header("Récolte manuelle",
		"Enchaîner les clics rapidement construit un combo, jusqu'à %s de bonus. Fenêtre : %s." % [
			max_mult, Fmt.number(GameManager.get_combo_window())]))
	var rows: Dictionary = {}
	for u in GameManager.config.click_upgrades:
		var id := str(u.get("id", ""))
		var row := _make_row(id)
		row.title.text = "%s %s" % [str(u.get("icon", "")), str(u.get("name", id))]
		row.subtitle.text = str(u.get("desc", ""))
		row.button.pressed.connect(func() -> void:
			if GameManager.buy_upgrade(id):
				Audio.play("upgrade")
			else:
				Audio.play("error")
			_refresh_clicks()
		)
		box.add_child(row.root)
		rows[id] = row
	_page_data[PAGE_CLICKS] = {"rows": rows}


func _refresh_clicks() -> void:
	var rows: Dictionary = _page_data[PAGE_CLICKS].get("rows", {})
	for u in GameManager.config.click_upgrades:
		var id := str(u.get("id", ""))
		var row: Row = rows.get(id)
		if row == null:
			continue
		var level := GameManager.get_upgrade_level(id)
		var max_level := int(u.get("max_level", 999))
		if level >= max_level:
			row.subtitle.text = "%s\nNiveau %d / %d — au maximum" % [str(u.get("desc", "")), level, max_level]
			row.button.text = "MAX"
			row.button.disabled = true
			row.root.add_theme_stylebox_override("panel", UITheme.card_disabled())
			continue
		var cost := GameManager.get_upgrade_cost(id)
		var can_afford: bool = GameManager.current_resources.gte(cost)
		row.subtitle.text = "%s\nNiveau %d / %d" % [str(u.get("desc", "")), level, max_level]
		row.button.text = cost.format_short(1)
		row.button.disabled = not can_afford
		row.root.add_theme_stylebox_override("panel",
			UITheme.card() if can_afford else UITheme.card_disabled())


# ======================================================================== page R&D

func _build_research_page() -> void:
	var box: VBoxContainer = _page_boxes(PAGE_RESEARCH)
	var rows: Dictionary = {}
	var sections := [
		["production", "Production", "Multiplicateurs permanents de production."],
		["clic", "Clic", "Multiplicateurs de puissance de récolte."],
		["utilitaire", "Utilitaire", "Effets indirects : hors-ligne, coûts, combo, ascension."],
	]
	for section in sections:
		box.add_child(_section_header(str(section[1]), str(section[2])))
		for t in GameManager.config.research_by_category(str(section[0])):
			var id := str(t.get("id", ""))
			var row := _make_row(id)
			row.title.text = "%s %s" % [str(t.get("icon", "")), str(t.get("name", id))]
			row.subtitle.text = str(t.get("desc", ""))
			row.button.pressed.connect(func() -> void:
				if GameManager.buy_research(id):
					Audio.play("upgrade")
				else:
					Audio.play("error")
				_refresh_research()
			)
			box.add_child(row.root)
			rows[id] = row
	_page_data[PAGE_RESEARCH] = {"rows": rows}


## Effet total d'une technologie au niveau donné, en clair.
func _research_effect_text(t: Dictionary, level: int) -> String:
	var value := float(t.get("effect_value", 1.0))
	match str(t.get("effect_type", "")):
		"offline_hours":
			return "Hors-ligne ×%s  ·  plafond %s" % [
				Fmt.number(pow(value, float(level))),
				Fmt.duration(GameManager.get_offline_cap_hours() * 3600.0)]
		"cost_reduction":
			return "Coût des bâtiments ×%s" % Fmt.number(pow(value, float(level)))
		"prestige_bonus":
			return "+%d %% de %s par ascension" % [
				int(value * 100.0 * level), GameManager.config.prestige_name]
		"combo_window":
			return "Fenêtre de combo %s s" % Fmt.number(GameManager.get_combo_window())
		"click_mult":
			return "Clic ×%s" % Fmt.number(pow(value, float(level)))
		_:
			return "Production ×%s" % Fmt.number(pow(value, float(level)))


func _refresh_research() -> void:
	var rows: Dictionary = _page_data[PAGE_RESEARCH].get("rows", {})
	for t in GameManager.config.research:
		var id := str(t.get("id", ""))
		var row: Row = rows.get(id)
		if row == null:
			continue
		if not GameManager.is_research_unlocked(id):
			row.root.visible = false
			continue
		row.root.visible = true

		var level := GameManager.get_research_level(id)
		var max_level := GameManager.get_research_max_level(id)
		if level >= max_level:
			row.subtitle.text = "%s\n%s — au maximum" % [str(t.get("desc", "")), _research_effect_text(t, level)]
			row.button.text = "MAX"
			row.button.disabled = true
			row.root.add_theme_stylebox_override("panel", UITheme.card_disabled())
			continue

		var cost := GameManager.get_research_cost(id)
		var can_afford: bool = GameManager.current_resources.gte(cost)
		row.subtitle.text = "Niveau %d / %d\n%s  →  %s" % [level, max_level,
			_research_effect_text(t, level), _research_effect_text(t, level + 1)]
		row.button.text = cost.format_short(1)
		row.button.disabled = not can_afford
		row.root.add_theme_stylebox_override("panel",
			UITheme.card() if can_afford else UITheme.card_disabled())


# =================================================================== page ascension

func _build_prestige_page() -> void:
	var box: VBoxContainer = _page_boxes(PAGE_PRESTIGE)
	box.add_child(_section_header(
		"%s Ascension" % GameManager.config.prestige_icon,
		"Repartez de zéro avec un multiplicateur permanent. C'est là que se joue la vraie progression."))

	var summary := Label.new()
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	summary.add_theme_font_size_override("font_size", 18)
	box.add_child(summary)

	var progress := ProgressBar.new()
	progress.custom_minimum_size = Vector2(0, 14)
	progress.show_percentage = false
	box.add_child(progress)

	var button := Button.new()
	button.text = "🌀 Ascensionner"
	button.custom_minimum_size = Vector2(0, 58)
	button.add_theme_font_size_override("font_size", 19)
	button.add_theme_stylebox_override("normal", UITheme.box(UITheme.ACCENT, 14, 10))
	button.add_theme_stylebox_override("hover", UITheme.box(UITheme.ACCENT.lightened(0.12), 14, 10))
	button.add_theme_stylebox_override("pressed", UITheme.box(UITheme.ACCENT.darkened(0.18), 14, 10))
	button.pressed.connect(_confirm_prestige)
	box.add_child(button)

	var info := Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_theme_color_override("font_color", UITheme.MUTED)
	info.add_theme_font_size_override("font_size", 15)
	box.add_child(info)

	var tips := _section_header("Comment ça marche", "")
	tips.add_child(_tip("Les %s se gagnent sur les %s gagnés pendant la run en cours." % [
		GameManager.config.prestige_name, GameManager.config.resource_name.to_lower()]))
	tips.add_child(_tip("Ils ne se perdent jamais et se cumulent d'une ascension à l'autre."))
	tips.add_child(_tip("Chaque point augmente le multiplicateur de production de façon définitive."))
	tips.add_child(_tip("Les succès, l'ascension passée et les statistiques sont conservés."))
	tips.add_child(_tip("Les bâtiments de nouvelle génération se débloquent au fil des ascensions."))
	box.add_child(tips)

	_page_data[PAGE_PRESTIGE] = {
		"summary": summary, "progress": progress, "button": button, "info": info,
	}


func _tip(text: String) -> Label:
	var label := Label.new()
	label.text = "•  " + text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", UITheme.MUTED)
	label.add_theme_font_size_override("font_size", 15)
	return label


func _refresh_prestige() -> void:
	var data: Dictionary = _page_data.get(PAGE_PRESTIGE, {})
	if data.is_empty():
		return
	var preview := GameManager.get_prestige_preview()
	var summary: Label = data["summary"]
	var progress: ProgressBar = data["progress"]
	var button: Button = data["button"]
	var info: Label = data["info"]

	var points_gained := int(preview["points_gained"])
	# Les points d'ascension sont un petit entier : pas de notation abrégée ici,
	# le joueur doit lire « 12 Éclats », pas « 1,2 e+1 ».
	summary.text = "%s : %d\nMultiplicateur : %s → %s" % [
		GameManager.config.prestige_name,
		GameManager.prestige_points,
		Fmt.multiplier(float(preview["current_multiplier"])),
		Fmt.multiplier(float(preview["next_multiplier"])),
	]
	progress.max_value = 1.0
	progress.value = float(preview["progress"])

	var can: bool = bool(preview["can_prestige"]) and points_gained > 0
	button.disabled = not can
	button.text = ("🌀 Ascensionner  +%d" % points_gained) if can else "🌀 Ascensionner"

	info.text = "Gagnés depuis la dernière ascension : %s\nCondition : %s %s\nAscensions réalisées : %d%s" % [
		GameManager.run_earnings.format_short(),
		GameManager.get_prestige_requirement().format_short(),
		GameManager.config.resource_name,
		GameManager.prestige_count,
		("\n\n⚠️ Remet à zéro : ressources, bâtiments"
			+ (", recherche." if bool(preview["resets_research"]) else ".")
			+ "\nVos %s sont conservés." % GameManager.config.prestige_name.to_lower()),
	]


func _confirm_prestige() -> void:
	var preview := GameManager.get_prestige_preview()
	if not bool(preview["can_prestige"]):
		Toast.push(_toast_layer, "Pas encore assez de gains depuis la dernière ascension.", "warn")
		return
	var modal := Modal.open(_overlay_layer, "🌀 Ascensionner ?",
		("Vous repartez de zéro et vous obtenez %s %s, définitivement.\n\n"
			+ "Multiplicateur de production :\n%s → %s\n\n"
			+ "Réinitialisé : ressources, bâtiments%s.\nConservé : succès, statistiques, %s.") % [
			Fmt.number(int(preview["points_gained"])),
			GameManager.config.prestige_name,
			Fmt.multiplier(float(preview["current_multiplier"])),
			Fmt.multiplier(float(preview["next_multiplier"])),
			", recherche" if bool(preview["resets_research"]) else "",
			GameManager.config.prestige_name.to_lower(),
		])
	modal.set_dismissible(false)
	modal.add_button("🌀 Ascensionner", func() -> void:
		var points := GameManager.perform_prestige()
		if points > 0:
			Audio.play("prestige")
			Toast.push(_toast_layer, "+%d %s" % [points, GameManager.config.prestige_name], "gold")
		modal.close()
		_refresh_page(PAGE_PRESTIGE)
	, UITheme.GOLD.darkened(0.2))
	modal.add_button("Annuler", modal.close, UITheme.PANEL_ALT)


# ==================================================================== page succès

func _build_achievements_page() -> void:
	var box: VBoxContainer = _page_boxes(PAGE_ACHIEVEMENTS)
	box.add_child(_section_header("Succès",
		"Des récompenses permanentes, que rien ne peut reprendre — pas même une ascension."))
	var rows: Dictionary = {}
	for a in GameManager.config.achievements:
		var id := str(a.get("id", ""))
		var row := _make_row(id)
		row.title.text = "%s %s" % [str(a.get("icon", "")), str(a.get("name", id))]
		box.add_child(row.root)
		rows[id] = row
	_page_data[PAGE_ACHIEVEMENTS] = {"rows": rows}


## Description lisible d'une récompense de succès.
func _achievement_reward_text(a: Dictionary) -> String:
	var value := float(a.get("reward_value", 0.0))
	match str(a.get("reward_type", "")):
		"resources":
			return "+%s %s" % [BigNum.from_float(value).format_short(), GameManager.config.resource_name]
		"production_mult":
			return "Production %s" % Fmt.multiplier(value)
		"click_power":
			return "+%s par clic" % BigNum.from_float(value).format_short()
		"prestige_points":
			return "+%d %s" % [int(value), GameManager.config.prestige_name]
	return ""


func _refresh_achievements() -> void:
	var rows: Dictionary = _page_data.get(PAGE_ACHIEVEMENTS, {}).get("rows", {})
	var unlocked := 0
	for a in GameManager.config.achievements:
		var id := str(a.get("id", ""))
		var row: Row = rows.get(id)
		if row == null:
			continue
		var reward := _achievement_reward_text(a)
		if GameManager.is_achievement_unlocked(id):
			unlocked += 1
			row.subtitle.text = "%s\n✅ Débloqué — %s" % [str(a.get("desc", "")), reward]
			row.button.text = "✅"
			row.button.disabled = true
			row.root.add_theme_stylebox_override("panel", UITheme.card(UITheme.SUCCESS))
		else:
			row.subtitle.text = "%s\n🔒 Récompense : %s" % [str(a.get("desc", "")), reward]
			row.button.text = "🔒"
			row.button.disabled = true
			row.root.add_theme_stylebox_override("panel", UITheme.card_disabled())
	if _achievements_button != null:
		_achievements_button.text = "🏆 %d/%d" % [unlocked, GameManager.config.achievements.size()]


# =================================================================== page boutique

func _build_store_page() -> void:
	var box: VBoxContainer = _page_boxes(PAGE_STORE)
	box.add_child(_section_header("Boutique",
		"Achat entièrement optionnel. Le jeu est complet et gratuit sans rien payer : "
		+ "tout ce qui est ici est un raccourci, jamais un verrou."))
	var rows: Dictionary = {}
	for p in GameManager.config.store_products:
		var id := str(p.get("id", ""))
		var row := _make_row(id)
		row.title.text = str(p.get("name", id))
		row.subtitle.text = str(p.get("description", ""))
		row.button.pressed.connect(func() -> void: Store.request_purchase(id))
		box.add_child(row.root)
		rows[id] = row
	_page_data[PAGE_STORE] = {"rows": rows}

	# Restauration des achats.
	#
	# `StoreService.restore_purchases()` existait, était correct, était testé —
	# et n'avait AUCUN point d'entrée dans l'interface. Son seul appelant dans
	# tout le projet était la suite de tests. C'est un motif de refus de la revue
	# (guideline 3.1.1, « restauration des achats » doit être accessible à
	# l'utilisateur) et un vrai piège pour le joueur : réinstallation, changement
	# d'appareil, achat sur l'ancien iPad — sans bouton, les droits sont perdus.
	#
	# Le bouton n'est pas masqué en mode simulation : la restauration y est réelle
	# pour les achats déjà enregistrés dans l'état local, donc la simuler serait
	# pire que ne rien faire.
	var restore := _make_row("restore")
	restore.title.text = "♻️ Restaurer mes achats"
	restore.subtitle.text = ("Réinstallez l'application, changez d'appareil, ou changez "
		+ "d'Apple ID : vos achats reviennent sans repayer.")
	restore.button.text = "♻️ Restaurer"
	restore.button.pressed.connect(func() -> void: Store.restore_purchases())
	box.add_child(restore.root)
	rows["restore"] = restore

	var note := Label.new()
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_color_override("font_color", UITheme.MUTED)
	note.add_theme_font_size_override("font_size", 14)
	note.text = ("Mode simulation : aucun paiement n'est encaissé. En production, un vrai "
		+ "SDK (StoreKit) prend le relais via le plugin « IdleStore ». Voir README.md.")
	box.add_child(note)


func _refresh_store() -> void:
	var rows: Dictionary = _page_data[PAGE_STORE].get("rows", {})
	for p in GameManager.config.store_products:
		var id := str(p.get("id", ""))
		var row: Row = rows.get(id)
		if row == null:
			continue
		var price := Store.get_display_price(id)
		var badge := str(p.get("badge", ""))
		row.button.text = price if badge.is_empty() else "%s  %s" % [price, badge]
		var owned: bool = Store.is_purchased(id)
		row.button.disabled = owned or not Store.can_purchase(id)
		row.root.add_theme_stylebox_override("panel",
			UITheme.card(UITheme.SUCCESS) if owned else UITheme.card())


# ================================================================= page réglages

func _build_settings_page() -> void:
	var box: VBoxContainer = _page_boxes(PAGE_SETTINGS)
	box.add_child(_section_header("Réglages", ""))

	var daily := _make_row("daily")
	daily.title.text = "🎁 Bonus quotidien"
	daily.button.pressed.connect(func() -> void:
		var amount := GameManager.claim_daily_bonus()
		if amount.is_zero():
			Toast.push(_toast_layer, "Pas encore disponible.", "warn")
		else:
			Audio.play("achievement")
			Toast.push(_toast_layer, "+%s %s" % [amount.format_short(), GameManager.config.resource_name], "gold")
		_refresh_settings()
	)
	# Le double par pub. `REWARD_DAILY_DOUBLE` existait dans AdService, était
	# compté, plafonné, et crédité par `_on_ad_completed()` — mais AUCUN bouton
	# ne l'atteignait. Le code entier était mort : la récompense, son compteur,
	# son plafond, et sa moitié de budget commun avec le double hors-ligne.
	var daily_double := _add_row_extra_button(daily)
	daily_double.pressed.connect(func() -> void:
		if not Ads.is_available(Ads.REWARD_DAILY_DOUBLE):
			Toast.push(_toast_layer, "Indisponible pour le moment.", "warn")
			return
		Ads.show_rewarded(Ads.REWARD_DAILY_DOUBLE)
	)
	box.add_child(daily.root)
	_settings_rows["daily"] = daily

	var boost := _make_row("boost")
	boost.title.text = "⚡ Boost de production"
	boost.subtitle.text = "Production ×%d pendant %d minutes." % [
		int(BOOST_AD_MULTIPLIER), int(BOOST_AD_MINUTES)]
	boost.button.pressed.connect(func() -> void:
		if not Ads.is_available(Ads.REWARD_PRODUCTION_BOOST):
			Toast.push(_toast_layer, "Indisponible pour le moment.", "warn")
			return
		Ads.show_rewarded(Ads.REWARD_PRODUCTION_BOOST)
	)
	box.add_child(boost.root)
	_settings_rows["boost"] = boost

	var freebies := _make_row("freebies")
	freebies.title.text = "🎬 Cadeau de bienvenue"
	freebies.subtitle.text = "5 minutes de production offertes."
	# Libellé posé ici et non dans _refresh_settings : sans valeur initiale, le
	# bouton s'affiche vide tant que l'onglet n'a pas été ouvert une fois.
	freebies.button.text = "🎬 Regarder"
	freebies.button.pressed.connect(func() -> void:
		if not Ads.is_available(Ads.REWARD_FREE_CRYSTALS):
			Toast.push(_toast_layer, "Indisponible pour le moment.", "warn")
			return
		Ads.show_rewarded(Ads.REWARD_FREE_CRYSTALS)
	)
	box.add_child(freebies.root)
	_settings_rows["freebies"] = freebies

	var ads := _make_row("ads")
	ads.title.text = "🎬 Pubs récompensées"
	ads.subtitle.text = "Désactivez-les si vous préférez jouer sans pub. Le jeu reste gratuit."
	ads.button.pressed.connect(func() -> void:
		GameManager.config.ads["enabled"] = not bool(GameManager.config.ads.get("enabled", true))
		# _configure_services() réapplique aussi le mode test AdMob et la
		# boutique : appeler Ads.configure() seul laisserait le plug-in dans son
		# état précédent.
		GameManager.call("_configure_services")
		_refresh_settings()
	)
	box.add_child(ads.root)
	_settings_rows["ads"] = ads

	var notif := _make_row("notif")
	notif.title.text = "🔔 Rappel hors-ligne"
	notif.button.pressed.connect(func() -> void:
		Notifications.set_enabled(not Notifications.enabled)
		_refresh_settings()
	)
	box.add_child(notif.root)
	_settings_rows["notif"] = notif

	var sound := _make_row("sound")
	sound.title.text = "🔊 Effets sonores"
	sound.button.pressed.connect(func() -> void:
		Audio.set_muted(not Audio.muted)
		if not Audio.muted:
			Audio.play("click")
		_refresh_settings()
	)
	box.add_child(sound.root)
	_settings_rows["sound"] = sound

	box.add_child(_section_header("Zone sensible", ""))
	var reset := _make_row("reset")
	reset.title.text = "💀 Réinitialiser la sauvegarde"
	reset.subtitle.text = "Efface définitivement la progression. Irréversible."
	reset.button.text = "⚠️"
	reset.button.add_theme_stylebox_override("normal", UITheme.box(UITheme.ERROR.darkened(0.25), 12, 10))
	reset.button.pressed.connect(_confirm_hard_reset)
	box.add_child(reset.root)

	var privacy := Label.new()
	privacy.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	privacy.add_theme_color_override("font_color", UITheme.MUTED)
	privacy.add_theme_font_size_override("font_size", 14)
	privacy.text = ("Modèle de jeu idle — Godot 4.7. Modèle de monétisation honnête : "
		+ "aucune donnée personnelle n'est collectée, aucun suivi comportemental, "
		+ "tout reste sur l'appareil. "
		+ "Les achats et les pubs sont strictement optionnels.")
	box.add_child(privacy)


func _refresh_settings() -> void:
	var daily: Row = _settings_rows.get("daily")
	if daily != null:
		var available := GameManager.is_daily_bonus_available()
		daily.subtitle.text = ("Une heure de production, une fois par 24 h." if available
			else "De nouveau disponible dans %s" % Fmt.duration(GameManager.get_daily_bonus_time_left()))
		daily.button.text = "🎁" if available else "⏳"
		daily.button.disabled = not available
		daily.root.add_theme_stylebox_override("panel",
			UITheme.card(UITheme.GOLD) if available else UITheme.card_disabled())
		# Le bouton « ×2 » est rafraîchi avec la ligne. Sans ce bloc, il restait
		# affiché tel qu'à la construction — donc « ×2 » actif après coupement
		# du budget, sur un bonus déjà encaissé.
		if daily.extra_button != null:
			daily.extra_button.text = "🎬 ×2"
			daily.extra_button.disabled = not (available
				and Ads.is_available(Ads.REWARD_DAILY_DOUBLE))

	var boost: Row = _settings_rows.get("boost")
	if boost != null:
		if GameManager.has_no_ads():
			boost.subtitle.text = "Indisponible : vous avez supprimé les pubs."
			boost.button.text = "🚫"
			boost.button.disabled = true
		else:
			var left := maxi(0, Ads.daily_cap(Ads.REWARD_PRODUCTION_BOOST)
				- Ads.get_daily_count(Ads.REWARD_PRODUCTION_BOOST))
			boost.subtitle.text = ("Production ×%d pendant %d minutes. Restant aujourd'hui : %d."
				% [int(BOOST_AD_MULTIPLIER), int(BOOST_AD_MINUTES), left])
			boost.button.text = "🎬 Regarder" if left > 0 else "✓"
			boost.button.disabled = left <= 0 or not Ads.is_available(Ads.REWARD_PRODUCTION_BOOST)

	var freebies: Row = _settings_rows.get("freebies")
	if freebies != null:
		if GameManager.has_no_ads():
			freebies.subtitle.text = "Indisponible : vous avez supprimé les pubs."
			freebies.button.text = "🚫"
			freebies.button.disabled = true
		else:
			var left := maxi(0, Ads.daily_cap(Ads.REWARD_FREE_CRYSTALS) - Ads.get_daily_count(Ads.REWARD_FREE_CRYSTALS))
			freebies.subtitle.text = "5 minutes de production offertes. Restant aujourd'hui : %d." % left
			freebies.button.text = "🎬 Regarder" if left > 0 else "✓"
			freebies.button.disabled = left <= 0 or not Ads.is_available(Ads.REWARD_FREE_CRYSTALS)
			freebies.root.add_theme_stylebox_override("panel",
				UITheme.card() if left > 0 else UITheme.card_disabled())

	var ads: Row = _settings_rows.get("ads")
	if ads != null:
		var on := bool(GameManager.config.ads.get("enabled", true))
		ads.button.text = "ON" if on else "OFF"
		if GameManager.has_no_ads():
			ads.subtitle.text = "Supprimées définitivement (achat « Supprimer les pubs »)."

	var notif: Row = _settings_rows.get("notif")
	if notif != null:
		var supported: bool = Notifications.is_supported()
		notif.button.text = "ON" if Notifications.enabled else "OFF"
		notif.button.disabled = not supported
		notif.subtitle.text = ("Programmée %s après être parti." % Fmt.duration(GameManager.get_offline_cap_hours() * 3600.0)
			if supported else
			"Indisponible : Godot 4 n'expose pas les notifications locales, "
			+ "un plugin natif iOS est nécessaire (voir README). "
			+ "Le jeu vous prévient déjà à chaque retour.")

	var sound: Row = _settings_rows.get("sound")
	if sound != null:
		sound.button.text = "OFF" if Audio.muted else "ON"


func _confirm_hard_reset() -> void:
	var modal := Modal.open(_overlay_layer, "💀 Tout effacer ?",
		("Toute votre progression sera définitivement perdue : ressources, bâtiments, "
			+ "recherche, succès, %s.\n\nCette action est irréversible." % GameManager.config.prestige_name))
	modal.set_dismissible(false)
	modal.add_button("💀 Oui, tout effacer", func() -> void:
		GameManager.hard_reset()
		modal.close()
	, UITheme.ERROR.darkened(0.12))
	modal.add_button("Annuler", modal.close, UITheme.PANEL_ALT)


# =============================================================== popup hors-ligne

## Ferme toutes les modales ouvertes.
##
## Utilisé après une remise à zéro : une popup de gains hors-ligne encore
## affichée proposerait de réclamer un solde qui n'existe plus.
func _close_all_modals() -> void:
	for child in _overlay_layer.get_children():
		if child is Modal:
			(child as Modal).close()


## Réception de `GameManager.offline_gains_pending` : le joueur revient au premier
## plan après une absence assez longue pour mériter une popup.
##
## Deux gardes : ne pas empiler une popup sur une popup, et ne pas interrompre
## une modale en cours (une confirmation d'achat, par exemple). Dans les deux cas
## les gains ne sont pas perdus — ils restent en attente, sont persistés, et la
## popup reviendra au prochain retour au premier plan.
func _on_offline_gains_pending(_elapsed: float, _amount: BigNum) -> void:
	if not GameManager.has_pending_offline():
		return
	if _is_modal_open():
		# Une modale est déjà à l'écran. La fermer ici détruirait ce que le
		# joueur est en train de décider ; on attend le prochain retour au
		# premier plan, où la popup sera proposée de nouveau.
		return
	_show_offline_popup()


func _is_modal_open() -> bool:
	for child in _overlay_layer.get_children():
		if child is Modal and (child as Modal).is_open():
			return true
	return false


func _show_offline_popup() -> void:
	# Garde-fou : sans gains en attente, la popup proposerait « Collecter 0 ».
	# Elle est donc refusée plutôt que d'afficher un montant vide.
	if not GameManager.has_pending_offline():
		return
	var pending := GameManager.get_pending_offline()
	var amount: BigNum = pending.get("amount", BigNum.zero())
	var elapsed := float(pending.get("elapsed", 0.0))
	var capped := bool(pending.get("capped", false))
	var no_ads := GameManager.has_no_ads()
	var can_watch_ad: bool = Ads.is_available(Ads.REWARD_OFFLINE_DOUBLE)

	var body := "Vous étiez absent·e pendant %s.\nVos %s continuaient de produire." % [
		Fmt.duration(elapsed), GameManager.config.resource_name.to_lower()]
	if capped:
		body += ("\n\nPlafond hors-ligne atteint (%s). La recherche « Serveurs de sauvegarde » "
			+ "l'augmente jusqu'à %s.") % [
			Fmt.duration(GameManager.get_offline_cap_hours() * 3600.0),
			Fmt.duration(GameManager.get_offline_cap_hours() * 3600.0),
		]

	var modal := Modal.open(_overlay_layer, "👋 Bon retour !", body)
	modal.set_dismissible(false)

	# Le gain réel est affiché avant toute proposition de pub : on ne cache jamais
	# la récompense pour créer un sentiment d'urgence artificiel.
	modal.add_button("💎 Collecter %s" % amount.format_short(), func() -> void:
		var gained := GameManager.claim_offline_gains(false)
		modal.close()
		Audio.play("offline")
		Toast.push(_toast_layer, "+%s %s" % [gained.format_short(), GameManager.config.resource_name], "gold")
		_refresh_header()
	, UITheme.ACCENT)

	if no_ads:
		# Le joueur a payé pour supprimer les pubs : le double devient gratuit.
		modal.add_button("💎💎 Double gratuit", func() -> void:
			var gained := GameManager.claim_offline_gains(true)
			modal.close()
			Toast.push(_toast_layer, "+%s %s (×2)" % [gained.format_short(), GameManager.config.resource_name], "gold")
			_refresh_header()
		, UITheme.GOLD.darkened(0.2))
	elif can_watch_ad:
		modal.add_button("🎬 Voir une pub → doubler", func() -> void:
			modal.close()
			Ads.show_rewarded(Ads.REWARD_OFFLINE_DOUBLE)
		, UITheme.PANEL_ALT)

	modal.add_button("Plus tard", func() -> void:
		# Rien n'est crédité, et c'est le bon choix : c'est ce qui rend le
		# double comptage impossible. Les gains restent en attente, et ils sont
		# désormais PERSISTÉS — ils survivent à la fermeture de l'app et la popup
		# réapparaîtra au prochain lancement.
		#
		# L'ancien commentaire affirmait ici que « la période sera intégralement
		# recalculée au prochain lancement ». C'était faux : `last_save_timestamp`
		# avait déjà été avancé, et `save_game()` le pousse encore à maintenant.
		# Rien n'était recalculé, et les gains disparaissaient.
		modal.close()
	, UITheme.DISABLED)


# ====================================================================== achats

func _show_purchase_confirm(product_id: String) -> void:
	var p: Dictionary = Store.get_product(product_id)
	if p.is_empty():
		return
	# Prix fourni par l'App Store quand le SDK est branché, sinon celui du
	# catalogue de simulation. Afficher le prix du JSON en production est un
	# motif de refus de la revue : il ne suit ni la devise ni le pays.
	var price := Store.get_display_price(product_id)
	var modal := Modal.open(_overlay_layer, str(p.get("name", product_id)),
		("%s\n\nPrix : %s\n\nLe jeu reste entièrement jouable et gratuit sans cet achat.") % [
			str(p.get("description", "")), price])
	modal.set_dismissible(false)
	# L'action principale et l'annulation sont côte à côte, même poids visuel.
	#
	# `submit_purchase()` et non la méthode d'achat directe : c'est ce bouton
	# qui valide l'achat, la feuille StoreKit ne doit donc s'ouvrir qu'ici.
	# L'ancien code n'utilisait le chemin direct qu'en mode plugin, et ce chemin
	# envoyait au SDK sans passer par cette confirmation — donc le bouton d'un
	# produit ouvrait la feuille de paiement au premier tap, et la confirmation
	# n'existait qu'en simulation.
	modal.add_button("Acheter — %s" % price, func() -> void:
		modal.close()
		Store.submit_purchase(product_id)
	, UITheme.SUCCESS.darkened(0.18))
	modal.add_button("Annuler", modal.close, UITheme.PANEL_ALT)


func _on_purchase_completed(product_id: String) -> void:
	var p: Dictionary = Store.get_product(product_id)
	Audio.play("achievement")
	Toast.push(_toast_layer, "%s acheté !" % str(p.get("name", product_id)), "success")
	_refresh_page(_current_page)


func _on_purchase_failed(_product_id: String, reason: String) -> void:
	if reason == "rien à restaurer":
		return
	Toast.push(_toast_layer, "Achat impossible : %s" % reason, "error")


func _on_store_products_loaded(_count: int) -> void:
	# Les prix localisés n'existent qu'après le retour asynchrone de StoreKit. La
	# boutique est donc désactivée jusque-là, puis rafraîchie pour rendre les
	# produits achetables avec leur vrai prix — jamais celui du JSON. Le même
	# signal débloque la consultation des droits et des pubs; si les réglages
	# étaient déjà ouverts, leurs boutons doivent aussi être réactivés.
	_refresh_page(PAGE_STORE)
	_refresh_settings()


# ========================================================================== pubs

func _on_ad_completed(reward_id: String) -> void:
	match reward_id:
		Ads.REWARD_OFFLINE_DOUBLE:
			# `claim_offline_gains()` rend `zero` s'il n'y a plus rien en
			# attente, et le joueur peut très bien en être là : il a regardé la
			# pub depuis le popup, il a été mis en arrière-plan pendant ce temps,
			# une popup est apparue à son retour, il l'a encaissée — et le
			# `ad_completed` de la pub n'arrive qu'ensuite, sur des gains déjà
			# consommés. Sans cette garde, l'écran affichait « ×2 !  +0 💎 »,
			# avec le son de récompense et un « ×2 » flottant : une récompense
			# déjà obtenue ailleurs, et facturée par une pub que le joueur venait
			# de regarder. Les deux autres appelants de la popup testaient déjà
			# `has_pending_offline()` ; celui-ci ne le faisait pas.
			if GameManager.has_pending_offline():
				var gained := GameManager.claim_offline_gains(true)
				Audio.play("achievement")
				Toast.push(_toast_layer, "×2 !  +%s %s" % [gained.format_short(), GameManager.config.resource_name], "gold")
				FloatingNumber.spawn(_floating_layer, _screen_center(), "×2", UITheme.GOLD, 36)
			else:
				Toast.push(_toast_layer, "Ces gains ont déjà été encaissés.", "warn")
		Ads.REWARD_PRODUCTION_BOOST:
			GameManager.grant_temporary_boost(BOOST_AD_MULTIPLIER, BOOST_AD_MINUTES / 60.0)
		Ads.REWARD_DAILY_DOUBLE:
			# Même raison : le bonus quotidien peut avoir été encaissé entre le
			# lancement de la pub et la fin de celle-ci.
			if GameManager.is_daily_bonus_available():
				var bonus := GameManager.claim_daily_bonus(true)
				Toast.push(_toast_layer, "Bonus ×2 : +%s" % bonus.format_short(), "gold")
			else:
				Toast.push(_toast_layer, "Bonus quotidien déjà encaissé aujourd'hui.", "warn")
		Ads.REWARD_FREE_CRYSTALS:
			var amount := GameManager.get_production_per_sec().mul_float(FREE_CRYSTALS_AD_SECONDS)
			GameManager.grant_resources(amount, true)
			Toast.push(_toast_layer, "+%s %s" % [amount.format_short(), GameManager.config.resource_name], "gold")
	_refresh_header()
	_refresh_settings()


func _on_ad_failed(_reward_id: String, reason: String) -> void:
	Toast.push(_toast_layer, "Pub : %s" % reason, "warn")


# ======================================================================== retour

func _on_message(text: String, kind: String) -> void:
	Toast.push(_toast_layer, text, kind)


func _on_achievement_unlocked(id: String, reward_text: String) -> void:
	var a := GameManager.config.achievement(id)
	Audio.play("achievement")
	Toast.push(_toast_layer, "🏆 %s — %s" % [str(a.get("name", id)), reward_text], "gold")
	_refresh_achievements()


func _on_combo_changed(stacks: int, multiplier: float) -> void:
	_combo_label.visible = stacks > 1
	if stacks > 1:
		_combo_label.text = "🔥 Combo %d  ·  %s" % [stacks, Fmt.multiplier(multiplier)]


func _on_game_reset() -> void:
	# Les gains hors-ligne sont annules par la remise a zero : toute popup
	# encore ouverte afficherait un montant qui n'existe plus.
	_close_all_modals()
	_daily_bonus_available_state = GameManager.is_daily_bonus_available()
	_refresh_header()
	_refresh_achievements()
	_refresh_page(_current_page)
	Toast.push(_toast_layer, "Partie réinitialisée.", "warn")


func _on_daily_bonus_changed(available: bool) -> void:
	# Le signal est émis au retour au premier plan et après l'encaissement. Sans
	# l'écouter, une page Réglages ouverte gardait le bouton désactivé après que
	# les 24 h étaient écoulées; et un joueur hors de cette page n'était jamais
	# informé du bonus devenu disponible.
	var became_available := available and not _daily_bonus_available_state
	_daily_bonus_available_state = available
	if _current_page == PAGE_SETTINGS:
		_refresh_settings()
	if became_available and GameManager.is_daily_bonus_available() \
			and not GameManager.has_pending_offline() and not _is_modal_open():
		Toast.push(_toast_layer, "🎁 Bonus quotidien disponible dans Réglages", "gold")


# ====================================================================== en-tête

func _refresh_header() -> void:
	var prod := GameManager.get_production_per_sec()
	_resource_label.text = "%s %s" % [
		GameManager.current_resources.format_short(), GameManager.config.resource_icon]
	_rate_label.text = "+%s/s  ·  +%s/clic" % [
		prod.format_short(), GameManager.get_click_power().format_short()]

	if GameManager.is_boost_active():
		var remaining := GameManager.get_boost_remaining()
		_boost_bar.visible = true
		_boost_bar.max_value = GameManager.get_boost_total()
		_boost_bar.value = remaining
		_rate_label.text += "   ⚡ ×%s  %s" % [
			Fmt.number(GameManager.boost_multiplier), Fmt.duration(remaining)]
	else:
		_boost_bar.visible = false


# ======================================================================= outils

func _page_boxes(page_name: String) -> VBoxContainer:
	var scroll: ScrollContainer = _pages[page_name]
	return scroll.get_child(0) as VBoxContainer


func _make_row(id: String) -> Row:
	var row := Row.new()
	row.id = id
	row.root = PanelContainer.new()
	row.root.add_theme_stylebox_override("panel", UITheme.card())
	row.root.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	row.root.add_child(line)

	var texts := VBoxContainer.new()
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	texts.add_theme_constant_override("separation", 3)
	line.add_child(texts)

	row.title = Label.new()
	row.title.add_theme_font_size_override("font_size", 17)
	row.title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	texts.add_child(row.title)

	row.subtitle = Label.new()
	row.subtitle.add_theme_font_size_override("font_size", 14)
	row.subtitle.add_theme_color_override("font_color", UITheme.MUTED)
	row.subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	texts.add_child(row.subtitle)

	row.button = Button.new()
	row.button.custom_minimum_size = Vector2(112, 48)
	row.button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.button.clip_text = true
	row.button.add_theme_font_size_override("font_size", 15)
	line.add_child(row.button)

	return row


## Ajoute un second bouton à une ligne existante. La ligne la plus large, donc
## les titres qui se wraps, sont gérés par l'autowrap du label.
func _add_row_extra_button(row: Row) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(112, 48)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.clip_text = true
	btn.add_theme_font_size_override("font_size", 15)
	row.button.get_parent().add_child(btn)
	row.extra_button = btn
	return btn


func _section_header(title: String, subtitle: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var heading := Label.new()
	heading.text = title
	heading.add_theme_font_size_override("font_size", 21)
	heading.add_theme_color_override("font_color", UITheme.GOLD)
	box.add_child(heading)
	if not subtitle.is_empty():
		var sub := Label.new()
		sub.text = subtitle
		sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sub.add_theme_font_size_override("font_size", 14)
		sub.add_theme_color_override("font_color", UITheme.MUTED)
		box.add_child(sub)
	return box


func _screen_center() -> Vector2:
	return Vector2(size.x * 0.5, size.y * 0.42)
