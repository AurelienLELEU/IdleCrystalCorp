extends SceneTree
## Trois défauts de l'économie des pubs, tous vérifiés par EXÉCUTION.
##
##   godot --headless --path . --script res://tests/test_ads_economy.gd
##
## Les trois se ressemblent — un réglage de configuration qui ne borne rien —
## mais ils ne se vérifient pas de la même façon. Le premier se mesure en
## faisant tourner le compteur, le deuxième se mesure en faisant disparaître
## une fenêtre, le troisième se mesure en cherchant une chaîne dans l'UI. Les
## mettre dans un seul fichier est un choix de présentation, pas une affirmation
## qu'un test de source prouve un comportement : celui qui cherche une chaîne
## est explicitement étiqueté comme tel.

var _failed := 0
var _passed := 0
var _ads: Node = null
var _game: Variant = null


func _check(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  ok    %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s %s" % [label, detail])


func _initialize() -> void:
	print("== Économie des pubs ==")
	_ads = root.get_node_or_null("Ads")
	_game = root.get_node_or_null("GameManager")
	_check(_ads != null, "autoload Ads présent")
	_check(_game != null, "autoload GameManager présent")
	if _ads == null or _game == null:
		quit(1)
		return
	# Un `process_frame` avant toute lecture de configuration, et pas après :
	# `GameManager.config` est `null` tant que son `_ready()` n'a pas tourné, et
	# un autoload est déjà dans l'arbre avant que son `_ready()` ne soit appelé.
	# Sans cette attente, `AdService._settings_value()` rendait silencieusement
	# son valeur de REPLI — et comme le repli (`3`, `1`, `5`) est identique aux
	# valeurs de `data/game_config.json`, les plafonds semblaient lus dans la
	# configuration alors qu'ils n'étaient lus nulle part. Vérifié : en mettant
	# la configuration à 7, `daily_cap()` rendait 1 avant l'attente et 7 après.
	await process_frame
	await _run()


func _run() -> void:
	await _test_daily_caps_are_enforced()
	await _test_shared_budget_is_one_budget()
	await _test_daily_cap_is_a_setting_not_a_constant()
	await _test_overlay_vanishing_releases_the_busy_flag()
	await _test_every_reward_is_reachable()
	_restore_nominal_state()
	print("  -> %d reussis, %d echecs" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


## Remet les pubs dans l'état d'une partie neuve, et les drapeaux à zéro : un
## joueur ayant acheté « Supprimer les pubs » ne doit pas invalider ces tests.
func _restore_nominal_state() -> void:
	_ads.call("configure", (_game.get("config") as GameConfig).ads)
	_ads.set("_plugin", null)
	_ads.set("mock", true)
	_ads.set("_busy", false)
	_ads.set("_active_reward", "")
	_ads.set("_daily_counts", {})


# ====================================================================== plafonds

## Le double des gains hors-ligne était plafonné par un `return true` sans
## condition. Le plafond configuré — 1 par jour — n'existait donc que dans
## `data/game_config.json`, où aucune valeur ne pouvait l'atteindre.
##
## Mesuré avant correction : 8 doubles sur 8 tentatives, pour un plafond de 1.
## `production_boost` (3) et `free_crystals` (5) respectaient le leur, ce qui
## rendait l'exception d'autant plus suspecte — les trois passent par le même
## `is_available()`.
func _test_daily_caps_are_enforced() -> void:
	_restore_nominal_state()
	for id: String in ["offline_double", "production_boost", "free_crystals", "daily_double"]:
		_ads.set("_daily_counts", {})
		_ads.set("_busy", false)
		var cap: int = _ads.call("daily_cap", id)
		var used := 0
		# On tente largement plus que le plafond : si le plafond ne mord pas,
		# les 12 tentatives passent.
		for _i in 12:
			if not bool(_ads.call("is_available", id)):
				break
			_ads.set("_busy", false)
			_ads.call("_count_reward", id)
			used += 1
		_check(used == cap,
			"plafond « %s » : %d utilisations accordées, plafond = %d" % [id, used, cap])
		_check(not bool(_ads.call("is_available", id)),
			"plafond « %s » : plus rien après épuisement" % id)


## `daily_cap_offline_double` couvre le double hors-ligne ET celui du bonus
## quotidien. Les deux lisaient la même valeur de configuration mais comptaient
## dans deux clés séparées : le joueur dépensait deux fois le budget prévu.
##
## Le test vérifie l'EFFET — le double du bonus devient indisponible une fois le
## double hors-ligne pris — et non la présence d'une clé dans un dictionnaire,
## qui ne prouverait rien sur la disponibilité.
func _test_shared_budget_is_one_budget() -> void:
	_restore_nominal_state()
	_ads.set("_busy", false)
	var cap: int = _ads.call("daily_cap", "daily_double")
	_check(cap == 1, "le double du bonus quotidien a un plafond configuré", "-> %d" % cap)
	for _i in cap:
		_ads.set("_busy", false)
		_ads.call("_count_reward", "offline_double")
	_check(int(_ads.call("get_daily_count", "offline_double")) == cap,
		"le seau hors-ligne est consommé")
	_check(int(_ads.call("get_daily_count", "daily_double")) == cap,
		"le bonus quotidien lit le MÊME compteur, pas le sien",
		"-> %d au lieu de %d" % [_ads.call("get_daily_count", "daily_double"), cap])
	_check(not bool(_ads.call("is_available", "daily_double")),
		"le double du bonus est indisponible une fois le budget commun pris")

	# Et l'inverse, parce qu'un seau partagé doit l'être dans les deux sens.
	_restore_nominal_state()
	_ads.set("_busy", false)
	_ads.call("_count_reward", "daily_double")
	_check(int(_ads.call("get_daily_count", "offline_double")) == 1,
		"un double du bonus consomme aussi le budget hors-ligne")
	_check(not bool(_ads.call("is_available", "offline_double")),
		"le double hors-ligne devient indisponible après un double du bonus")


## Si le plafond restait une constante codée en dur, le correctif ci-dessus
## aurait juste remplacé un magic number par un autre. Ce test prouve que le
## réglage est vivant : le changer dans la configuration change le nombre
## d'utilisations accordées.
func _test_daily_cap_is_a_setting_not_a_constant() -> void:
	_restore_nominal_state()
	var cfg: GameConfig = _game.get("config") as GameConfig
	var original: Variant = cfg.ads.get("daily_cap_offline_double")
	cfg.ads["daily_cap_offline_double"] = 4
	_check(int(_ads.call("daily_cap", "offline_double")) == 4,
		"le plafond suit la configuration", "-> %d" % _ads.call("daily_cap", "offline_double"))
	_ads.set("_daily_counts", {})
	_ads.set("_busy", false)
	var used := 0
	for _i in 10:
		if not bool(_ads.call("is_available", "offline_double")):
			break
		_ads.set("_busy", false)
		_ads.call("_count_reward", "offline_double")
		used += 1
	_check(used == 4, "et le nombre d'utilisations suit avec", "-> %d au lieu de 4" % used)
	cfg.ads["daily_cap_offline_double"] = original
	_check(int(_ads.call("daily_cap", "offline_double")) == int(original),
		"et le réglage se restaure")


# ===================================================================== filet de sécurité

## Fermer la fenêtre de l'application pendant une pub laissait `_busy` à `true`
## jusqu'au redémarrage. `is_available()` rendait alors `false` pour TOUTE
## récompense, l'UI désactivait « Regarder » avec « Indisponible pour le
## moment », et rien n'expliquait pourquoi : plus aucune pub de la session.
##
## Le test monte une VRAIE fenêtre via `_mount_mock_overlay()` et la fait
## disparaître, sans passer par `complete()` ni `abort()` — c'est exactement le
## chemin de la fermeture de fenêtre. Appeler `_open_mock_overlay()` ne
## conviendrait pas : en headless cette fonction ne crée aucun overlay, et le
## test passerait au vert sans exécuter une seule ligne du filet.
func _test_overlay_vanishing_releases_the_busy_flag() -> void:
	_restore_nominal_state()
	_ads.set("_daily_counts", {})
	var failures: Array = []
	_ads.ad_failed.connect(func(id: String, reason: String) -> void:
		failures.append([id, reason]))

	_ads.set("_busy", true)
	_ads.set("_active_reward", "production_boost")
	_ads.call("_mount_mock_overlay")
	var overlay: Variant = _ads.get("_overlay")
	_check(is_instance_valid(overlay), "une fenêtre de pub est montée")
	_check(not bool(_ads.call("is_available", "production_boost")),
		"pendant une pub, aucune récompense n'est offerte")

	# L'overlay disparaît sans rendre son verdict.
	overlay.queue_free()
	await process_frame
	await process_frame

	_check(not bool(_ads.get("_busy")),
		"la fenêtre disparue libère le service : sinon plus aucune pub de session")
	_check(str(_ads.get("_active_reward")) == "",
		"et la récompense en cours est vidée")
	_check(failures == [["production_boost", "pub interrompue"]],
		"le joueur est prévenu, pas laissé devant un bouton mort",
		"-> %s" % [failures])
	_check(bool(_ads.call("is_available", "production_boost")),
		"les pubs redeviennent disponibles juste après")

	# Et le cas normal ne doit pas être touché : `complete()` rend son verdict
	# AVANT que l'overlay parte, donc le filet ne doit pas déclencher un
	# second échec pour une pub pourtant réussie.
	failures.clear()
	_ads.set("_busy", true)
	_ads.set("_active_reward", "free_crystals")
	_ads.call("_mount_mock_overlay")
	_ads.call("complete", "free_crystals")
	(_ads.get("_overlay") as Node).queue_free()
	await process_frame
	await process_frame
	_check(failures.is_empty(), "une pub réussie n'émet aucun échec",
		"-> %s" % [failures])
	_check(not bool(_ads.get("_busy")), "et le service est bien libéré")
	_restore_nominal_state()


# ================================================================ atteignabilité

## Deux récompenses sur quatre n'étaient atteignables par aucun bouton :
## `REWARD_PRODUCTION_BOOST` et `REWARD_DAILY_DOUBLE`. Tout leur code existait
## et fonctionnait — compteur, plafond, crédit dans `_on_ad_completed()`,
## constantes `BOOST_AD_MULTIPLIER` — mais aucun chemin n'y menait.
##
## ATTENTION : ceci est un test de SOURCE, pas de comportement. Il prouve que la
## chaîne est présente, pas que le bouton fonctionne. Le comportement est
## couvert ailleurs (`test_ui_interaction` pour le bonus quotidien,
## `test_plugin_contract` pour le crédit des récompenses) ; ici on vérifie
## seulement qu'aucune récompense n'est oubliée, ce qu'un test de comportement
## ne peut pas dire — un jeu sans bouton passe tous les tests de crédit.
func _test_every_reward_is_reachable() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/MainUI.gd")
	_check(not src.is_empty(), "atteignabilité : lecture de MainUI.gd")
	if src.is_empty():
		return
	# Contrôle d'écho : sans lui, une forme de chaîne fausse ferait passer
	# les quatre contrôles suivants pour de bonnes raisons.
	_check(src.contains("Ads.show_rewarded(Ads.REWARD_FREE_CRYSTALS)"),
		"atteignabilité : le contrôle d'écho matche bien la forme attendue")
	for id: String in ["PRODUCTION_BOOST", "DAILY_DOUBLE", "FREE_CRYSTALS", "OFFLINE_DOUBLE"]:
		_check(src.contains("Ads.show_rewarded(Ads.REWARD_%s)" % id),
			"la récompense « %s » a un bouton" % id)
	# Les quatre constantes de l'énumération d'AdService : une cinquième
	# récompense ajoutée sans bouton serait invisible du coup d'œil.
	_check(src.contains("Ads.REWARD_PRODUCTION_BOOST")
			and src.contains("Ads.REWARD_DAILY_DOUBLE")
			and src.contains("Ads.REWARD_FREE_CRYSTALS")
			and src.contains("Ads.REWARD_OFFLINE_DOUBLE"),
		"les quatre récompenses connues sont toutes citées par l'UI")
