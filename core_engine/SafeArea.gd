class_name SafeArea
extends RefCounted

## Marges à respecter pour ne rien placer sous l'encoche, la barre d'état ou
## l'indicateur d'accueil.
##
## Sur un iPhone, l'écran ne fait pas toute la surface utile : l'encoche mange
## le haut et la barre d'accueil mange le bas. Un `CenterContainer` qui centre
## la carte sur la hauteur *complète* place donc le haut du texte sous l'encoche
## et le bas sous l'indicateur — et les deux bouts disparaissent en même temps,
## ce qui donne l'impression que le texte est tronqué au hasard.
##
## Ce qui complique le calcul : le projet est en `canvas_items` / `expand`, donc
## une marge exprimée en pixels d'écran n'est pas un nombre d'unités de mise en
## page. La conversion passe par l'échelle du viewport.
##
## Aucun état, uniquement des statiques : c'est une règle d'affichage, pas un
## objet qui vit dans la scène.

## Marge de sécurité minimale, même quand la plateforme ne rien signale.
## Sur un ordinateur de bureau il n'y a pas d'encoche : ces valeurs évitent
## simplement que le texte colle au bord de la fenêtre.
const MIN_TOP := 14.0
const MIN_BOTTOM := 14.0

## Confort ajouté PAR-DESSUS l'encoche réelle. Deux raisons : la barre d'état
## peut disparaître en plein écran alors que l'encoche, elle, reste ; et un
## texte collé au bord de l'écran se lit comme du texte tronqué même quand il ne
## l'est pas. Ces deux marges se règlent ici, une fois pour toute l'application.
const COMFORT_TOP := 18.0
const COMFORT_BOTTOM := 18.0

## Marge latérale minimale : les bords d'écran sont la zone la plus difficile à
## atteindre d'une seule main, et une cible tactile collée au bord est
## inatteignable en pratique.
const MIN_SIDE := 10.0

## Clé de métadonnée servant à mémoriser les marges d'origine d'un
## `MarginContainer`. Un nom lisible, parce que la valeur est lisible en
## débogage et que « métadonnée 8743 » ne l'est pas.
const META_BASE := "_safe_area_base_margins"


## Marges de mise en page à réserver, en unités du viewport de `vp`.
##
## Renvoie `{left, top, right, bottom}`. Sur une plateforme sans zone sûre
## (ordinateur, éditeur, headless), seuls `MIN_*` et `COMFORT_*` s'appliquent :
## le résultat est alors déterministe, ce qui permet de tester la mise en page
## sans appareil.
static func insets_for(vp: Viewport) -> Dictionary:
	var out := {
		"left": MIN_SIDE,
		"top": MIN_TOP + COMFORT_TOP,
		"right": MIN_SIDE,
		"bottom": MIN_BOTTOM + COMFORT_BOTTOM,
	}
	var raw := _platform_insets(vp)
	out["left"] = maxf(float(out["left"]), float(raw["left"]))
	out["top"] = maxf(float(out["top"]), float(raw["top"]) + COMFORT_TOP)
	out["right"] = maxf(float(out["right"]), float(raw["right"]))
	out["bottom"] = maxf(float(out["bottom"]), float(raw["bottom"]) + COMFORT_BOTTOM)
	return out


## Applique `insets_for` aux quatre marges d'un `MarginContainer`.
static func apply(margin: MarginContainer, vp: Viewport) -> Dictionary:
	var i := insets_for(vp)
	write(margin, i)
	return i


## Écrit des marges données sur un `MarginContainer`.
##
## Les marges de la scène sont un plancher de mise en page (12 px sur les côtés
## dans `Main.tscn`) : elles s'AJOUTENT aux marges de zone sûre, elles ne la
## remplacent pas. Problème : `add_theme_constant_override` remplace la valeur
## au lieu de l'incrémenter, donc un second appel écracerait la marge de la
## scène. La valeur de départ est mémorisée au premier appel et réutilisée
## ensuite, ce qui rend l'opération idempotente.
##
## C'est le seul endroit du dépôt qui écrit des marges issues d'insets. Les
## tests s'en servent pour appliquer une encoche SIMULÉE et vérifier le
## centrage sans avoir l'appareil sous la main.
static func write(margin: MarginContainer, insets: Dictionary) -> void:
	if margin == null:
		return
	var base := _base_margins(margin)
	margin.add_theme_constant_override("margin_left",
		int(round(base["left"] + float(insets.get("left", 0.0)))))
	margin.add_theme_constant_override("margin_top",
		int(round(base["top"] + float(insets.get("top", 0.0)))))
	margin.add_theme_constant_override("margin_right",
		int(round(base["right"] + float(insets.get("right", 0.0)))))
	margin.add_theme_constant_override("margin_bottom",
		int(round(base["bottom"] + float(insets.get("bottom", 0.0)))))


## Marges de mise en page d'origine, mémorisées au premier appel.
static func _base_margins(margin: MarginContainer) -> Dictionary:
	if margin.has_meta(META_BASE):
		return margin.get_meta(META_BASE)
	var base := {
		"left": float(margin.get_theme_constant("margin_left")),
		"top": float(margin.get_theme_constant("margin_top")),
		"right": float(margin.get_theme_constant("margin_right")),
		"bottom": float(margin.get_theme_constant("margin_bottom")),
	}
	margin.set_meta(META_BASE, base)
	return base


## Maintient les marges d'un `MarginContainer` synchronisées avec la zone sûre.
##
## À appeler UNE fois, sur un `MarginContainer` déjà dans l'arbre. Le rappel est
## refait à chaque redimensionnement — donc aussi à la rotation, où l'encoche
## change de bord. Une connexion `ONE_SHOT` conviendrait à une icône de fenêtre,
## pas à une marge d'encoche : au premier pliage du clavier ou passage en
## multitâche, la mise en page resterait décalée pour le reste de la session.
static func bind(margin: MarginContainer) -> void:
	if margin == null or not margin.is_inside_tree():
		return
	apply(margin, margin.get_viewport())
	margin.resized.connect(
		func() -> void: apply(margin, margin.get_viewport()),
		CONNECT_DEFERRED,
	)


## Insets bruts rapportés par la plateforme, convertis en unités de mise en page.
static func _platform_insets(vp: Viewport) -> Dictionary:
	var none := {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	if vp == null or DisplayServer.get_name() == "headless":
		return none

	var safe: Rect2i = DisplayServer.get_display_safe_area()
	if safe.size.x <= 0 or safe.size.y <= 0:
		# Pas de zone sûre sur cette plateforme (ordinateur de bureau, ou
		# fenêtre pas encore créée). Rien à convertir : les MIN_* prennent le
		# relais, et l'interface reste utilisable.
		return none

	# L'application occupe tout l'écran, donc le coin haut-gauche de l'écran
	# physique est aussi celui de la fenêtre : les marges de la zone sûre sont
	# directement les deux premières coordonnées du rectangle.
	var screen := DisplayServer.screen_get_size()
	if screen.x <= 0 or screen.y <= 0:
		return none

	# L'échelle du viewport convertit les pixels d'écran en unités de mise en
	# page. On ne prend que la *magnitude* : la transformation complète change
	# de sens selon la version de Godot et selon le mode d'étirement, alors que
	# son échelle, non.
	var t := vp.get_final_transform()
	var sx := absf(t.x.x)
	var sy := absf(t.y.y)
	if sx < 0.001 or sy < 0.001:
		# Viewport pas encore dimensionné : diviser donnerait un nombre
		# arbitraire, purement et simplement. Mieux vaut aucune marge que
		# plusieurs milliers de pixels de vide.
		return none

	return {
		"left": float(safe.position.x) / sx,
		"top": float(safe.position.y) / sy,
		"right": float(screen.x - safe.position.x - safe.size.x) / sx,
		"bottom": float(screen.y - safe.position.y - safe.size.y) / sy,
	}
