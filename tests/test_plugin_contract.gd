extends SceneTree

## Vérifie le CONTRAT entre le jeu et les extensions natives `IdleAds` et
## `IdleStore`, en injectant un faux plug-in.
##
##   godot --headless --path . --script res://tests/test_plugin_contract.gd
##
## Ce test ne remplace pas un test sur appareil : il vérifie que, le jour où
## vous remplacerez le simulateur par Google AdMob et StoreKit 2, la branche
## « plug-in » du code est celle que vous croyez. C'est le seul moyen de
## détecter une dérive de contrat sans avoir un iPhone sous la main.
##
## Le faux plug-in reproduit exactement l'interface documentée dans
## native/ads/src/idle_ads.h et native/store/src/idle_store.h : mêmes noms de
## méthodes, mêmes signatures, mêmes signaux.

var _failed := 0
var _passed := 0
var _ads: Node = null
var _store: Node = null
var _ads_backup: Object = null
var _store_backup: Object = null


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  ok    %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s %s" % [label, detail])


func _initialize() -> void:
	print("== Contrat des extensions natives ==")
	# Un script étendant SceneTree ne voit pas les identifiants d'autoload
	# comme globals : on passe par le noeud, comme dans les autres suites.
	_ads = root.get_node_or_null("Ads")
	_store = root.get_node_or_null("Store")
	_check("autoload Ads présent", _ads != null)
	_check("autoload Store présent", _store != null)
	if _ads == null or _store == null:
		quit(1)
		return

	_ads_backup = _ads.get("_plugin")
	_store_backup = _store.get("_plugin")

	_run()


## Remet les services dans l'état d'une partie neuve, comme après un
## redémarrage de l'application.
func _restore_nominal_state() -> void:
	var game: Variant = root.get_node_or_null("GameManager")
	var cfg: GameConfig = game.get("config") as GameConfig
	cfg.ads["enabled"] = true
	_ads.call("configure", cfg.ads)
	_store.set("mock", true)
	_ads.set("mock", true)
	_ads.set("_busy", false)
	_ads.set("_daily_counts", {})
	_store.set("_owned", {})
	game.call("_apply_fresh_state")
	game.set("pending_offline", {})


func _run() -> void:
	# Deux frames : les autoloads doivent avoir terminé leur _ready(), sans quoi
	# AdService n'a pas encore branché ses propres signaux.
	await process_frame
	await process_frame

	# L'état à plat est posé ICI, pas dans _initialize() : à ce moment
	# GameManager n'a pas terminé son _ready() et sa configuration est encore
	# vide. Chaque test repart d'une partie neuve — les suites précédentes
	# modifient cet état global, et en dépendre rendrait le résultat fonction
	# de l'ordre d'exécution des suites, le pire genre de test.
	_restore_nominal_state()

	_test_ads_delegates_to_plugin()
	_test_ads_completion_is_the_only_reward()
	_test_ads_failure_credits_nothing()
	_test_ads_daily_cap_survives_plugin()
	_test_ads_never_runs_while_no_ads_purchased()
	_test_store_delegates_to_plugin()
	_test_store_maps_native_ids_back()
	_test_store_entitlement_survives_hard_reset()
	_test_store_prices_come_from_the_sdk()
	_test_missing_plugin_methods_are_reported()

	_ads.set("_plugin", _ads_backup)
	_store.set("_plugin", _store_backup)
	print("== Contrat des extensions : %d vérifications, %d échecs ==" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


## Un faux plug-in qui implements TOUT le contrat déclaré dans idle_ads.h.
class FakeAds:
	extends RefCounted

	signal rewarded_completed(reward_id: String)
	signal rewarded_failed(reward_id: String, reason: String)

	var configured_with: Array = []
	var show_calls: Array = []

	func is_configured() -> bool:
		return true

	func configure(app_id: String, rewarded_unit_id: String, debug: bool) -> void:
		configured_with = [app_id, rewarded_unit_id, debug]

	func show_rewarded(reward_id: String) -> void:
		show_calls.append(reward_id)


# =========================================================== IdleAds

func _test_ads_delegates_to_plugin() -> void:
	var plugin := FakeAds.new()
	_ads.set("_plugin", plugin)
	_ads.set("_busy", false)
	_ads.set("mock", false)
	_ads.call("_connect_plugin")

	_ads.show_rewarded("offline_double")
	_check("IdleAds.show_rewarded délègue au plug-in", plugin.show_calls == ["offline_double"],
		"-> %s" % [plugin.show_calls])
	_check("IdleAds marque la pub en cours", _ads.is_busy())

	# Le mode test Google doit pouvoir être activé depuis la configuration.
	var ok: bool = _ads.configure_plugin("ca-app-pub-x~y", "ca-app-pub-x/1", true)
	_check("IdleAds.configure est transmis", ok and plugin.configured_with.size() == 3,
		"-> %s" % [plugin.configured_with])
	_check("IdleAds reçoit le mode test", plugin.configured_with[2] == true)

	_ads.set("_busy", false)
	_ads.set("mock", true)
	_ads.set("_plugin", _ads_backup)


## Le seul moment où le joueur a droit à sa récompense : la fin de la vidéo.
## C'est le point le plus important de tout le branchement, d'où un test dédié.
func _test_ads_completion_is_the_only_reward() -> void:
	var plugin := FakeAds.new()
	_ads.set("_plugin", plugin)
	_ads.set("mock", false)
	_ads.set("_busy", false)
	_ads.call("_connect_plugin")

	var events: Array = []
	_ads.ad_completed.connect(func(reward_id: String) -> void: events.append(["ok", reward_id]))
	_ads.ad_failed.connect(func(reward_id: String, reason: String) -> void:
		events.append(["ko", reward_id, reason]))

	_ads.show_rewarded("production_boost")
	_check("aucun signal pendant la pub", events.is_empty(),
		"-> %s" % [events])

	plugin.rewarded_completed.emit("production_boost")
	_check("la fin de vidéo émet ad_completed", events == [["ok", "production_boost"]],
		"-> %s" % [events])
	_check("la pub n'est plus en cours", not _ads.is_busy())

	# Un second rappel ne doit pas compter deux fois : c'est le défaut classique
	# quand un delegate AdMob déclenche à la fois dismissal et reward.
	plugin.rewarded_completed.emit("production_boost")
	_check("un rappel supplémentaire ne recompte rien", events.size() == 1,
		"-> %s" % [events])

	_ads.set("mock", true)
	_ads.set("_busy", false)
	_ads.set("_plugin", _ads_backup)


func _test_ads_failure_credits_nothing() -> void:
	var plugin := FakeAds.new()
	_ads.set("_plugin", plugin)
	_ads.set("mock", false)
	_ads.set("_busy", false)
	_ads.call("_connect_plugin")

	var failures: Array = []
	_ads.ad_failed.connect(func(reward_id: String, reason: String) -> void:
		failures.append([reward_id, reason]))

	_ads.show_rewarded("free_crystals")
	plugin.rewarded_failed.emit("free_crystals", "réseau indisponible")
	_check("un échec émet ad_failed", failures.size() == 1, "-> %s" % [failures])
	_check("l'échec porte sa raison", failures[0][1] == "réseau indisponible")
	_check("l'échec libère la pub", not _ads.is_busy())

	_ads.set("mock", true)
	_ads.set("_plugin", _ads_backup)


## Le plafond quotidien doit continuer à compter en mode plug-in : c'est lui
## qui empêche de regarder mille pubs pour farmer — et Google sanctionne cela.
func _test_ads_daily_cap_survives_plugin() -> void:
	var plugin := FakeAds.new()
	_ads.set("_plugin", plugin)
	_ads.set("mock", false)
	_ads.set("_busy", false)
	_ads.set("_daily_counts", {})
	_ads.call("_connect_plugin")

	var cap: int = _ads.daily_cap("production_boost")
	var granted := 0
	for i in cap + 2:
		if _ads.is_available("production_boost"):
			_ads.show_rewarded("production_boost")
			plugin.rewarded_completed.emit("production_boost")
			granted += 1
	_check("le plafond quotidien tient en mode plug-in", granted == cap,
		"-> %d accordés pour un plafond de %d" % [granted, cap])
	_check("au-delà du plafond, la pub est refusée", not _ads.is_available("production_boost"))

	_ads.set("mock", true)
	_ads.set("_plugin", _ads_backup)


## Acheter « Supprimer les pubs » doit rendre toute pub inaccessible, plug-in
## compris. Un garde-fou que le plug-in pourrait contourner serait inutile.
func _test_ads_never_runs_while_no_ads_purchased() -> void:
	var plugin := FakeAds.new()
	_ads.set("_plugin", plugin)
	_ads.set("mock", false)
	_ads.set("_busy", false)
	_ads.set("_daily_counts", {})

	var game: Variant = root.get_node_or_null("GameManager")
	var flags: Dictionary = game.get("flags")
	var before: Dictionary = flags.duplicate()
	flags["no_ads"] = true

	_check("plus aucune pub disponible", not _ads.is_available("production_boost"))
	_check("le double hors-ligne est indisponible aussi", not _ads.is_available("offline_double"))
	_ads.show_rewarded("production_boost")
	_check("le plug-in n'est jamais appelé", plugin.show_calls.is_empty(),
		"-> %s" % [plugin.show_calls])

	game.set("flags", before)
	_ads.set("mock", true)
	_ads.set("_plugin", _ads_backup)


# ========================================================== IdleStore

class FakeStore:
	extends RefCounted

	signal products_loaded(count: int)
	signal purchase_completed(product_id: String)
	signal purchase_failed(product_id: String, reason: String)
	signal purchase_restored(count: int)

	var start_csv: String = ""
	var purchase_calls: Array = []
	var restore_calls := 0
	var owned: Dictionary = {}
	var prices: Dictionary = {}

	func is_configured() -> bool:
		return true

	func start(product_ids_csv: String) -> void:
		start_csv = product_ids_csv
		products_loaded.emit(prices.size())

	func purchase(product_id: String) -> void:
		purchase_calls.append(product_id)

	func restore() -> void:
		restore_calls += 1

	func is_purchased(product_id: String) -> bool:
		return bool(owned.get(product_id, false))

	func get_price(product_id: String) -> String:
		return str(prices.get(product_id, ""))


func _test_store_delegates_to_plugin() -> void:
	var plugin := FakeStore.new()
	_store.set("_plugin", plugin)
	_store.set("mock", false)

	_store.call("_start_plugin")
	_check("le catalogue est demandé au plug-in", plugin.start_csv.contains("com.aurelien.idlegame.noads"),
		"-> %s" % [plugin.start_csv])
	_check("les 7 identifiants sont transmis", plugin.start_csv.split(",").size() == 7,
		"-> %s" % [plugin.start_csv])

	# Le premier achat passe par le plug-in avec l'identifiant App Store, pas
	# l'identifiant interne : c'est le seul que StoreKit comprenne.
	var requested: Array = []
	_store.purchase_requested.connect(func(id: String) -> void: requested.append(id))
	_store.purchase("supprimer_pubs")
	_check("l'achat va au plug-in", plugin.purchase_calls == ["com.aurelien.idlegame.noads"],
		"-> %s" % [plugin.purchase_calls])
	_check("le mode plug-in n'émet pas purchase_requested", requested.is_empty(),
		"-> %s" % [requested])

	_store.restore_purchases()
	_check("la restauration est déléguée", plugin.restore_calls == 1)

	_store.set("mock", true)
	_store.set("_plugin", _store_backup)


## StoreKit parle en identifiants App Store Connect, le jeu en identifiants
## internes. Sans cette traduction, un achat réussi ne crédite rien.
func _test_store_maps_native_ids_back() -> void:
	var plugin := FakeStore.new()
	_store.set("_plugin", plugin)
	_store.set("mock", false)
	_store.call("_connect_plugin")

	var completed: Array = []
	_store.purchase_completed.connect(func(id: String) -> void: completed.append(id))
	_store.purchase("supprimer_pubs")
	plugin.purchase_completed.emit("com.aurelien.idlegame.noads")

	_check("l'identifiant natif est retraduit", completed == ["supprimer_pubs"],
		"-> %s" % [completed])
	_check("le droit est accordé", _store.is_purchased("supprimer_pubs"))

	var failed: Array = []
	_store.purchase_failed.connect(func(id: String, reason: String) -> void:
		failed.append([id, reason]))
	plugin.purchase_failed.emit("com.aurelien.idlegame.pack.t1", "achat annulé")
	_check("un échec est retraduit et propagé", failed == [["pack_cristaux_1", "achat annulé"]],
		"-> %s" % [failed])

	_store.set("mock", true)
	_store.set("_plugin", _store_backup)


## Le bug le plus coûteux d'un jeu à achats : un joueur qui réinitialise sa
## partie et qui doit racheter ce qu'il a déjà payé.
func _test_store_entitlement_survives_hard_reset() -> void:
	var plugin := FakeStore.new()
	plugin.owned["com.aurelien.idlegame.noads"] = true
	_store.set("_plugin", plugin)
	_store.set("mock", false)
	_store.call("_connect_plugin")

	var game: Variant = root.get_node_or_null("GameManager")
	# _apply_fresh_state est exactement ce que voit le jeu au redémarrage, sans
	# réécrire la sauvegarde. hard_reset() conviendrait aussi mais toucherait au
	# fichier, ce qu'un test n'a pas à faire.
	game.call("_apply_fresh_state")
	_check("après remise à zéro, l'état local a oublié l'achat",
		not bool((game.get("flags") as Dictionary).get("no_ads", false)))
	_check("le SDK, lui, s'en souvient", _store.is_purchased("supprimer_pubs"),
		"-> un joueur avait payé : le droit doit revenir")

	_store.set("mock", true)
	_store.set("_plugin", _store_backup)


func _test_store_prices_come_from_the_sdk() -> void:
	var plugin := FakeStore.new()
	plugin.prices["com.aurelien.idlegame.noads"] = "3,99 €"
	plugin.prices["com.aurelien.idlegame.pack.t1"] = "1,29 $"
	_store.set("_plugin", plugin)

	_check("le prix affiché vient de l'App Store",
		_store.get_display_price("supprimer_pubs") == "3,99 €",
		"-> %s" % _store.get_display_price("supprimer_pubs"))
	_check("une autre devise est respectée telle quelle",
		_store.get_display_price("pack_cristaux_1") == "1,29 $")
	_check("sans SDK, le catalogue de simulation prend le relais",
		_store.get_display_price("supprimer_pubs") == str(
			_store.get_product("supprimer_pubs").get("price", "")))

	_store.set("_plugin", _store_backup)


## Un plug-in compilé à moitié (ou une version plus ancienne) ne doit pas
## laisser le jeu dans un état muet : l'échec doit être explicite.
func _test_missing_plugin_methods_are_reported() -> void:
	var partial := RefCounted.new()
	# Les tests précédents ont accordé ce droit : sans l'oublier,
	# can_purchase() renverrait false et l'échec viendrait d'ailleurs.
	_store.set("_owned", {})
	var reasons: Array = []
	_store.purchase_failed.connect(func(id: String, reason: String) -> void: reasons.append(reason))
	_store.set("_plugin", partial)
	_store.set("mock", false)
	_store.purchase("supprimer_pubs")
	_check("un plug-in sans purchase() est signalé", reasons == ["plugin sans purchase()"],
		"-> %s" % [reasons])

	var reasons_ads: Array = []
	_ads.ad_failed.connect(func(id: String, reason: String) -> void: reasons_ads.append(reason))
	_ads.set("_plugin", RefCounted.new())
	_ads.set("mock", false)
	_ads.set("_busy", false)
	_ads.show_rewarded("production_boost")
	_check("un plug-in sans show_rewarded() est signalé",
		reasons_ads == ["plugin sans show_rewarded()"], "-> %s" % [reasons_ads])

	_ads.set("mock", true)
	_store.set("mock", true)
