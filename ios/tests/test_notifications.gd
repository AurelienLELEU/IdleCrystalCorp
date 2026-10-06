extends SceneTree
## Parcours GDScript des rappels locaux : permission, délai, succès/échec async,
## révocation et annulation. Le faux plugin teste le contrat sans demander la
## permission iOS sur la machine de CI.

class FakeNotifications:
	extends RefCounted

	signal permission_changed(state: String)
	signal schedule_completed(id: String, success: bool, reason: String)

	var permission := "not_determined"
	var requests: Array = []
	var cancel_calls := 0
	var settings_calls := 0

	func is_configured() -> bool:
		return true

	func get_permission() -> String:
		return permission

	func refresh_permission() -> void:
		permission_changed.emit(permission)

	func request_permission() -> void:
		permission = "granted"
		permission_changed.emit(permission)

	func schedule(id: String, title: String, body: String, delay: float) -> bool:
		requests.append([id, title, body, delay])
		return true

	func cancel_all() -> void:
		cancel_calls += 1

	func open_settings() -> void:
		settings_calls += 1


var _checks := 0
var _failures := 0
const TEST_SETTINGS := "user://test_notifications_settings.cfg"


func _initialize() -> void:
	print("=== test_notifications ===")
	await _run()
	print("=== test_notifications : %d vérifications, %d échecs ===" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _run() -> void:
	await process_frame
	var service: Variant = root.get_node_or_null("Notifications")
	var game: Variant = root.get_node_or_null("GameManager")
	_check(service != null, "autoload Notifications présent")
	_check(game != null, "autoload GameManager présent")
	if service == null or game == null:
		return

	var plugin_before: Variant = service.get("_plugin")
	var permission_before := str(service.get("_permission"))
	var enabled_before := bool(service.get("enabled"))
	service.set("_settings_path_override", TEST_SETTINGS)
	var fake := FakeNotifications.new()
	service.set("_plugin", fake)
	service.set("_permission", "not_determined")
	service.set("enabled", true)
	service.call("_connect_plugin")
	_check(bool(service.call("is_supported")), "le faux plugin actif rend les rappels disponibles")

	var permission_events: Array = []
	var scheduled_delays: Array = []
	var failures: Array = []
	var on_permission := func(state: String) -> void: permission_events.append(state)
	var on_scheduled := func(delay: float) -> void: scheduled_delays.append(delay)
	var on_failed := func(reason: String) -> void: failures.append(reason)
	service.permission_changed.connect(on_permission)
	service.reminder_scheduled.connect(on_scheduled)
	service.reminder_failed.connect(on_failed)
	service.call("request_permission")
	_check(service.call("get_permission") == "granted"
			and permission_events == ["requesting", "granted"],
		"permission : l'état n'est autorisé qu'après le callback du système")

	var config: GameConfig = game.get("config") as GameConfig
	var hours := float(config.offline.get("notify_after_hours", 0.0))
	_check(is_equal_approx(hours, 2.0), "configuration : le délai du rappel est de 2 h")
	var stats: Dictionary = game.get("stats")
	var scheduled_count_before := int(stats.get("notifications_scheduled", 0))
	game.call("_schedule_idle_notification")
	var requests: Array = fake.requests
	_check(requests.size() == 1 and requests[0][0] == "idle_reminder"
			and is_equal_approx(float(requests[0][3]), hours * 3600.0),
		"GameManager programme le rappel à l'échéance exacte (%d s)" % int(hours * 3600.0))
	_check(scheduled_delays.is_empty(),
		"le service n'annonce pas le succès avant la réponse asynchrone du système")

	fake.schedule_completed.emit("idle_reminder", true, "")
	_check(scheduled_delays == [7200.0],
		"le callback système confirme le rappel de 2 h")
	_check(int(stats.get("notifications_scheduled", 0)) == scheduled_count_before + 1,
		"le compteur n'avance qu'après confirmation asynchrone du système")
	fake.schedule_completed.emit("idle_reminder", false, "centre de notifications indisponible")
	_check(failures == ["centre de notifications indisponible"],
		"un échec système est propagé sans annoncer un faux succès")
	_check(int(stats.get("notifications_scheduled", 0)) == scheduled_count_before + 1,
		"un rappel refusé n'est pas compté comme programmé")

	fake.permission = "denied"
	fake.permission_changed.emit("denied")
	_check(service.call("get_permission") == "denied" and bool(service.get("enabled")),
		"permission refusée : le choix reste ON et l'UI propose Réglages iOS")
	var scheduled_while_denied: bool = bool(service.call("schedule_idle_reminder", 7200.0, {}))
	_check(not scheduled_while_denied,
		"permission refusée : le service ne programme pas de rappel")
	service.call("set_enabled", false)
	_check(fake.cancel_calls >= 1,
		"désactiver les rappels annule les requêtes locales en attente")
	var saved_settings := ConfigFile.new()
	var settings_loaded := saved_settings.load(TEST_SETTINGS) == OK
	_check(settings_loaded and not bool(saved_settings.get_value("notifications", "enabled", true)),
		"le choix ON/OFF survit à un redémarrage")

	# Parcours UI sans afficher le vrai dialogue OS : on réutilise le plugin faux
	# pour vérifier qu'« Autoriser » demande le droit et que « Réglages » ouvre la
	# page système après un refus.
	fake.permission = "not_determined"
	service.set("_permission", "not_determined")
	service.set("enabled", true)
	var main := (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Control
	root.add_child(main)
	await process_frame
	await process_frame
	main.call("_switch_page", "settings")
	await process_frame
	var notif_row: Variant = (main.get("_settings_rows") as Dictionary).get("notif")
	var notif_button := notif_row.get("button") as Button if notif_row != null else null
	_check(notif_button != null and notif_button.text == "Autoriser",
		"Réglages affiche Autoriser avant la première permission")
	if notif_button != null:
		notif_button.emit_signal("pressed")
	_check(notif_button != null and service.call("get_permission") == "granted"
			and notif_button.text == "ON",
		"le bouton Autoriser suit le résultat asynchrone et active le rappel")
	fake.permission = "denied"
	fake.permission_changed.emit("denied")
	await process_frame
	if notif_button != null:
		notif_button.emit_signal("pressed")
	_check(notif_button != null and fake.settings_calls == 1,
		"après refus, le bouton Réglages ouvre les réglages iOS")
	main.queue_free()
	await process_frame

	service.permission_changed.disconnect(on_permission)
	service.reminder_scheduled.disconnect(on_scheduled)
	service.reminder_failed.disconnect(on_failed)
	service.set("_plugin", plugin_before)
	service.set("_permission", permission_before)
	service.set("enabled", enabled_before)
	service.set("_settings_path_override", "")
	var settings_path := ProjectSettings.globalize_path(TEST_SETTINGS)
	if FileAccess.file_exists(TEST_SETTINGS):
		DirAccess.remove_absolute(settings_path)


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  ECHEC %s" % label)
