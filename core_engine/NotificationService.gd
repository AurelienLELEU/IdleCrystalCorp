extends Node

## Autoload : Notifications
##
## Programation de notifications locales (« vos gains vous attendent »).
##
## IMPORTANT — Godot 4.7 n'expose aucune API de notification locale dans son core :
## sur iOS il faut un plugin natif. Cette classe est donc la couche d'abstraction
## qui appelle le plugin s'il est présent, et se dégrade proprement sinon.
##
## Plugin attendu (GDExtension ou plugin iOS) exposant une classe
## "IdleNotifications" avec ces méthodes :
##
##   request_permission() -> void          # émet permission_changed(bool)
##   schedule(id: String, title: String, body: String, delay_seconds: float) -> bool
##   cancel(id: String) -> void
##   cancel_all() -> void
##
## Sans plugin, le jeu fonctionne quand même : la popup de retour hors-ligne et
## le bandeau in-game font le même travail, et `is_supported()` vaut false.
## Voir README.md § « Notifications locales » pour un exemple Swift.

signal permission_changed(state: String)
signal reminder_scheduled(delay_seconds: float)
signal reminder_failed(reason: String)

const PLUGIN_CLASS := "IdleNotifications"
const REMINDER_ID := "idle_reminder"

var enabled: bool = true
var _permission: String = "unknown"
var _plugin: Object = null
## Rappel demandé mais non programmable : l'interface peut l'afficher au retour.
var _pending_delay: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_plugin()


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
	_permission = "granted"


func is_supported() -> bool:
	return _plugin != null


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
		_plugin.call("request_permission")
	else:
		_permission = "granted"


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
	var ok: bool = false
	if _plugin.has_method("schedule"):
		ok = _plugin.call(
			"schedule",
			REMINDER_ID,
			str(payload.get("title", "Revenez jouer")),
			str(payload.get("body", "")),
			_pending_delay
		)
	if ok:
		reminder_scheduled.emit(_pending_delay)
	else:
		reminder_failed.emit("le plugin a refusé la programmation")
	return ok


func cancel_all() -> void:
	_pending_delay = 0.0
	if _plugin != null and _plugin.has_method("cancel_all"):
		_plugin.call("cancel_all")


func set_enabled(value: bool) -> void:
	enabled = value
	if not enabled:
		cancel_all()
