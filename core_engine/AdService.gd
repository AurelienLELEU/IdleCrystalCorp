extends Node

## Autoload : Ads
##
## Pubs récompensées. Le jeu est intégralement jouable sans pub et sans achat :
## une pub n'est jamais un verrou, seulement un accélérateur optionnel. C'est un
## choix de conception, pas une contrainte technique.
##
## Deux modes :
##   - mock (par défaut) : une fausse pub générée en interne, pour développer et
##     tester tout le parcours de récompense sans SDK. Elle est étiquetée
##     « SIMULATION » à l'écran pour qu'on ne la confonde jamais avec une vraie pub.
##   - plugin : un SDK réel (AdMob, Unity Ads, ironSource...) exposé via la même
##     interface, voir README.md.
##
## Plafonds quotidiens : une pub récompensée n'est pas « infinie ». C'est la pratique
## standard des réseaux et, surtout, ça évite un jeu dégradé pour le joueur.

signal ad_started(reward_id: String)
signal ad_completed(reward_id: String)
signal ad_failed(reward_id: String, reason: String)

const REWARD_OFFLINE_DOUBLE := "offline_double"
const REWARD_PRODUCTION_BOOST := "production_boost"
const REWARD_DAILY_DOUBLE := "daily_double"
const REWARD_FREE_CRYSTALS := "free_crystals"

const PLUGIN_CLASS := "IdleAds"

var enabled: bool = true
var mock: bool = true
var duration_seconds: float = 5.0

var _plugin: Object = null
var _daily_counts: Dictionary = {}
var _busy: bool = false
var _overlay: Control = null
var _active_reward: String = ""


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


## Branche les signaux du SDK sur nos propres états.
##
## Le plug-in ne rappelle pas l'autoload `Ads` : il émet des signaux, et c'est
## ici qu'on les traduit. Un appel natif vers un autoload depuis une tâche
## Objective-C ou Swift n'est pas fiable — le nœud peut être en cours de
## destruction quand le rappel arrive, et un signal reçu par un objet invalide
## plante sans laisser de trace exploitable.
func _connect_plugin() -> void:
	if _plugin == null or not is_instance_valid(_plugin):
		return
	if _plugin.has_signal("rewarded_completed"):
		_plugin.connect("rewarded_completed", complete)
	if _plugin.has_signal("rewarded_failed"):
		_plugin.connect("rewarded_failed", _on_plugin_failed)


func _on_plugin_failed(reward_id: String, reason: String) -> void:
	abort(reward_id, reason if not reason.is_empty() else "pub indisponible")
	# Une pub indisponible est normale : on l'annonce discrètement, sans message
	# d'erreur en rouge qui ferait croire à un bug. Le joueur garde son gain
	# hors-ligne, il perd simplement l'accélérateur — ce qui est la seule
	# sanction acceptable quand on a promis qu'aucun achat ni pub n'est requis.
	GameManager.notify("Publicité indisponible. Récompense non délivrée.", "warn")


## Passe les identifiants AdMob au SDK. Sans effet en mode simulation.
##
## `debug` DOIT valoir true pendant le développement : c'est ce qui fait
## afficher les annonces de test de Google au lieu des vraies. Voir
## native/ads/ios/idle_ads_ios.mm pour pourquoi c'est non négociable.
func configure_plugin(app_id: String, rewarded_unit_id: String, debug: bool) -> bool:
	if _plugin == null or not _plugin.has_method("configure"):
		return false
	_plugin.call("configure", app_id, rewarded_unit_id, debug)
	return true


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_close_overlay()


func configure(settings: Dictionary) -> void:
	enabled = bool(settings.get("enabled", true))
	mock = bool(settings.get("mock", true))
	duration_seconds = maxf(1.0, float(settings.get("duration_seconds", 5.0)))


func is_busy() -> bool:
	return _busy


func daily_cap(reward_id: String) -> int:
	match _cap_bucket(reward_id):
		REWARD_PRODUCTION_BOOST:
			return int(_settings_value("daily_cap_production_boost", 3))
		REWARD_OFFLINE_DOUBLE:
			return int(_settings_value("daily_cap_offline_double", 1))
		REWARD_FREE_CRYSTALS:
			return int(_settings_value("daily_cap_free_crystals", 5))
	return 99


## Le budget se compte par SEAU, pas par récompense.
##
## `daily_cap_offline_double` couvre le double des gains hors-ligne ET celui du
## bonus quotidien : les deux lisent la même valeur de configuration, donc elles
## doivent partager le même compteur. `get_daily_count()` indexait par
## `reward_id`, si bien qu'un joueur pouvait dépenser deux fois le budget prévu
## en alternant les deux — vérifié par exécution, pas déduit du code.
##
## Le seau n'est PAS l'inverse de `is_purchased()` côté boutique : c'est le même
## principe — une valeur de configuration partagée doit n'avoir qu'un seul
## compteur, sinon elle ne borne rien.
func _cap_bucket(reward_id: String) -> String:
	if reward_id == REWARD_DAILY_DOUBLE:
		return REWARD_OFFLINE_DOUBLE
	return reward_id


func get_daily_count(reward_id: String) -> int:
	return int(_daily_counts.get("%s:%d" % [_cap_bucket(reward_id), _today()], 0))


## Une récompense pub n'est jamais due si le joueur a acheté « Supprimer les pubs ».
##
## Le double des gains hors-ligne était court-circuité par un `return true` sans
## condition, avec le commentaire « une seule fois par popup : c'est le popup
## lui-même qui borne l'usage ». Cette borne n'existe pas : `pending_offline`
## se remplit à chaque retour au premier plan, donc le popup revient toutes les
## 60 secondes, et le joueur pouvait doubler ses gains hors-ligne autant de fois
## qu'il le voulait. Mesuré : 8 doubles sur 8 tentatives, pour un plafond
## configuré à 1. `daily_cap_offline_double` était donc du code mort — et
## `production_boost` et `free_crystals` respectaient bien le leur, ce qui rendait
## l'exception d'autant plus suspecte.
##
## Le plafond configuré fait désormais autorité. Si vous voulez un double
## hors-ligne illimité, mettez `daily_cap_offline_double` à 99 dans
## `data/game_config.json` : c'est un réglage, pas une branche codée en dur.
func is_available(reward_id: String) -> bool:
	if not enabled or _busy:
		return false
	# StoreKit charge les droits existants de façon asynchrone. Échouer fermé
	# pendant cette fenêtre évite qu'un acheteur « Supprimer les pubs » voie une
	# annonce à la réinstallation, avant que GameManager ne récupère son droit.
	var store: Variant = get_node_or_null("/root/Store")
	if store != null and store.has_method("are_entitlements_ready") \
			and not bool(store.call("are_entitlements_ready")):
		return false
	var game: Variant = _game()
	if game != null and bool(game.call("has_no_ads")):
		return false
	return get_daily_count(reward_id) < daily_cap(reward_id)


func show_rewarded(reward_id: String) -> void:
	if _busy:
		ad_failed.emit(reward_id, "une pub est déjà en cours")
		return
	if not is_available(reward_id):
		ad_failed.emit(reward_id, "récompense indisponible")
		return
	_busy = true
	_active_reward = reward_id
	ad_started.emit(reward_id)
	if mock or _plugin == null:
		_open_mock_overlay()
	elif _plugin.has_method("show_rewarded"):
		_plugin.call("show_rewarded", reward_id)
	else:
		_fail("plugin sans show_rewarded()")


## À appeler par l'UI une fois la récompense réellement accordée, ou par le SDK.
func complete(reward_id: String) -> void:
	if not _busy:
		return
	_count_reward(reward_id)
	_busy = false
	_active_reward = ""
	ad_completed.emit(reward_id)


## Interruption de la pub. Rien n'est crédité.
##
## `reason` vient du SDK quand il y en a une : « réseau indisponible » et
## « pub interrompue » ne demandent pas la même réaction du joueur, et un
## message générique sur une coupure réseau passagère donne l'impression
## d'un bug alors que c'est un état normal et temporaire.
func abort(reward_id: String, reason: String = "pub interrompue") -> void:
	_busy = false
	_active_reward = ""
	ad_failed.emit(reward_id, reason)


# ------------------------------------------------------------------ simulation

func _open_mock_overlay() -> void:
	if DisplayServer.get_name() == "headless":
		# Pas de fenêtre (tests) : on simule le résultat sans afficher.
		await get_tree().create_timer(0.05).timeout
		complete(_active_reward)
		return
	_mount_mock_overlay()


## Monte la fenêtre de pub simulée et branche le filet de sécurité.
##
## Séparée de `_open_mock_overlay()` pour une raison qui n'est pas le style :
## la branche headless de cette fonction-ci ne crée jamais d'overlay, donc un
## test du filet de sécurité qui l'appellerait ne testerait jamais le filet de
## sécurité. Il passerait au vert en n'exerçant aucune des lignes qu'il prétend
## couvrir. Ici, le test monte une VRAIE fenêtre et la fait disparaître pour de
## vrai.
func _mount_mock_overlay() -> void:
	_overlay = _build_mock_overlay()
	var layer := CanvasLayer.new()
	layer.layer = 120
	layer.add_child(_overlay)
	add_child(layer)
	_overlay.tree_exited.connect(func() -> void: _on_overlay_exited(layer))


func _on_overlay_exited(layer: CanvasLayer) -> void:
	# Filet de sécurité, capté AVANT le nettoyage : l'overlay peut disparaître
	# sans avoir rendu son verdict — fenêtre fermée,
	# `NOTIFICATION_WM_CLOSE_REQUEST`, scène supprimée. `complete()` et
	# `abort()` remettent tous deux `_busy` à faux ET vident `_active_reward`
	# avant que `tree_exited` ne parte, donc ce test ne les touche pas.
	#
	# Sans ce filet, `_busy` restait à `true` jusqu'au redémarrage de
	# l'application : `is_available()` rendait alors `false` pour TOUTE
	# récompense, l'UI désactivait « Regarder » en écrivant « Indisponible
	# pour le moment », et rien n'indiquait au joueur qu'une pub était en
	# cours. C'est-à-dire : plus aucune pub de la session, sans explication.
	var was_busy := _busy
	var pending := _active_reward
	layer.queue_free()
	if is_instance_valid(_overlay):
		_overlay = null
	if was_busy and not pending.is_empty():
		_busy = false
		_active_reward = ""
		ad_failed.emit(pending, "pub interrompue")


func _build_mock_overlay() -> Control:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP

	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.02, 0.05, 0.97)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	var panel := VBoxContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_theme_constant_override("separation", 14)
	panel.offset_left = 24
	panel.offset_right = -24
	# `root.add_child(panel)`, et surtout pas `panel.add_child(bg)` : un nœud ne
	# peut avoir qu'un seul parent, et Godot le DÉPLACE silencieusement. Le fond
	# disparaissait donc de la racine et se retrouvait empilé dans le panneau,
	# au-dessus de son propre contenu.
	root.add_child(panel)

	var sim_tag := Label.new()
	sim_tag.text = "PUB — SIMULATION (aucun réseau appelé)"
	sim_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sim_tag.modulate = Color(1.0, 0.55, 0.2)
	panel.add_child(sim_tag)

	var title := Label.new()
	title.text = "Espace publicitaire"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	panel.add_child(title)

	var countdown := Label.new()
	countdown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown.add_theme_font_size_override("font_size", 64)
	countdown.text = "%d" % int(duration_seconds)
	panel.add_child(countdown)

	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(0, 14)
	bar.max_value = duration_seconds
	bar.value = 0.0
	bar.show_percentage = false
	panel.add_child(bar)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 20)
	panel.add_child(spacer)

	var reward_btn := Button.new()
	reward_btn.text = "Récompense indisponible"
	reward_btn.disabled = true
	reward_btn.custom_minimum_size = Vector2(0, 56)
	panel.add_child(reward_btn)

	var elapsed := 0.0
	var ticker := Timer.new()
	ticker.wait_time = 0.1
	ticker.timeout.connect(func() -> void:
		elapsed = minf(elapsed + ticker.wait_time, duration_seconds)
		bar.value = elapsed
		countdown.text = "%d" % int(ceilf(duration_seconds - elapsed))
		if elapsed >= duration_seconds:
			ticker.stop()
			reward_btn.disabled = false
			reward_btn.text = "🎁 Recevoir la récompense"
	)
	root.add_child(ticker)
	# PAS ICI. Cette fonction renvoie `root` sans l'avoir encore ajouté à
	# l'arbre, et `Timer.start()` refuse de démarrer hors arbre : « Unable to
	# start the timer because it's not inside the scene tree ». Le compte à
	# rebours ne tournait donc jamais, et le bouton « Recevoir la récompense »
	# restait désactivé pour toujours — la pub simulée bloquait le joueur en plein
	# développement. Le démarrage attend le premier passage dans l'arbre.
	root.ready.connect(func() -> void: ticker.start())

	reward_btn.pressed.connect(func() -> void:
		if not is_instance_valid(root):
			return
		var reward := _active_reward
		root.queue_free()
		complete(reward)
	)

	return root


# ----------------------------------------------------------------------- interne

func _count_reward(reward_id: String) -> void:
	# Le SEAU, pas la récompense : voir `_cap_bucket()`. Compter par récompense
	# donnait au joueur deux fois le budget de `daily_cap_offline_double`.
	var key := "%s:%d" % [_cap_bucket(reward_id), _today()]
	_daily_counts[key] = int(_daily_counts.get(key, 0)) + 1
	var game: Variant = _game()
	if game != null:
		var stats: Dictionary = game.get("stats")
		stats["ads_watched"] = int(stats.get("ads_watched", 0)) + 1
		game.set("stats", stats)


func _fail(reason: String) -> void:
	var reward := _active_reward
	_busy = false
	_active_reward = ""
	ad_failed.emit(reward, reason)


func _close_overlay() -> void:
	if is_instance_valid(_overlay):
		_overlay.queue_free()


func _today() -> int:
	return int(Time.get_unix_time_from_system() / 86400.0)


func _settings_value(key: String, fallback: Variant) -> Variant:
	var game: Variant = _game()
	if game == null:
		return fallback
	# Type GameConfig explicite : avec un Variant, `cfg.get("x", defaut)` se
	# résout vers Object.get( propriete), qui n'accepte qu'un seul argument.
	var cfg: GameConfig = game.get("config") as GameConfig
	if cfg == null:
		return fallback
	return cfg.ads.get(key, fallback)


func _game() -> Variant:
	return get_node_or_null("/root/GameManager")
