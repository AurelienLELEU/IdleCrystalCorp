extends Node

## Autoload : Store
##
## Achats intégrés. Même abstraction que les pubs : un jeu fonctionne entièrement
## sans le moindre paiement, les achats sont des raccourcis.
##
## Ligne rouge assumée : aucune fenêtre de confirmation trompeuse. Pas de bouton
## « X » qui achète, pas de « continuez » qui surplombe un « non ». L'écran de
## confirmation est explicite, affiche le vrai nom et le vrai prix, et « Annuler »
## est aussi visible que « Acheter ». C'est ce qui fait la différence entre un
## jeu qui fait de l'argent et un jeu qui se fait détester.
##
## Plugin attendu (classe "IdleStore") :
##   load_products() -> void                              # remplit _products
##   purchase(product_id: String) -> void
##   restore() -> void
##   is_purchased(product_id: String) -> bool

signal products_loaded()
signal purchase_requested(product_id: String)
signal purchase_completed(product_id: String)
signal purchase_failed(product_id: String, reason: String)

const PLUGIN_CLASS := "IdleStore"

var mock: bool = true
var _plugin: Object = null
var _owned: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not ClassDB.class_exists(PLUGIN_CLASS):
		_plugin = null
		return
	var instance: Variant = ClassDB.instantiate(PLUGIN_CLASS)
	if instance != null:
		_plugin = instance
		if _plugin is Node:
			add_child(_plugin as Node)


func configure(settings: Dictionary) -> void:
	mock = bool(settings.get("mock", true))


func get_products() -> Array[Dictionary]:
	var game: Variant = _game()
	if game == null:
		return []
	var cfg: GameConfig = game.get("config") as GameConfig
	if cfg == null:
		return []
	# Type GameConfig explicite : avec un Variant, `cfg.get("x", defaut)` se
	# résout vers Object.get( propriete) qui n'accepte qu'un argument.
	var products: Array[Dictionary] = cfg.store_products
	var copy: Array[Dictionary] = []
	for item in products:
		copy.append(item)
	return copy


func get_product(product_id: String) -> Dictionary:
	for p in get_products():
		if str(p.get("id", "")) == product_id:
			return p
	return {}


func is_consumable(product_id: String) -> bool:
	return str(get_product(product_id).get("type", "consumable")) == "consumable"


## Un droit (type "entitlement") ne s'achète qu'une fois.
func is_purchased(product_id: String) -> bool:
	if is_consumable(product_id):
		return false
	return bool(_owned.get(product_id, false))


func can_purchase(product_id: String) -> bool:
	var p := get_product(product_id)
	if p.is_empty():
		return false
	if not is_consumable(product_id) and is_purchased(product_id):
		return false
	if product_id == "boost_production" and _active_boost_count() >= 3:
		return false
	return true


## Déclenche l'achat. En mode mock, émet purchase_requested : c'est l'UI qui
## affiche la confirmation, puis appelle complete_mock_purchase().
func purchase(product_id: String) -> void:
	if not can_purchase(product_id):
		purchase_failed.emit(product_id, "déjà possédé ou indisponible")
		return
	if mock or _plugin == null:
		purchase_requested.emit(product_id)
		return
	if _plugin.has_method("purchase"):
		_plugin.call("purchase", str(get_product(product_id).get("product_id", product_id)))
	else:
		purchase_failed.emit(product_id, "plugin sans purchase()")


func complete_mock_purchase(product_id: String) -> void:
	if not can_purchase(product_id):
		purchase_failed.emit(product_id, "déjà possédé ou indisponible")
		return
	_grant(product_id)
	purchase_completed.emit(product_id)


func restore_purchases() -> void:
	if _plugin != null and _plugin.has_method("restore"):
		_plugin.call("restore")
		return
	var restored: Array[String] = []
	for p in get_products():
		var id := str(p.get("id", ""))
		if is_consumable(id):
			continue
		if bool(_owned.get(id, false)):
			_grant(id)
			restored.append(id)
	for id in restored:
		purchase_completed.emit(id)
	if restored.is_empty():
		purchase_failed.emit("", "rien à restaurer")


func _grant(product_id: String) -> void:
	if not is_consumable(product_id):
		_owned[product_id] = true
	var game: Variant = _game()
	if game != null:
		game.call("grant_store_product", product_id)


func _active_boost_count() -> int:
	var game: Variant = _game()
	if game == null:
		return 0
	# On approxime par le temps de surcharge restant : chaque achat ajoute
	# boost_hours, on considère qu'au-delà de ~5 h restantes le joueur en a 3.
	var ends: float = float(game.get("boost_ends_at"))
	var now := Time.get_unix_time_from_system()
	if ends <= now:
		return 0
	return 3 if ends - now > 5.0 * 3600.0 else 2


func _game() -> Variant:
	return get_node_or_null("/root/GameManager")
