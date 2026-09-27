extends Node

## Autoload : Notifications
##
## Programation de notifications locales (« vos gains vous attendent »).
##
## IMPORTANT — Godot 4.7 n'expose aucune API de notification locale dans son core :
## sur iOS il faut un plugin natif. Cette classe est donc la couche d'abstraction
## qui appelle le plugin s'il est présent, et se dégrade proprement sinon.
##
## GDExtension native IdleNotifications (UserNotifications sur iOS/macOS) :
##
##   get_permission() -> String
##   refresh_permission() -> void
##   request_permission() -> void          # émet permission_changed(state)
##   schedule(id: String, title: String, body: String, delay_seconds: float) -> bool
##   cancel(id: String) -> void
##   cancel_all() -> void
##   open_settings() -> void
##
## Sans plugin, le jeu fonctionne quand même : la popup de retour hors-ligne et
## le bandeau in-game font le même travail, et `is_supported()` vaut false.
## L'extension Swift est dans native/notifications/.

signal permission_changed(state: String)
signal reminder_scheduled(delay_seconds: float)
signal reminder_failed(reason: String)

const PLUGIN_CLASS := "IdleNotifications"
const REMINDER_ID := "idle_reminder"
const SETTINGS_PATH := "user://notification_settings.cfg"

var enabled: bool = true
var _permission: String = "not_determined"
var _plugin: Object = null
## Injecté uniquement par les tests pour isoler la préférence utilisateur.
var _settings_path_override := ""
## Rappel demandé mais non programmable : l'interface peut l'afficher au retour.
var _pending_delay: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_user_preference()
	_load_plugin()


func _settings_path() -> String:
	return _settings_path_override if not _settings_path_override.is_empty() else SETTINGS_PATH


func _load_user_preference() -> void:
	var settings := ConfigFile.new()
	if settings.load(_settings_path()) == OK:
		enabled = bool(settings.get_value("notifications", "enabled", true))


func _save_user_preference() -> void:
	var settings := ConfigFile.new()
	settings.load(_settings_path())
	settings.set_value("notifications", "enabled", enabled)
	var error := settings.save(_settings_path())
	if error != OK:
		push_warning("Préférence de notification non enregistrée : %s" % error_string(error))


func _load_plugin() -> void:
	if not ClassDB.class_exists(PLUGIN_CLASS):
		_permission = "unsupported"
		return
	var instance: Variant = ClassDB.instantiate(PLUGIN_CLASS)
	if instance == null:
		_permission = "unsupported"
		return
	_plugin = instance
	if _plugin is Node:
		add_child(_plugin as Node)
	if _plugin.has_method("is_configured") and not bool(_plugin.call("is_configured")):
		_permission = "unsupported"
		_dispose_plugin()
		return
	_connect_plugin()
	if _plugin.has_method("get_permission"):
		_permission = str(_plugin.call("get_permission"))
	if _plugin.has_method("refresh_permission"):
		_plugin.call("refresh_permission")


func _connect_plugin() -> void:
	if _plugin == null or not is_instance_valid(_plugin):
		return
	if _plugin.has_signal("permission_changed") \
			and not _plugin.is_connected("permission_changed", _on_plugin_permission_changed):
		_plugin.connect("permission_changed", _on_plugin_permission_changed)
	if _plugin.has_signal("schedule_completed") \
			and not _plugin.is_connected("schedule_completed", _on_plugin_schedule_completed):
		_plugin.connect("schedule_completed", _on_plugin_schedule_completed)


func _exit_tree() -> void:
	# IdleNotifications est un Object natif non-RefCounted : le service en est
	# propriétaire et doit le libérer explicitement.
	_dispose_plugin()


func _dispose_plugin() -> void:
	var plugin := _plugin
	_plugin = null
	if plugin == null or not is_instance_valid(plugin):
		return
	if plugin is Node or plugin is RefCounted:
		return
	plugin.free()


func is_supported() -> bool:
	return _plugin != null and is_instance_valid(_plugin) \
		and (not _plugin.has_method("is_configured") or bool(_plugin.call("is_configured")))


func get_permission() -> String:
	return _permission


func get_pending_delay() -> float:
	return _pending_delay


func request_permission() -> void:
	if _plugin == null:
		_permission = "unsupported"
		permission_changed.emit(_permission)
		return
	if _plugin.has_method("request_permission"):
		_permission = "requesting"
		permission_changed.emit(_permission)
		_plugin.call("request_permission")
	else:
		_permission = "unsupported"
		permission_changed.emit(_permission)


func refresh_permission() -> void:
	if _plugin != null and _plugin.has_method("refresh_permission"):
		_plugin.call("refresh_permission")


func open_settings() -> void:
	if _plugin != null and _plugin.has_method("open_settings"):
		_plugin.call("open_settings")


func _on_plugin_permission_changed(state: String) -> void:
	_permission = state
	if state == "denied":
		cancel_all()
	permission_changed.emit(_permission)


func _on_plugin_schedule_completed(id: String, success: bool, reason: String) -> void:
	if id != REMINDER_ID:
		return
	if success:
		reminder_scheduled.emit(_pending_delay)
	else:
		reminder_failed.emit(reason if not reason.is_empty() else "échec de la programmation")


## Programme un rappel dans `delay_seconds`. Idempotent : un second appel
## remplace le premier (iOS n'empile pas les rappels, on évite les doublons).
func schedule_idle_reminder(delay_seconds: float, payload: Dictionary) -> bool:
	_pending_delay = maxf(0.0, delay_seconds)
	if not enabled:
		reminder_failed.emit("notifications désactivées")
		return false
	if _plugin == null:
		reminder_failed.emit("aucun plugin de notification locale installé")
		return false
	if _permission != "granted" and _permission != "provisional":
		reminder_failed.emit("autorisation de notification non accordée")
		return false
	var ok: bool = false
	if _plugin.has_method("schedule"):
		ok = _plugin.call(
			"schedule",
			REMINDER_ID,
			str(payload.get("title", "Revenez jouer")),
			str(payload.get("body", "")),
			_pending_delay
		)
	if not ok:
		reminder_failed.emit("le plugin a refusé la programmation")
	# Le résultat réel arrive de manière asynchrone via schedule_completed.
	return ok


func cancel_all() -> void:
	_pending_delay = 0.0
	if _plugin != null and _plugin.has_method("cancel_all"):
		_plugin.call("cancel_all")


func set_enabled(value: bool) -> void:
	enabled = value
	_save_user_preference()
	if not enabled:
		cancel_all()
	elif _permission != "granted" and _permission != "provisional":
		request_permission()
