extends SceneTree

## Vérifie que la scène principale s'instancie réellement, autoloads compris.
##
## Un simple `--import` ne parse pas chaque script : un fichier non référencé par
## une scène peut rester cassé sans qu'on le voie. Ce test charge donc Main.tscn
## pour de vrai, ce qui force l'analyse de MainUI.gd, de Modal.gd, de Toast.gd et
## de toute la chaîne d'autoloads (Ads, Store, Notifications, Audio, GameManager).
##
##   ./tests/run.sh res://tests/test_ui_compile.gd

const MAIN_SCENE := "res://scenes/Main.tscn"
const REQUIRED_AUTOLOADS := ["Ads", "Store", "Notifications", "Audio", "GameManager"]

var _failures: int = 0


func _initialize() -> void:
	print("=== test_ui_compile ===")
	_run()


func _run() -> void:
	# En mode --script, les autoloads sont ajoutés à la racine mais leur _ready()
	# n'est exécuté qu'au premier frame : sans cette attente, on lirait un
	# GameManager dont la configuration n'est pas encore chargée.
	await process_frame
	await process_frame

	var viewport_width := int(ProjectSettings.get_setting("display/window/size/viewport_width", 0))
	var viewport_height := int(ProjectSettings.get_setting("display/window/size/viewport_height", 0))
	_check(viewport_width == 1080 and viewport_height == 1920,
		"viewport de conception mobile Full HD portrait (%d×%d)" % [viewport_width, viewport_height])
	var stretch_scale := float(ProjectSettings.get_setting("display/window/stretch/scale", 1.0))
	_check(is_equal_approx(stretch_scale, 1.5),
		"le facteur de stretch compense la base Full HD (%.2f)" % stretch_scale)

	# --- autoloads présents dans l'ordre prévu -----------------------------
	for autoload_name in REQUIRED_AUTOLOADS:
		var node: Node = root.get_node_or_null(autoload_name)
		_check(node != null, "autoload « %s » instancié" % autoload_name)

	var game: Variant = root.get_node_or_null("GameManager")
	if game != null:
		var config: GameConfig = game.get("config")
		_check(config != null, "GameManager.config non nul")
		if config != null:
			_check(config.load_error.is_empty(), "configuration sans erreur (%s)" % config.load_error)
			_check(config.buildings.size() == 20, "20 bâtiments chargés")
			_check(config.achievements.size() == 31, "31 succès chargés")
			_check(config.store_products.size() == 7, "7 produits boutique chargés")
		_check(int(game.get("prestige_count")) == 0, "partie neuve (ascension 0)")

	# --- la scène principale s'instancie -----------------------------------
	if not ResourceLoader.exists(MAIN_SCENE):
		_failures += 1
		print("ECHEC  ", MAIN_SCENE, " introuvable")
	else:
		var packed: PackedScene = load(MAIN_SCENE)
		_check(packed != null, "Main.tscn se charge")
		if packed != null:
			var scene: Node = packed.instantiate()
			_check(scene != null, "Main.tscn s'instancie")
			if scene != null:
				root.add_child(scene)
				await process_frame
				_check_ui_built(scene)
				scene.queue_free()
				await process_frame

	quit(1 if _failures > 0 else 0)


## Prouve que MainUI._ready() a tourné jusqu'au bout : la scène .tscn ne contient
## que des conteneurs vides, tout le contenu est fabriqué par le script. Sans
## cette vérification, une exception au milieu de _ready() passerait inaperçue
## car les nœuds resteraient simplement vides.
func _check_ui_built(scene: Node) -> void:
	var top_bar: Node = _find(scene, "TopBar")
	var bottom_bar: Node = _find(scene, "BottomBar")
	var page_host: Node = _find(scene, "PageHost")
	var overlay_layer: Node = _find(scene, "OverlayLayer")

	_check(top_bar != null and top_bar.get_child_count() >= 4,
		"barre haute remplie (%d entrées)" % (0 if top_bar == null else top_bar.get_child_count()))
	_check(top_bar != null and top_bar.get_combined_minimum_size().y >= 80.0,
		"barre haute agrandie : cibles tactiles d'au moins 80 unités")
	_check(bottom_bar != null and bottom_bar.get_child_count() == 5,
		"barre basse remplie (%d entrées : 2 onglets + récolte + 2 onglets)"
			% (0 if bottom_bar == null else bottom_bar.get_child_count()))
	_check(page_host != null and page_host.get_child_count() == 7,
		"7 pages construites (%d)" % (0 if page_host == null else page_host.get_child_count()))
	_check(overlay_layer != null, "couche de modales présente")

	# Une page contient des lignes de bâtiments : c'est la preuve que les
	# dictionnaires de GameConfig ont été parcourus et indexés correctement.
	var buildings_page: Node = _find(page_host, "Page_buildings")
	_check(buildings_page != null, "page « Bâtiments » instanciée")
	if buildings_page != null and buildings_page.get_child_count() > 0:
		var box: Node = buildings_page.get_child(0)
		# 20 cartes + un en-tête de section = 21 enfants.
		_check(box.get_child_count() == 21,
			"20 lignes de bâtiments + en-tête (%d enfants)" % box.get_child_count())


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok    ", label)
	else:
		_failures += 1
		print("  ECHEC ", label)


## Recherche descendante par nom, en tolérant un argument nul.
func _find(node: Node, target: String) -> Node:
	if node == null:
		return null
	if str(node.name) == target:
		return node
	for child in node.get_children():
		var found: Node = _find(child, target)
		if found != null:
			return found
	return null
