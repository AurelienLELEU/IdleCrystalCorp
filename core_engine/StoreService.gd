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
		_connect_plugin()
		_start_plugin()


## Branche les signaux de StoreKit 2 sur nos propres états.
##
## Le plug-in émet des signaux et ne rappelle pas l'autoload : un appel natif
## vers un autoload depuis une tâche Swift arrive parfois après la destruction
## du nœud, et plante sans laisser de trace. Un signal reçu par un objet
## invalide est, lui, au minimum ignorable.
func _connect_plugin() -> void:
	if _plugin == null or not is_instance_valid(_plugin):
		return
	if _plugin.has_signal("products_loaded"):
		_plugin.connect("products_loaded", _on_products_loaded)
	if _plugin.has_signal("purchase_completed"):
		_plugin.connect("purchase_completed", _on_plugin_purchased)
	if _plugin.has_signal("purchase_failed"):
		_plugin.connect("purchase_failed", _on_plugin_failed)
	if _plugin.has_signal("purchase_restored"):
		_plugin.connect("purchase_restored", _on_plugin_restored)


## Demande au SDK de charger le catalogue. Les identifiants viennent de la
## configuration, dans l'ordre : c'est le seul endroit où ils sont écrits, donc
## le seul endroit à modifier pour ajouter un produit.
func _start_plugin() -> void:
	if _plugin == null or not _plugin.has_method("start"):
		return
	var ids: PackedStringArray = PackedStringArray()
	for item in get_products():
		ids.append(str(item.get("product_id", item.get("id", ""))))
	_plugin.call("start", ",".join(ids))


func _on_products_loaded(_count: int) -> void:
	# Le catalogue est prêt : c'est le bon moment de demander les droits déjà
	# possédés, StoreKit ne renseignant is_purchased qu'à partir de maintenant.
	refresh_entitlements()
	products_loaded.emit()


func _on_plugin_purchased(native_product_id: String) -> void:
	# StoreKit parle en identifiants App Store Connect, la config en identifiants
	# internes (« supprimer_pubs »). Le pont est la recherche inverse.
	var product_id := _internal_id_for(native_product_id)
	_grant(product_id)
	purchase_completed.emit(product_id)


func _on_plugin_failed(native_product_id: String, reason: String) -> void:
	purchase_failed.emit(_internal_id_for(native_product_id), reason)


func _on_plugin_restored(count: int) -> void:
	# count < 0 signale une erreur réseau, pas un catalogue vide.
	if count < 0:
		GameManager.notify("Restauration impossible. Vérifiez votre connexion.", "warn")
		return
	refresh_entitlements()
	if count == 0:
		GameManager.notify("Aucun achat à restaurer.", "info")
	else:
		GameManager.notify("%d achat(s) restauré(s)." % count, "success")


func _internal_id_for(native_product_id: String) -> String:
	for item in get_products():
		if str(item.get("product_id", "")) == native_product_id:
			return str(item.get("id", native_product_id))
	return native_product_id


## Demande au SDK les achats déjà possédés. Appelé au démarrage : un joueur
## qui réinstalle l'application doit retrouver ses droits sans racheter.
func refresh_entitlements() -> void:
	if _plugin == null or not _plugin.has_method("is_purchased"):
		return
	for item in get_products():
		if str(item.get("type", "consumable")) == "entitlement":
			var native_id := str(item.get("product_id", ""))
			if _plugin.call("is_purchased", native_id):
				_grant(str(item.get("id", "")))


## Prix affiché, au format de la devise locale. C'est le SDK qui parle : le
## prix du JSON n'est qu'un repli pour la boutique simulée, et afficher le prix
## du JSON en production est un motif de refus de la revue.
func get_display_price(product_id: String) -> String:
	var item := get_product(product_id)
	var fallback := str(item.get("price", ""))
	if _plugin != null and _plugin.has_method("get_price"):
		var price := str(_plugin.call("get_price", str(item.get("product_id", product_id))))
		if not price.is_empty():
			return price
	return fallback


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
##
## Le SDK est consulté en second, et c'est volontaire : si le joueur a remis
## la partie à zéro mais que son achat est bien dans l'App Store, le droit doit
## revenir. Faire confiance au seul état local reviendrait à lui facturer deux
## fois le même achat.
func is_purchased(product_id: String) -> bool:
	if is_consumable(product_id):
		return false
	if bool(_owned.get(product_id, false)):
		return true
	if _plugin != null and _plugin.has_method("is_purchased"):
		var native_id := str(get_product(product_id).get("product_id", product_id))
		if _plugin.call("is_purchased", native_id):
			_owned[product_id] = true
			return true
	return false


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
