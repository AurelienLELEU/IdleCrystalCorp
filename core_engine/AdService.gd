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
	match reward_id:
		REWARD_PRODUCTION_BOOST:
			return int(_settings_value("daily_cap_production_boost", 3))
		REWARD_OFFLINE_DOUBLE, REWARD_DAILY_DOUBLE:
			return int(_settings_value("daily_cap_offline_double", 1))
		REWARD_FREE_CRYSTALS:
			return int(_settings_value("daily_cap_free_crystals", 5))
	return 99


func get_daily_count(reward_id: String) -> int:
	return int(_daily_counts.get("%s:%d" % [reward_id, _today()], 0))


## Une récompense pub n'est jamais due si le joueur a acheté « Supprimer les pubs ».
func is_available(reward_id: String) -> bool:
	if not enabled or _busy:
		return false
	var game: Variant = _game()
	if game != null and bool(game.call("has_no_ads")):
		return false
	if reward_id == REWARD_OFFLINE_DOUBLE:
		# Une seule fois par popup : c'est le popup lui-même qui borne l'usage.
		return true
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
	_overlay = _build_mock_overlay()
	var layer := CanvasLayer.new()
	layer.layer = 120
	layer.add_child(_overlay)
	add_child(layer)
	_overlay.tree_exited.connect(func() -> void:
		layer.queue_free()
		if is_instance_valid(_overlay):
			_overlay = null
	)


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
	var key := "%s:%d" % [reward_id, _today()]
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
