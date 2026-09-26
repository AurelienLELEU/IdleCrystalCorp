extends SceneTree

## Test d'interaction de l'interface : il ne se contente pas de vérifier que
## Main.tscn s'instancie, il manipule réellement l'UI.
##
##   ./tests/run.sh res://tests/test_ui_interaction.gd
##
## Pourquoi : les rafraîchissements de page (_refresh_buildings, _refresh_prestige,
## _refresh_store...) ne s'exécutent qu'à l'ouverture de l'onglet. Un simple
## test de compilation les laisse donc intacts. Or c'est là que vivent la plupart
## des erreurs d'exécution : chemin de nœud erroné, libellé manquant, index de
## ligne hors bornes.

const MAIN_SCENE := "res://scenes/Main.tscn"

## Un game manager isolé, pour ne pas dépendre d'une sauvegarde réelle.
const TEST_SAVE := "user://test_ui_save.dat"

var _failures: int = 0
var _checks: int = 0
var _ui: Node
var _game: Node


func _initialize() -> void:
	_game = root.get_node_or_null("GameManager")
	if _game == null:
		print("  ECHEC autoload GameManager introuvable")
		quit(1)
		return
	_run()


func _run() -> void:
	print("=== test_ui_interaction ===")
	await process_frame
	await process_frame

	_game.set("save_path_override", TEST_SAVE)
	_game.call("hard_reset")
	_game.set("pending_offline", {})

	var packed: PackedScene = load(MAIN_SCENE)
	if packed == null:
		_failures += 1
		print("  ECHEC Main.tscn introuvable")
		quit(1)
		return
	_ui = packed.instantiate()
	root.add_child(_ui)
	# L'écran principal écoute game_reset et se rafraîchit lui-même. Un reset
	# pendant les tests émet ce signal : il faut laisser le frames s'écouler,
	# sinon les modales ouvertes par _ready() (popup hors-ligne) sont encore
	# dans l'arbre et une reference NULL entre deux awaits coupe la coroutine.
	_ui.set("pending_offline", {})
	await process_frame
	await process_frame
	_check(is_instance_valid(_ui), "scène principale vivante après l'initialisation")
	if not is_instance_valid(_ui):
		quit(1)
		return

	# Chaque test est une coroutine (il contient `await process_frame`). Sans
	# `await` devant l'appel, GDScript les lance toutes en parallèle : elles
	# s'entrelacent, et le queue_free() final libère la scène pendant que les
	# autres sont encore suspendues. D'où des erreurs « previously freed ».
	await _test_all_pages_refresh()
	await _test_harvest_button()
	await _test_building_purchase()
	await _test_click_page_buy()
	await _test_research_page_buy()
	await _test_offline_popup()
	await _test_store_confirmation()
	await _test_restore_button()
	await _test_settings_toggles()
	await _test_ad_failure_single_toast()
	await _test_hard_reset_from_ui()
	await _test_responsive_layout()

	_ui.queue_free()
	await process_frame
	_remove_test_save()

	print("=== test_ui_interaction : %d vérifications, %d échecs ===" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


# ========================================================================= tests

## Chaque page doit s'ouvrir sans erreur et remplir ses lignes de texte.
func _test_all_pages_refresh() -> void:
	for page in ["buildings", "clicks", "research", "prestige", "achievements", "store", "settings"]:
		_ui.call("_switch_page", page)
		await process_frame
		_check(_ui.get("_current_page") == page, "page « %s » ouverte" % page)

		var scroll: Node = _ui.get("_pages")[page]
		_check(scroll != null and scroll.visible, "page « %s » visible" % page)
		if scroll == null or scroll.get_child_count() == 0:
			continue
		var box: Node = scroll.get_child(0)
		_check(box.get_child_count() > 0, "page « %s » remplie (%d entrées)"
			% [page, box.get_child_count()])
		_check(_no_empty_button_text(box), "page « %s » : aucun bouton sans libellé" % page)

	# Re-cliquer sur l'onglet deja ouvert referme la page. Apres la boucle
	# ci-dessus c'est « settings » qui est ouverte.
	_ui.call("_switch_page", "settings")
	await process_frame
	_check(_ui.get("_current_page") == "", "recliquer sur l'onglet ouvert referme la page")
	_check(not (_ui.get("_pages")["settings"] as Control).visible,
		"page refermee : elle est bien masquee")

	# Un onglet ferme ne se rouvre pas tout seul.
	_ui.call("_switch_page", "")
	await process_frame
	_check(_ui.get("_current_page") == "", "cliquer sur l'onglet fermé ne l'ouvre pas")

	# Et on rouvre normalement.
	_ui.call("_switch_page", "buildings")
	await process_frame
	_check(_ui.get("_current_page") == "buildings", "la page se rouvre")


func _test_harvest_button() -> void:
	var before: BigNum = _game.get("current_resources")
	_ui.call("_on_harvest_pressed")
	await process_frame
	_check((_game.get("current_resources") as BigNum).gt(before),
		"récolte : les ressources augmentent depuis l'UI")

	# Le libellé d'en-tête doit refléter la nouvelle valeur.
	var label: Label = _ui.get("_resource_label")
	_check(not label.text.is_empty(), "en-tête : compteur non vide (« %s »)" % label.text)
	var rate: Label = _ui.get("_rate_label")
	_check(rate.text.contains("/s"), "en-tête : débit affiché (« %s »)" % rate.text)


func _test_building_purchase() -> void:
	_game.call("hard_reset")
	_game.set("pending_offline", {})
	_game.call("grant_resources", BigNum.from_float(1e6), true)
	_ui.call("_switch_page", "buildings")
	await process_frame

	var rows: Dictionary = _ui.get("_page_data")["buildings"]["rows"]
	var bought := false
	for id in rows:
		if _game.call("buy_building", id, 1) == 1:
			bought = true
			break
	_check(bought, "achat : un bâtiment acheté via l'état du jeu")

	# Le rafraîchissement de la page doit refléter l'achat sans planter.
	_ui.call("_refresh_page", "buildings")
	await process_frame
	var row: Object = rows[(_game.get("config") as GameConfig).buildings[0].get("id", "")]
	if row != null:
		var title: Label = row.get("title")
		var subtitle: Label = row.get("subtitle")
		var button: Button = row.get("button")
		_check(not title.text.is_empty(), "ligne bâtiment : titre non vide")
		_check(subtitle.text.contains("Possédé"), "ligne bâtiment : compteur « Possédé » affiché")
		_check(not button.text.is_empty(), "ligne bâtiment : bouton étiqueté")


func _test_click_page_buy() -> void:
	_game.call("hard_reset")
	_game.set("pending_offline", {})
	_game.call("grant_resources", BigNum.from_float(1e12), true)
	_ui.call("_switch_page", "clicks")
	await process_frame

	var rows: Dictionary = _ui.get("_page_data")["clicks"]["rows"]
	var config: GameConfig = _game.get("config")
	var first_id: String = str(config.click_upgrades[0].get("id", ""))
	var level_before: int = _game.call("get_upgrade_level", first_id)
	_check(_game.call("buy_upgrade", first_id), "clics : amélioration achetée")
	_check(_game.call("get_upgrade_level", first_id) == level_before + 1, "clics : niveau augmenté")

	_ui.call("_refresh_page", "clicks")
	await process_frame
	var row: Object = rows[first_id]
	if row != null:
		var subtitle: Label = row.get("subtitle")
		_check(subtitle.text.contains("Niveau"), "ligne clic : niveau affiché (« %s »)"
			% subtitle.text.replace("\n", " / "))


func _test_research_page_buy() -> void:
	_game.call("hard_reset")
	_game.set("pending_offline", {})
	_game.call("grant_resources", BigNum.from_float(1e30), true)
	_ui.call("_switch_page", "research")
	await process_frame

	var config: GameConfig = _game.get("config")
	# Une technologie sans prérequis, achetable immédiatement.
	var target := ""
	for t in config.research:
		if t.get("requires", []).is_empty():
			target = str(t.get("id", ""))
			break
	_check(not target.is_empty(), "R&D : une technologie de départ existe")
	_check(_game.call("buy_research", target), "R&D : technologie achetée")
	_ui.call("_refresh_page", "research")
	await process_frame
	_check(true, "R&D : la page se rafraîchit après achat")


func _test_offline_popup() -> void:
	_game.call("hard_reset")
	_game.set("pending_offline", {})
	# Un bâtiment et une heure d'absence : le popup doit s'ouvrir.
	_game.set("buildings_owned", {"b1": 20})
	_game.set("buildings_total_owned", 20)
	_game.set("_production_dirty", true)
	_game.call("_recalculate")
	_game.set("production_at_save", _game.call("get_production_per_sec"))
	_game.set("last_save_timestamp", Time.get_unix_time_from_system() - 3600.0)
	_game.call("_compute_offline_gains")
	_check(_game.call("has_pending_offline"), "popup hors-ligne : gains en attente")

	var before: BigNum = _game.get("current_resources")
	var owed: BigNum = _game.call("get_pending_offline").get("amount", BigNum.zero())
	_ui.call("_show_offline_popup")
	await process_frame
	_check(_layer_child_count(_ui, "OverlayLayer") >= 1, "popup hors-ligne : modale ouverte")
	# La production continue pendant ce temps : on verifie que l'ecart reste
	# negligeable devant la somme annoncee, pas qu'il soit nul.
	var drift := (_game.get("current_resources") as BigNum).sub(before)
	_check(drift.lt(owed.mul_float(0.01)),
		"popup hors-ligne : rien n'est crédité tant que le joueur n'a rien choisi"
			+ " (%s de dérive pour %s annoncés)" % [drift.format_short(), owed.format_short()])

	# La modale propose au minimum « collecter » et « plus tard ».
	var modal: Node = _overlay_last(_ui, "OverlayLayer")
	if modal != null:
		var labels := _collect_button_texts(modal)
		var has_collect := false
		var has_decline := false
		for text in labels:
			if text.contains("Collecter"):
				has_collect = true
			if text.contains("Plus tard"):
				has_decline = true
		_check(has_collect, "popup hors-ligne : bouton « Collecter » présent (%s)" % str(labels))
		_check(has_decline, "popup hors-ligne : bouton « Plus tard » présent — le refus est possible")

		# Le gain annoncé doit correspondre à ce qui sera réellement crédité.
		var pending: Dictionary = _game.call("get_pending_offline")
		var amount: BigNum = pending.get("amount", BigNum.zero())
		var shown := false
		for text in labels:
			if text.contains(amount.format_short(1)) or text.contains(amount.format_short()):
				shown = true
		_check(shown, "popup hors-ligne : le montant crédité est affiché avant de proposer la pub")

		# On clique « Plus tard » : aucun gain hors-ligne, et la periode reste
		# reclamable au prochain lancement.
		_click_button_with_text(modal, "Plus tard")
		await process_frame
		_check((_game.get("current_resources") as BigNum).sub(before).lt(owed.mul_float(0.02)),
			"popup hors-ligne : « Plus tard » ne crédite rien")
		_check(_game.call("has_pending_offline"),
			"popup hors-ligne : les gains restent en attente, pas perdus")

		# On réouvre et on collecte : là, ça crédite une fois.
		_ui.call("_show_offline_popup")
		await process_frame
		modal = _overlay_last(_ui, "OverlayLayer")
		_click_button_with_text(modal, "Collecter")
		await process_frame
		_check((_game.get("current_resources") as BigNum).gt(before),
			"popup hors-ligne : « Collecter » crédite les gains")
		_check(not _game.call("has_pending_offline"),
			"popup hors-ligne : plus rien en attente après collecte")
		var snapshot: BigNum = _game.get("current_resources")
		_ui.call("_show_offline_popup")
		await process_frame
		_check((_game.get("current_resources") as BigNum).sub(snapshot)
				.lt(owed.mul_float(0.02)),
			"popup hors-ligne : rouvrir le popup ne crédite rien deux fois")
		# Plus rien en attente : la popup doit refuser de s'ouvrir plutot que
		# d'afficher « Collecter 0 ».
		_ui.call("_close_all_modals")
		await process_frame
		var layers_before: int = _layer_child_count(_ui, "OverlayLayer")
		_ui.call("_show_offline_popup")
		await process_frame
		_check(_layer_child_count(_ui, "OverlayLayer") == layers_before,
			"popup hors-ligne : aucune modale vide quand il n'y a plus rien à réclamer")


func _test_store_confirmation() -> void:
	_game.call("hard_reset")
	_game.set("pending_offline", {})
	_ui.call("_switch_page", "store")
	await process_frame

	var config: GameConfig = _game.get("config")
	var product: Dictionary = config.store_products[0]
	var product_id: String = str(product.get("id", ""))

	var store: Node = root.get_node_or_null("Store")
	if store == null:
		_check(false, "boutique : autoload Store présent")
		return
	_check(store.products_loaded.is_connected(Callable(_ui, "_on_store_products_loaded")),
		"boutique : l'interface rafraîchit les prix après le chargement asynchrone")
	# Garde sur la méthode AVANT de l'appeler. Un `call()` sur une méthode
	# inexistante ne lève rien en GDScript : la suite perdait les quatre
	# vérifications suivantes et annonçait quand même « 0 échec ». C'est le
	# faux vert le plus dangereux possible — une suite qui renonce sans le dire.
	_check(store.has_method("request_purchase"), "boutique : le Store sait demander un achat")
	if not store.has_method("request_purchase"):
		return
	store.call("request_purchase", product_id)
	await process_frame
	_check(_layer_child_count(_ui, "OverlayLayer") >= 1, "boutique : confirmation affichée")

	var modal: Node = _overlay_last(_ui, "OverlayLayer")
	if modal == null:
		_check(false, "boutique : modale de confirmation introuvable")
		return
	var buttons := _collect_button_texts(modal)
	var has_price := false
	var has_cancel := false
	for text in buttons:
		if text.contains(str(product.get("price", ""))):
			has_price = true
		if text.contains("Annuler"):
			has_cancel = true
	_check(has_price, "boutique : le vrai prix est affiché dans la confirmation (%s)" % str(buttons))
	_check(has_cancel, "boutique : « Annuler » présent au même niveau que « Acheter »")

	# Annuler ne doit rien acheter.
	_click_button_with_text(modal, "Annuler")
	await process_frame
	_check(not store.call("is_purchased", product_id),
		"boutique : « Annuler » n'achète rien")

	# Le produit de surcharge appelle lui aussi GameManager.notify() lors du
	# grant. L'UI écoute déjà purchase_completed pour le toast d'achat : sans le
	# grant silencieux, un seul paiement produit deux notifications. Exécuter le
	# trajet complet (demande -> confirmation -> paiement simulé), puis compter
	# les vrais nœuds Toast de la CanvasLayer.
	var boost_id := "boost_production"
	var toasts_before := _toast_count()
	store.call("request_purchase", boost_id)
	await process_frame
	var boost_modal: Node = _overlay_last(_ui, "OverlayLayer")
	_check(boost_modal != null, "boutique : confirmation de surcharge affichée")
	if boost_modal == null:
		return
	_click_button_with_text(boost_modal, "Acheter —")
	await process_frame
	await process_frame
	_check(int(_game.get("boost_stacks")) == 1,
		"boutique : la surcharge est bien accordée par le bouton de confirmation")
	_check(_toast_count() - toasts_before == 1,
		"boutique : un seul toast annonce un achat de surcharge (delta %d)"
			% (_toast_count() - toasts_before))


func _test_settings_toggles() -> void:
	_game.call("hard_reset")
	_game.set("pending_offline", {})
	_ui.call("_switch_page", "settings")
	await process_frame

	var ads: Variant = root.get_node_or_null("Ads")
	var audio: Variant = root.get_node_or_null("Audio")
	_check(ads != null, "réglages : autoload Ads présent")
	_check(audio != null, "réglages : autoload Audio présent")
	if ads == null or audio == null:
		return

	var ads_before: bool = bool(ads.get("enabled"))
	var muted_before: bool = bool(audio.get("muted"))
	_ui.call("_refresh_settings")
	await process_frame
	_ui.call("_refresh_settings")
	await process_frame
	_check(bool(ads.get("enabled")) == ads_before, "réglages : état des pubs inchangé")
	_check(bool(audio.get("muted")) == muted_before, "réglages : état du son inchangé")

	# Bascule du son : l'inverse, et rien ne doit planter.
	audio.call("set_muted", not muted_before)
	_ui.call("_refresh_settings")
	await process_frame
	_check(bool(audio.get("muted")) == not muted_before, "réglages : le son se bascule")
	audio.call("set_muted", muted_before)

	# Le timer quotidien peut expirer quand l'app est en arrière-plan. Sans
	# l'écoute de daily_bonus_changed, une page Réglages déjà ouverte reste
	# bloquée sur l'ancien état jusqu'à ce que le joueur change d'onglet.
	var daily: Variant = (_ui.get("_settings_rows") as Dictionary).get("daily")
	_check(daily != null, "réglages : ligne du bonus quotidien présente")
	if daily == null:
		return
	var stats: Dictionary = _game.get("stats")
	var now := Time.get_unix_time_from_system()
	stats["last_daily_claim"] = now
	_ui.call("_refresh_settings")
	_check(daily.button.disabled, "réglages : le bonus est bloqué avant les 24 h")
	stats["last_daily_claim"] = now - 86401.0
	var toasts_before := _toast_count()
	_game.emit_signal("daily_bonus_changed", true)
	await process_frame
	_check(not daily.button.disabled,
		"réglages : daily_bonus_changed réactive le bouton sans quitter la page")
	_check(_toast_count() - toasts_before == 1,
		"bonus quotidien : un seul toast annonce sa disponibilité")


func _test_ad_failure_single_toast() -> void:
	var ads: Variant = root.get_node_or_null("Ads")
	_check(ads != null, "pub : autoload Ads présent")
	if ads == null:
		return
	var game_messages: Array = []
	var on_message := func(_text: String, _kind: String) -> void:
		game_messages.append(true)
	_game.message.connect(on_message)
	var toasts_before := _toast_count()
	ads.call("_on_plugin_failed", "production_boost", "réseau indisponible")
	await process_frame
	_game.message.disconnect(on_message)
	_check(_toast_count() - toasts_before == 1 and game_messages.is_empty(),
		"pub : l'échec natif produit un seul toast, pas un double canal")


## Le bouton « Restaurer mes achats » doit exister ET déclencher la
## restauration. La méthode `StoreService.restore_purchases()` existait depuis le
## début, était correcte, était testée — et son seul appelant dans tout le
## projet était la suite de tests. Un joueur qui réinstalle l'application, ou qui
## change d'appareil, n'avait aucun moyen de retrouver ses droits : motif de
## refus de la revue (guideline 3.1.1).
##
## On clique le VRAI bouton, et on vérifie l'effet sur le Store, pas la
## présence d'une chaîne de caractères.
func _test_restore_button() -> void:
	_game.call("hard_reset")
	_game.set("pending_offline", {})
	_ui.call("_switch_page", "store")
	await process_frame

	var store: Node = root.get_node_or_null("Store")
	_check(store != null, "restauration : autoload Store présent")
	if store == null:
		return

	# Un achat que le Store connaît et que le jeu a oublié : c'est le scénario
	# réel d'une réinstallation.
	store.set("_owned", {})
	store.set("mock", true)
	store.set("_plugin", null)
	# L'ATTRIBUTION passe par le Store, pas par `GameManager.grant_store_product`
	# : c'est `_grant()` qui remplit `Store._owned`. Appeler le jeu
	# directement pose le drapeau du jeu et laisse le Store dans l'ignorance —
	# il n'y a alors rien à restaurer, et le test passerait ou échouerait pour la
	# mauvaise raison. (Fait : c'est ce que faisait la première version de ce
	# test, et elle échouait.)
	store.call("_grant", "supprimer_pubs")
	_check(_game.call("has_no_ads"), "restauration : l'achat est accordé")
	# `hard_reset()` ne convient PLUS ici : depuis la correction des droits,
	# il les rend lui-même. On simule donc directement l'oubli du jeu.
	_game.set("flags", {})
	_check(not _game.call("has_no_ads"), "restauration : le droit a bien été perdu")

	var toasts_before := _toast_count()
	_click_button_with_text(_ui, "Restaurer")
	await process_frame
	await process_frame
	_check(_game.call("has_no_ads"),
		"restauration : le bouton rend les droits, sans repayer")
	_check(_toast_count() - toasts_before == 1,
		"restauration : un seul toast de synthèse, pas un toast par achat (delta %d)"
			% (_toast_count() - toasts_before))
	store.set("_owned", {})


func _test_hard_reset_from_ui() -> void:
	_game.call("hard_reset")
	_game.set("pending_offline", {})
	_game.call("grant_resources", BigNum.from_float(1e30), true)
	_game.set("prestige_points", 9)

	_ui.call("_confirm_hard_reset")
	await process_frame
	var modal: Node = _overlay_last(_ui, "OverlayLayer")
	_check(modal != null, "reset : confirmation affichée")
	if modal == null:
		return
	var buttons := _collect_button_texts(modal)
	var has_cancel := false
	for text in buttons:
		if text.contains("Annuler"):
			has_cancel = true
	_check(has_cancel, "reset : confirmation annulable")

	# D'abord on annule : rien ne doit bouger.
	_click_button_with_text(modal, "Annuler")
	await process_frame
	_check(int(_game.get("prestige_points")) == 9, "reset : « Annuler » ne réinitialise pas")

	# Puis on confirme.
	_ui.call("_confirm_hard_reset")
	await process_frame
	modal = _overlay_last(_ui, "OverlayLayer")
	var toasts_before := _toast_count()
	_click_button_with_text(modal, "Oui, tout effacer")
	await process_frame
	_check(int(_game.get("prestige_points")) == 0, "reset : progression effacée après confirmation")
	_check((_game.get("current_resources") as BigNum).lt(BigNum.from_float(1e30)),
		"reset : ressources revenues au début")
	_check(_toast_count() - toasts_before == 1,
		"reset : un seul toast annonce la réinitialisation (delta %d)"
			% (_toast_count() - toasts_before))


## Un jeu idle se joue sur des écrans très inégaux, du petit téléphone à la
## tablette. La mise en page ne doit ni déborder ni se chevaucher.
func _test_responsive_layout() -> void:
	var host: Control = _ui.get("_page_host")
	_check(host != null, "mise en page : conteneur de pages présent")
	if host == null:
		return
	var bottom_bar: Control = _ui.get("_bottom_bar")
	var top_bar: Control = _ui.get("_top_bar")
	_check(bottom_bar.size.x > 0.0 and top_bar.size.x > 0.0,
		"mise en page : barres dimensionnées (%.0f / %.0f px)"
			% [bottom_bar.size.x, top_bar.size.x])
	_check(bottom_bar.size.x <= _ui.size.x + 1.0,
		"mise en page : la barre basse ne déborde pas (%.0f <= %.0f)"
			% [bottom_bar.size.x, _ui.size.x])
	# Les trois zones ne doivent pas se chevaucher.
	var resource_panel: Control = _ui.get_node("Root/Layout/ResourcePanel")
	_check(resource_panel.position.y >= top_bar.position.y + top_bar.size.y - 1.0,
		"mise en page : le compteur est sous la barre haute")
	_check(bottom_bar.position.y >= resource_panel.position.y + resource_panel.size.y - 1.0,
		"mise en page : la barre basse est sous le compteur")


# ======================================================================== outils

## Nombre de modales ouvertes dans une CanvasLayer.
func _layer_child_count(node: Node, layer_name: String) -> int:
	var layer: Node = node.get_node_or_null(layer_name)
	if layer == null:
		return 0
	return layer.get_child_count()


## Nombre de vrais toasts dans la couche de l'UI (les modales et autres enfants
## de la CanvasLayer ne comptent pas).
func _toast_count() -> int:
	var layer: Node = _ui.get_node_or_null("ToastLayer")
	if layer == null:
		return 0
	var count := 0
	for child in layer.get_children():
		if child is Toast:
			count += 1
	return count


func _overlay_last(node: Node, layer_name: String) -> Node:
	var layer: Node = node.get_node_or_null(layer_name)
	if layer == null or layer.get_child_count() == 0:
		return null
	return layer.get_child(layer.get_child_count() - 1)


## Tous les textes de boutons contenus dans un sous-arbre.
func _collect_button_texts(node: Node) -> PackedStringArray:
	var out := PackedStringArray()
	if node == null:
		return out
	if node is Button:
		out.append((node as Button).text)
	for child in node.get_children():
		out.append_array(_collect_button_texts(child))
	return out


func _click_button_with_text(node: Node, needle: String) -> void:
	if node == null:
		return
	for child in node.get_children():
		if child is Button and (child as Button).text.contains(needle):
			if not (child as Button).disabled:
				(child as Button).emit_signal("pressed")
			return
		_click_button_with_text(child, needle)


## Un bouton sans libellé est un bouton cassé : impossible à deviner.
func _no_empty_button_text(node: Node) -> bool:
	if node == null:
		return true
	if node is Button:
		# Seuls les boutons reellement a l'ecran doivent porter un libelle : une
		# ligne verrouillee est masquee, et son texte est pose au rafraichissement
		# qui precede son affichage. is_visible_in_tree() et non visible : le
		# masquage se fait sur le conteneur de la ligne, pas sur le bouton.
		if (node as Button).is_visible_in_tree() and (node as Button).text.strip_edges().is_empty():
			return false
	for child in node.get_children():
		if not _no_empty_button_text(child):
			return false
	return true


func _remove_test_save() -> void:
	for path in [TEST_SAVE, TEST_SAVE + ".tmp"]:
		if not FileAccess.file_exists(path):
			continue
		var dir := DirAccess.open(path.get_base_dir())
		if dir != null:
			dir.remove(path.get_file())


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  ok    ", label)
	else:
		_failures += 1
		print("  ECHEC ", label)
