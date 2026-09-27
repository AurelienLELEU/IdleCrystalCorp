extends SceneTree

## Vérifie que rien ne sort de l'écran, encoche ou pas.
##
##   ./tests/run.sh res://tests/test_safe_area.gd
##
## Le défaut que ce test traque : un `CenterContainer` centre son enfant à sa
## taille MINIMALE. Dès que la carte dépasse la hauteur disponible, il la place
## à un offset NÉGATIF, et les deux bouts sortent de l'écran à parts égales. Sur
## un iPhone, le haut part sous l'encoche et le bas sous l'indicateur
## d'accueil : le texte paraît tronqué aux deux extrémités, sans qu'aucun
## indice ne dise qu'il y en a plus. Ni la compilation, ni `--import`, ni un
## test qui vérifie seulement « la popup s'affiche » ne le révèlent.
##
## Le test mesure donc la position réelle de la carte dans un viewport de taille
## connue, y compris en simulant une encoche (120 en haut, 90 en bas : l'ordre
## de grandeur d'un iPhone 15 Pro en portrait), et vérifie que la carte reste
## entière dans la zone visible.
##
## Il vérifie aussi le CENTRAGE, pas seulement la présence : une carte plaquée
## en haut de l'écran reste « dans les limites » et passerait un simple test de
## visibilité, alors que le joueur voit un bandeau au lieu d'une boîte de
## dialogue.

const VIEWPORT_W := 390.0
const VIEWPORT_H := 844.0

## Encoche simulée : iPhone 15 Pro, portrait, barre d'état et indicateur
## d'accueil en mode classique.
const NOTCH := {"left": 0.0, "top": 120.0, "right": 0.0, "bottom": 90.0}
const LANDSCAPE_NOTCH := {"left": 90.0, "top": 0.0, "right": 0.0, "bottom": 0.0}

## Tolérance en pixels. Un arrondi de `MarginContainer` suffit à faire varier la
## mesure d'une unité ; prétendre à l'égalité parfaite testerait l'arrondi, pas
## la mise en page.
const EPS := 1.5

var _failures: int = 0
var _host: Control


func _initialize() -> void:
	print("=== test_safe_area ===")
	_run()


func _run() -> void:
	await process_frame
	await process_frame

	_test_defaults()
	_test_headless_is_neutral()
	await _test_anchors_preset_trap()
	await _test_write_is_idempotent()
	await _test_modal_fits_screen()
	await _test_modal_is_centred()
	await _test_modal_under_notch()
	await _test_modal_too_tall_under_notch()
	await _test_modal_too_tall_no_notch()
	await _test_no_invisible_container()
	await _test_mock_ad_overlay()
	await _test_combo_label_stays_usable()

	quit(1 if _failures > 0 else 0)


# ================================================================ zone sûre

func _test_defaults() -> void:
	var i := SafeArea.insets_for(null)
	_check(i["top"] == SafeArea.MIN_TOP + SafeArea.COMFORT_TOP,
		"marge haute de repli = MIN_TOP + COMFORT_TOP (%.0f)" % i["top"])
	_check(i["bottom"] == SafeArea.MIN_BOTTOM + SafeArea.COMFORT_BOTTOM,
		"marge basse de repli = MIN_BOTTOM + COMFORT_BOTTOM (%.0f)" % i["bottom"])
	_check(i["left"] == SafeArea.MIN_SIDE and i["right"] == SafeArea.MIN_SIDE,
		"marges latérales de repli symétriques (%.0f)" % i["left"])
	_check(SafeArea.COMFORT_TOP > 0.0 and SafeArea.COMFORT_BOTTOM > 0.0,
		"un offset haut ET un offset bas sont définis, comme demandé")


func _test_headless_is_neutral() -> void:
	# La suite doit être déterministe : aucun appareil, donc aucun inset
	# imprévisible. Si la plateforme rapportait déjà quelque chose en headless,
	# toutes les mesures ci-dessous dépendraient de la machine.
	_check(DisplayServer.get_name() == "headless", "la suite tourne bien en headless")
	var vp: Viewport = root
	var i := SafeArea.insets_for(vp)
	_check(is_equal_approx(float(i["top"]), SafeArea.MIN_TOP + SafeArea.COMFORT_TOP),
		"headless : marge haute retombée sur MIN_TOP + COMFORT_TOP")
	_check(is_equal_approx(float(i["bottom"]), SafeArea.MIN_BOTTOM + SafeArea.COMFORT_BOTTOM),
		"headless : marge basse retombée sur MIN_BOTTOM + COMFORT_BOTTOM")


# ==================================================== écriture des marges

func _test_write_is_idempotent() -> void:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 12)
	m.add_theme_constant_override("margin_top", 10)
	m.add_theme_constant_override("margin_right", 12)
	m.add_theme_constant_override("margin_bottom", 10)
	root.add_child(m)
	await process_frame

	SafeArea.write(m, NOTCH)
	_check(m.get_theme_constant("margin_left") == 12,
		"les marges de la scène sont conservées à gauche (12)")
	_check(m.get_theme_constant("margin_top") == 10 + int(NOTCH["top"]),
		"l'inset s'AJOUTE à la marge de la scène en haut (%d = 10 + %d)"
			% [m.get_theme_constant("margin_top"), int(NOTCH["top"])])
	_check(m.get_theme_constant("margin_bottom") == 10 + int(NOTCH["bottom"]),
		"l'inset s'AJOUTE à la marge de la scène en bas")

	# Écritures répétées : sans mémorisation des marges d'origine, l'inset
	# serait compté deux fois, puis trois.
	SafeArea.write(m, NOTCH)
	SafeArea.write(m, NOTCH)
	_check(m.get_theme_constant("margin_top") == 10 + int(NOTCH["top"]),
		"trois écritures ne cumulent pas les insets (%d)" % m.get_theme_constant("margin_top"))
	_check(m.get_theme_constant("margin_left") == 12,
		"trois écritures ne cumulent pas les côtés")

	m.queue_free()
	await process_frame


# ============================================================== carte réelle

## Ouvre une modale réelle dans un conteneur de taille imposée.
func _open_modal(body: String, buttons: int) -> Modal:
	if _host != null and is_instance_valid(_host):
		_host.queue_free()
		await process_frame

	# Le viewport racine fait 1280x1280 en headless. On passe par un conteneur
	# de la taille d'un téléphone pour que les mesures soient celles visées.
	_host = Control.new()
	root.add_child(_host)
	_host.position = Vector2.ZERO
	_host.size = Vector2(VIEWPORT_W, VIEWPORT_H)
	await process_frame

	var modal := Modal.new()
	_host.add_child(modal)
	modal.configure("👋 Bon retour !", body)
	for i in buttons:
		modal.add_button("bouton %d" % i, func() -> void: pass)
	# Deux frames : la première construit l'arbre, la seconde laisse la mise en
	# page se propager jusqu'à la taille réelle de la carte.
	await process_frame
	await process_frame
	return modal


## Le `MarginContainer` de zone sûre du composant Modal.
func _safe_of(modal: Modal) -> MarginContainer:
	return modal.get("_safe") as MarginContainer


## Rectangle de la carte, en coordonnées écran.
func _rect(node: Control) -> Dictionary:
	if node == null or not node.is_inside_tree():
		return {}
	return {
		"x": node.global_position.x,
		"y": node.global_position.y,
		"w": node.size.x,
		"h": node.size.y,
		"bottom": node.global_position.y + node.size.y,
		"right": node.global_position.x + node.size.x,
	}


## Applique une encoche simulée par le chemin exact de la production.
func _apply_notch(modal: Modal) -> void:
	SafeArea.write(_safe_of(modal), NOTCH)
	await process_frame
	await process_frame


func _test_modal_fits_screen() -> void:
	var modal := await _open_modal("Vous étiez absent·e pendant 2 h 04 min.", 3)
	var card := _rect(modal.get("_card") as Control)
	_check(not card.is_empty(), "la carte a une géométrie")
	if card.is_empty():
		return
	_check(card["x"] >= -EPS and card["y"] >= -EPS,
		"popup courte : rien ne sort en haut ni à gauche (%.0f, %.0f)" % [card["x"], card["y"]])
	_check(card["right"] <= VIEWPORT_W + EPS and card["bottom"] <= VIEWPORT_H + EPS,
		"popup courte : rien ne sort en bas ni à droite (%.0f, %.0f pour %.0f, %.0f)"
			% [card["right"], card["bottom"], VIEWPORT_W, VIEWPORT_H])
	modal.queue_free()
	await process_frame


func _test_modal_is_centred() -> void:
	var modal := await _open_modal("Texte court.", 2)
	var card := _rect(modal.get("_card") as Control)
	var area := _rect(_safe_of(modal))
	if card.is_empty() or area.is_empty():
		_check(false, "géométrie disponible pour le centrage")
		return

	var card_center_x: float = card["x"] + card["w"] * 0.5
	var area_center_x: float = area["x"] + area["w"] * 0.5
	_check(absf(card_center_x - area_center_x) <= EPS,
		"centrée horizontalement (%.1f pour %.1f)" % [card_center_x, area_center_x])

	# Verticale : centrée entre les deux marges, et PAS au milieu de l'écran.
	# C'est toute la différence entre une boîte de dialogue et un bandeau.
	var card_center_y: float = card["y"] + card["h"] * 0.5
	var area_center_y: float = area["y"] + area["h"] * 0.5
	_check(absf(card_center_y - area_center_y) <= EPS,
		"centrée verticalement dans la zone utile (%.1f pour %.1f)" % [card_center_y, area_center_y])
	_check(card["y"] >= area["y"] - EPS, "la marge haute est respectée (%.0f >= %.0f)"
		% [card["y"], area["y"]])
	_check(card["bottom"] <= area["bottom"] + EPS, "la marge basse est respectée (%.0f <= %.0f)"
		% [card["bottom"], area["bottom"]])

	# La largeur est bornée : sans cela, sur une tablette le texte s'étire sur
	# 1000 px de large et devient illisible en un coup d'œil.
	_check(card["w"] <= Modal.CARD_MAX_WIDTH + EPS,
		"la carte est bornée à CARD_MAX_WIDTH (%.0f <= %.0f)" % [card["w"], Modal.CARD_MAX_WIDTH])
	_check(card["w"] > 0.0, "la carte a une largeur non nulle (%.0f)" % card["w"])

	modal.queue_free()
	await process_frame


func _test_modal_under_notch() -> void:
	var modal := await _open_modal("Texte court.", 2)
	await _apply_notch(modal)
	var card := _rect(modal.get("_card") as Control)
	if card.is_empty():
		_check(false, "géométrie disponible sous encoche")
		return

	var top_limit: float = float(NOTCH["top"])
	var bottom_limit: float = VIEWPORT_H - float(NOTCH["bottom"])
	_check(card["y"] >= top_limit - EPS,
		"sous encoche : le haut reste visible (%.0f >= %.0f)" % [card["y"], top_limit])
	_check(card["bottom"] <= bottom_limit + EPS,
		"sous encoche : le bas reste visible (%.0f <= %.0f)" % [card["bottom"], bottom_limit])

	# Centrée dans l'espace RESTANT, pas au milieu de l'écran : c'est ce qui
	# que l'œil attend, et ce que le centrage naïf ne fait pas.
	var space_center: float = (top_limit + bottom_limit) * 0.5
	_check(absf((card["y"] + card["h"] * 0.5) - space_center) <= EPS,
		"sous encoche : centrée dans l'espace restant (%.1f pour %.1f)"
			% [card["y"] + card["h"] * 0.5, space_center])

	modal.queue_free()
	await process_frame


func _test_modal_too_tall_under_notch() -> void:
	# Un texte à rallonge, c'est le cas qui faisait déborder avant : la carte
	# dépassait, le CenterContainer la sortait par le haut ET par le bas.
	var modal := await _open_modal(_long_body(), 4)
	await _apply_notch(modal)
	var card := _rect(modal.get("_card") as Control)
	if card.is_empty():
		_check(false, "géométrie disponible pour le texte long")
		return

	var top_limit: float = float(NOTCH["top"])
	var bottom_limit: float = VIEWPORT_H - float(NOTCH["bottom"])
	_check(card["h"] > bottom_limit - top_limit,
		"le cas testé dépasse bien la zone visible (%.0f > %.0f)"
			% [card["h"], bottom_limit - top_limit])
	_check(card["y"] >= top_limit - EPS,
		"même trop longue, la carte ne passe pas sous l'encoche (y = %.0f, limite = %.0f)"
			% [card["y"], top_limit])

	# Elle déborde par le bas, ce qui est le bon comportement : c'est le
	# ScrollContainer qui prend le relais, et l'utilisateur voit qu'il y a plus.
	var scroll := modal.get("_scroll") as ScrollContainer
	_check(scroll != null, "un ScrollContainer prend le relais quand ça déborde")
	if scroll != null:
		_check(scroll.vertical_scroll_mode == ScrollContainer.SCROLL_MODE_AUTO,
			"le défilement vertical est automatique")
		_check(scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED,
			"pas de défilement horizontal : la largeur reste celle de la zone sûre")
		await process_frame
		_check(scroll.get_v_scroll_bar().visible,
			"la barre de défilement apparaît, l'utilisateur voit qu'il reste du texte")

	modal.queue_free()
	await process_frame


func _test_modal_too_tall_no_notch() -> void:
	var modal := await _open_modal(_long_body(), 4)
	await process_frame
	var card := _rect(modal.get("_card") as Control)
	var area := _rect(_safe_of(modal))
	var scroll := _rect(modal.get("_scroll") as Control)
	if card.is_empty() or area.is_empty() or scroll.is_empty():
		_check(false, "géométrie disponible pour le texte long sans encoche")
		return

	# Ici, la carte DÉBORDE volontairement vers le bas : c'est le rôle du
	# ScrollContainer. Ce qui est interdit, c'est que la fenêtre de défilement
	# elle-même sorte de l'écran, ou que le contenu commence au-dessus du haut.
	# Vérifier « le bas de la carte est dans l'écran » serait faux, et le serait
	# doublement : ça décourageait la seule solution correcte, à savoir
	# défiler.
	_check(scroll["y"] >= -EPS and scroll["bottom"] <= VIEWPORT_H + EPS,
		"la fenêtre de défilement reste dans l'écran (%.0f..%.0f pour %.0f)"
			% [scroll["y"], scroll["bottom"], VIEWPORT_H])
	_check(card["y"] >= area["y"] - EPS,
		"le contenu démarre sous la marge haute, jamais au-dessus (%.0f >= %.0f)"
			% [card["y"], area["y"]])
	_check(card["y"] < VIEWPORT_H, "le début du texte est visible à l'écran")
	modal.queue_free()
	await process_frame


## Corps de texte assez long pour dépasser n'importe quel téléphone.
func _long_body() -> String:
	var lines: PackedStringArray = PackedStringArray()
	for i in range(16):
		lines.append("Ligne %02d : production, stockage, recherche et énergie "
			% i + "avec assez de texte pour provoquer un retour à la ligne sur un écran étroit.")
	return "\n".join(lines)


# ==================================== le piège set_anchors_preset, et ses suites

## `set_anchors_preset(PRESET_FULL_RECT)` ne fait pas étirer un contrôle, il
## conserve son rectangle courant en compensant les offsets. Appelé APRÈS
## `add_child` — donc avec un parent déjà dimensionné — il donne une taille
## NULLE, et tout ce qu'il contient devient invisible.
##
## Le cas est si trompeur qu'il faut le vérifier dans les deux sens : une
## assertion qui passe toujours est pire qu'absente, parce qu'elle donne une
## fausse assurance sur un piège qui, lui, n'agit que dans un seul sens.
func _test_anchors_preset_trap() -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	await process_frame

	var before := Control.new()
	before.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(before)
	await process_frame
	_check(before.size.x > 0.0 and before.size.y > 0.0,
		"set_anchors_preset AVANT add_child : étiré quand même (%.0f x %.0f)"
			% [before.size.x, before.size.y])

	var after := Control.new()
	layer.add_child(after)
	after.set_anchors_preset(Control.PRESET_FULL_RECT)
	await process_frame
	_check(after.size.x == 0.0 and after.size.y == 0.0,
		"set_anchors_preset APRES add_child : taille nulle, comme le veut le piège (%.0f x %.0f)"
			% [after.size.x, after.size.y])

	var good := Control.new()
	layer.add_child(good)
	good.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame
	_check(good.size.x > 0.0 and good.size.y > 0.0,
		"set_anchors_and_offsets_preset : étiré dans les deux cas (%.0f x %.0f)"
			% [good.size.x, good.size.y])

	before.queue_free()
	after.queue_free()
	good.queue_free()
	layer.queue_free()
	await process_frame


## Aucun conteneur de premier niveau de l'écran ne doit avoir une taille nulle.
## Une taille nulle ne lève aucune erreur : le controle existe, ses enfants
## existent, les tests fonctionnels qui l'appellent directement passent -- et
## l'utilisateur ne voit rien.
func _test_no_invisible_container() -> void:
	var packed: PackedScene = load("res://scenes/Main.tscn")
	if packed == null:
		_check(false, "Main.tscn se charge")
		return
	var scene: Node = packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	var host: Control = scene.get_node_or_null("Root/Layout/Pages/PageHost")
	_check(host != null and host.size.x > 0.0 and host.size.y > 0.0,
		"l'hôte des pages a une taille non nulle")

	# Les pages n'existent qu'une fois rendues visibles : un conteneur invisible
	# n'est pas mis en page, et sa mesure serait celle d'avant le premier
	# affichage. Sans ce passage en visible, ce test mesurerait du vide.
	if host != null:
		var pages: Array[Control] = []
		for child in host.get_children():
			var page := child as Control
			if page != null:
				page.visible = true
				pages.append(page)
		await process_frame
		await process_frame

		for page in pages:
			_check(page.size.x > 0.0 and page.size.y > 0.0,
				"page %s dimensionnée (%.0f x %.0f)" % [page.name, page.size.x, page.size.y])
			if page.get_child_count() > 0:
				var content := page.get_child(0) as Control
				if content != null:
					_check(content.size.x > 0.0,
						"page %s : contenu dimensionné (%.0f de large)" % [page.name, content.size.x])
					_check(content.size.x <= page.size.x + 1.0,
						"page %s : le contenu ne déborde pas en largeur (%.0f pour %.0f)"
							% [page.name, content.size.x, page.size.x])

	scene.queue_free()
	await process_frame


## L'ecran de pub simulee doit contenir SON CONTENU, pas seulement son fond.
##
## Régression : `panel.add_child(bg)` alors que `bg` était déjà enfant de `root`.
## Godot refuse de réparenter — `Can't add child ... already has a parent` —
## et tout le VBoxContainer disparaît de l'arbre. Le fond seul restait : un écran
## noir, sans le moindre texte, en plein développement.
func _test_mock_ad_overlay() -> void:
	var ads: Node = root.get_node_or_null("Ads")
	if ads == null:
		_check(false, "autoload Ads présent")
		return

	var layer := CanvasLayer.new()
	root.add_child(layer)
	await process_frame

	var overlay: Control = ads.call("_build_mock_overlay")
	layer.add_child(overlay)
	await process_frame
	await process_frame

	_check(overlay != null and overlay.size.x > 0.0 and overlay.size.y > 0.0,
		"l'écran de pub simulée est dimensionné")
	var has_bg := false
	var has_panel := false
	if overlay != null:
		for child in overlay.get_children():
			if child is ColorRect:
				has_bg = true
			elif child is BoxContainer:
				has_panel = true
				_check((child as BoxContainer).get_child_count() >= 4,
					"le panneau de la pub simulée a son contenu (%d enfants)"
						% (child as BoxContainer).get_child_count())
	_check(has_bg, "l'écran de pub simulée a son fond")
	_check(has_panel, "l'écran de pub simulée a son panneau de contenu")

	# Le compte à rebours doit TOURNER. `Timer.start()` échoue silencieusement
	# hors arbre et le bouton de récompense resterait désactivé pour toujours :
	# le joueur bloque sur une pub simulée qu'il ne peut pas valider.
	var ticker: Timer = null
	if overlay != null:
		for node in _all_children(overlay):
			if node is Timer:
				ticker = node as Timer
				break
	_check(ticker != null, "la pub simulée a son compteur")
	if ticker != null:
		_check(not ticker.is_stopped(),
			"le compte à rebours tourne une fois l'écran dans l'arbre")

	overlay.queue_free()
	layer.queue_free()
	await process_frame


# ==================================================== compteur de combo flottant

## Le compteur de combo est le seul élément de l'écran qui flotte au-dessus du
## contenu, et il était le seul aussi à être HORS du `MarginContainer` de zone
## sûre : enfant direct de la racine, ancré au bas de la fenêtre entière, il
## tombait entièrement sous l'indicateur d'accueil. Mesuré avant correction,
## avec l'encoche du projet : le libellé allait de y = 816 à 842 alors que la zone
## non sûre commençait à 810. Le joueur ne voyait jamais son combo.
##
## Le test vérifie trois choses, dans cet ordre : que le libellé est dans la zone
## sûre, qu'il ne chevauche pas la barre basse, et qu'il SUIT l'encoche. La
## troisième est celle qui distingue un correctif d'un chanceux : un libellé
## simplement remonté à une position fixe passerait les deux premières.
func _test_combo_label_stays_usable() -> void:
	# Le toast quotidien de démarrage n'est pas le sujet de cette sonde. Le test
	# crée un toast explicite après la marge simulée pour vérifier son placement
	# avec le même `MainUI` et la même SafeArea.
	var preloaded_game: Variant = root.get_node_or_null("GameManager")
	if preloaded_game != null:
		var preloaded_stats: Dictionary = preloaded_game.get("stats")
		preloaded_stats["last_daily_claim"] = Time.get_unix_time_from_system()
	var ui: Control = await _open_main_ui()
	if ui == null:
		_check(false, "compteur de combo : MainUI a pu être instancié")
		return

	var combo: Label = ui.get("_combo_label") as Label
	var bar: Control = ui.get("_bottom_bar") as Control
	_check(combo != null, "compteur de combo : le libellé existe")
	_check(bar != null, "compteur de combo : la barre basse existe")
	if combo == null or bar == null:
		return
	var root_margin := ui.get_node("Root") as MarginContainer
	_check(root_margin.get_theme_constant("margin_top")
			>= int(10.0 + SafeArea.MIN_TOP + SafeArea.COMFORT_TOP),
		"MainUI applique ses marges SafeArea au conteneur racine, pas un offset fixe")

	# La barre basse doit avoir exactement les cinq enfants attendus. Un
	# `add_child` glissé dans la fonction de positionnement du libellé — ce qui
	# est arrivé pendant le développement — la doublait, et une barre de dix
	# boutons devenait plus large que l'écran (487 px pour 390). Ce contrôle
	# attrape la famille entière de régressions.
	_check(bar.get_child_count() == 5,
		"compteur de combo : la barre basse a 5 enfants et pas plus (%d)"
			% bar.get_child_count())

	# Le libellé est visible seulement avec un combo, donc on en fabrique un par
	# des récoltes réelles plutôt que de forcer `visible`.
	_check(not combo.visible, "compteur de combo : masqué tant qu'aucun combo")
	var game: Variant = root.get_node_or_null("GameManager")
	_check(game != null, "compteur de combo : autoload GameManager présent")
	if game == null:
		return
	for i in 4:
		game.call("harvest")
	await process_frame
	_check(combo.visible, "compteur de combo : visible après 4 récoltes")

	_assert_combo_usable(combo, bar, "sans encoche", 0.0)

	# Encoche par le chemin exact de la production, puis le label doit avoir
	# suivi la barre vers le haut.
	var before := combo.get_global_rect().position.y
	SafeArea.write(ui.get_node("Root") as MarginContainer, NOTCH)
	await process_frame
	await process_frame
	_assert_combo_usable(combo, bar, "sous encoche", float(NOTCH["bottom"]))
	_assert_top_bar_usable(ui, "sous encoche", float(NOTCH["top"]))
	await _test_toast_avoids_fixed_header(ui)
	_check(combo.get_global_rect().position.y < before,
		"compteur de combo : le libellé a suivi la barre vers le haut (%.0f -> %.0f)"
			% [before, combo.get_global_rect().position.y])

	# Rotation : la fenêtre change de forme et l'encoche simulée passe sur le
	# bord gauche, comme sur un téléphone avec l'écouteur en paysage.
	_host.size = Vector2(VIEWPORT_H, VIEWPORT_W)
	await process_frame
	await process_frame
	# `SafeArea.bind()` recalcule ses marges au redimensionnement; simuler
	# l'encoche après ce recalcul évite que son callback headless la remplace.
	var before_x := combo.get_global_rect().position.x
	SafeArea.write(ui.get_node("Root") as MarginContainer, LANDSCAPE_NOTCH)
	await process_frame
	await process_frame
	_assert_combo_usable(combo, bar, "en paysage", 0.0,
		float(LANDSCAPE_NOTCH["left"]))
	_assert_top_bar_usable(ui, "en paysage", 0.0,
		float(LANDSCAPE_NOTCH["left"]))
	_check(combo.get_global_rect().position.x > before_x,
		"compteur de combo : le libellé suit l'encoche en paysage (%.0f -> %.0f)"
			% [before_x, combo.get_global_rect().position.x])

	ui.queue_free()
	await process_frame


func _test_toast_avoids_fixed_header(ui: Control) -> void:
	var layer := ui.get_node_or_null("ToastLayer") as CanvasLayer
	var top := ui.get_node_or_null("Root/Layout/TopBar") as Control
	var resources := ui.get_node_or_null("Root/Layout/ResourcePanel") as Control
	_check(layer != null and top != null and resources != null,
		"toast : couche, barre haute et panneau de ressources présents")
	if layer == null or top == null or resources == null:
		return
	var toast := Toast.push(layer, "Notification de test", "info")
	await process_frame
	await process_frame
	# L'animation est rendue en quelques centaines de millisecondes, sans compter
	# les frames (qui tournent des milliers de fois plus vite en headless).
	await create_timer(0.3).timeout
	var rect := toast.get_global_rect()
	var panel_bottom := resources.global_position.y + resources.size.y
	_check(rect.position.y >= panel_bottom + 6.0,
		("toast : sous le panneau de ressources, pas sur le titre "
			+ "(toast y=%.0f, header bas=%.0f)") % [rect.position.y, panel_bottom])
	_check(not rect.intersects(top.get_global_rect())
			and not rect.intersects(resources.get_global_rect()),
		"toast : ne masque ni les boutons du haut ni le compteur de ressources")
	toast.call("_on_gone")
	await process_frame


## Les conditions qu'un libellé flottant doit respecter, quel que soit l'écran :
## dans la zone sûre, dans l'écran, et juste au-dessus de la barre basse.
##
## Les dimensions de référence sont LUES sur l'hôte, jamais reprises des
## constantes : après une rotation, la fenêtre fait 844 x 390 et non 390 x 844, et
## une vérification figée sur la constante passerait sur un écran de téléphone
## en portrait puis échouerait — ou l'inverse — à la première rotation.
##
## Le libellé est assemblé par concaténation AVANT l'opérateur `%`, et
## l'ensemble est mis entre parenthèses. `a + b % c` s'analyse comme
## `a + (b % c)` : le format ne s'applique qu'à la dernière chaîne. Trois
## vérifications affichaient donc littéralement « %s » et « %.0f » sans jamais
## échouer — des contrôles qui ne peuvent pas échouer, c'est-à-dire des
## contrôles inutiles.
func _assert_combo_usable(combo: Label, bar: Control, when: String,
		notch_bottom: float, notch_left: float = 0.0) -> void:
	var c := combo.get_global_rect()
	var b := bar.get_global_rect()
	var screen := _host.size
	var unsafe_top: float = screen.y - notch_bottom

	_check(c.position.y + c.size.y <= screen.y + EPS,
		("compteur de combo %s : le libellé tient dans la hauteur "
			+ "(bas %.0f <= %.0f)") % [when, c.position.y + c.size.y, screen.y])
	_check(c.position.y < unsafe_top,
		("compteur de combo %s : le libellé est au-dessus de la zone non sûre "
			+ "(%.0f < %.0f)") % [when, c.position.y, unsafe_top])
	_check(not c.intersects(b),
		"compteur de combo %s : le libellé ne chevauche pas la barre basse" % when)
	# ET il est juste au-dessus, pas flottant à l'autre bout de l'écran. Le
	# libellé est ancré par la CONSTANTE `BOTTOM_BAR_HEIGHT` : si la barre
	# changeait de hauteur sans que la constante suive, le libellé s'en
	# éloignerait — invisible à un simple test de non-chevauchement. L'écart
	# toléré ici est de 12 px, large assez pour absorber un arrondi de mise en
	# page, étroit assez pour voir une dérive.
	var gap := b.position.y - (c.position.y + c.size.y)
	_check(gap >= -EPS and gap <= 12.0,
		("compteur de combo %s : le libellé est juste au-dessus de la barre "
			+ "(écart %.0f px)") % [when, gap])
	_check(c.position.x >= -EPS and c.position.x + c.size.x <= screen.x + EPS,
		("compteur de combo %s : le libellé tient dans la largeur "
			+ "(%.0f..%.0f dans %.0f)")
		% [when, c.position.x, c.position.x + c.size.x, screen.x])
	_check(c.position.x >= notch_left - EPS,
		("compteur de combo %s : le libellé reste à droite de l'encoche "
			+ "(%.0f >= %.0f)") % [when, c.position.x, notch_left])


## Le rapport utilisateur porte surtout sur la barre haute : vérifier seulement
## la popup et le compteur bas ne suffisait pas. On contrôle le rectangle complet
## et chaque entrée de barre, en portrait sous l'encoche haute et en paysage avec
## l'encoche latérale.
func _assert_top_bar_usable(ui: Control, when: String, notch_top: float,
		notch_left: float = 0.0) -> void:
	var top := ui.get_node_or_null("Root/Layout/TopBar") as Control
	var root_margin := ui.get_node_or_null("Root") as MarginContainer
	_check(top != null and top.is_visible_in_tree() and top.size.y > 0.0,
		"barre haute %s : le conteneur est visible et dimensionné" % when)
	_check(root_margin != null and absf(root_margin.global_position.y) <= EPS,
		"barre haute %s : aucune marge de notch codée en offset fixe" % when)
	if top == null or root_margin == null:
		return
	var rect := top.get_global_rect()
	_check(rect.position.y >= notch_top - EPS,
		("barre haute %s : au-dessous de la zone haute non sûre "
			+ "(y %.0f >= %.0f)") % [when, rect.position.y, notch_top])
	var screen := _host.size
	var all_children_fit := true
	for child in top.get_children():
		if not child is Control:
			continue
		var child_rect := (child as Control).get_global_rect()
		if not (child as Control).is_visible_in_tree() \
				or child_rect.position.y < notch_top - EPS \
				or child_rect.position.x < notch_left - EPS \
				or child_rect.position.x + child_rect.size.x > screen.x + EPS \
				or child_rect.position.y + child_rect.size.y > screen.y + EPS:
			all_children_fit = false
	_check(all_children_fit,
		"barre haute %s : tous ses contrôles restent dans l'écran et hors de l'encoche"
			% when)


## Instancie `Main.tscn` dans un conteneur de la taille d'un téléphone, avec un
## combo actif. Renvoie `null` si la scène ne peut pas être chargée, pour que
## l'échec soit visible plutôt que silencieux.
func _open_main_ui() -> Control:
	if _host != null and is_instance_valid(_host):
		_host.queue_free()
		await process_frame
	_host = Control.new()
	root.add_child(_host)
	_host.position = Vector2.ZERO
	_host.size = Vector2(VIEWPORT_W, VIEWPORT_H)
	await process_frame

	var packed: PackedScene = load("res://scenes/Main.tscn")
	if packed == null:
		_check(false, "compteur de combo : Main.tscn est chargeable")
		return null
	var ui := packed.instantiate() as Control
	_host.add_child(ui)
	await process_frame
	await process_frame
	return ui


# ==================================================================== outils
func _all_children(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	for child in node.get_children():
		out.append(child)
		out.append_array(_all_children(child))
	return out


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok    ", label)
	else:
		_failures += 1
		print("  ECHEC ", label)
