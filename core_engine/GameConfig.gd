class_name GameConfig
extends RefCounted

## Contenu du jeu, lu depuis data/game_config.json et indexé.
##
## Tout ce qui est équilibrage (noms, coûts, multiplicateurs, paliers) vit dans le
## JSON : rééquilibrer un jeu revient à éditer ce fichier, sans toucher au code.
## Cette classe se contente de normaliser et d'indexer une fois au chargement,
## pour que la boucle de jeu ne fasse plus de recherche linéaire par frame.

const DEFAULT_PATH := "res://data/game_config.json"

# --- Métadonnées
var title: String = "Idle Game"
var tagline: String = ""
var resource_name: String = "Or"
var resource_icon: String = "🪙"
var prestige_name: String = "Points"
var prestige_icon: String = "⭐"
var schema_version: int = 1

# --- Économie de base
var base_production_per_sec: BigNum = BigNum.from_float(1.0)
var start_resources: BigNum = BigNum.zero()
var start_click_power: BigNum = BigNum.from_float(1.0)
var autosave_interval: float = 20.0

# --- Listes ordonnées (tel quel) + index par id
var buildings: Array[Dictionary] = []
var buildings_by_id: Dictionary = {}
var click_upgrades: Array[Dictionary] = []
var click_upgrades_by_id: Dictionary = {}
var research: Array[Dictionary] = []
var research_by_id: Dictionary = {}
var achievements: Array[Dictionary] = []
var achievements_by_id: Dictionary = {}
var store_products: Array[Dictionary] = []
var store_products_by_id: Dictionary = {}

# --- Sections
var offline: Dictionary = {}
var combo: Dictionary = {}
var prestige: Dictionary = {}
var ads: Dictionary = {}
var store: Dictionary = {}

var load_error: String = ""


func load_from_file(path: String = DEFAULT_PATH) -> bool:
	load_error = ""
	if not FileAccess.file_exists(path):
		load_error = "Configuration introuvable : %s" % path
		push_error(load_error)
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		load_error = "Impossible d'ouvrir %s (erreur %d)" % [path, FileAccess.get_open_error()]
		push_error(load_error)
		return false
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		load_error = "JSON invalide dans %s" % path
		push_error(load_error)
		return false
	_from_dict(parsed)
	return true


func _from_dict(d: Dictionary) -> void:
	schema_version = int(d.get("schema_version", 1))
	title = str(d.get("game_title", title))
	tagline = str(d.get("tagline", ""))
	resource_name = str(d.get("resource_name", resource_name))
	resource_icon = str(d.get("resource_icon", resource_icon))
	prestige_name = str(d.get("prestige_name", prestige_name))
	prestige_icon = str(d.get("prestige_icon", prestige_icon))
	base_production_per_sec = _num(d.get("base_production_per_sec", 1.0), BigNum.from_float(1.0))
	start_resources = _num(d.get("start_resources", 0.0), BigNum.zero())
	start_click_power = _num(d.get("start_click_power", 1.0), BigNum.from_float(1.0))
	autosave_interval = maxf(1.0, float(d.get("autosave_interval", 20.0)))

	buildings = _normalize_list(d.get("buildings", []))
	buildings_by_id = _index(buildings)
	click_upgrades = _normalize_list(d.get("click_upgrades", []))
	click_upgrades_by_id = _index(click_upgrades)
	research = _normalize_list(d.get("research_techs", []))
	research_by_id = _index(research)
	achievements = _normalize_list(d.get("achievements", []))
	achievements_by_id = _index(achievements)

	offline = _section(d, "offline", {
		"base_hours": 2.0,
		"hours_per_research_level": 2.0,
		"min_popup_seconds": 60.0,
		"notify_after_hours": 2.0,
	})
	combo = _section(d, "combo", {
		"base_window": 1.2,
		"max_stacks": 25,
		"power_per_stack": 0.04,
		"window_per_research_level": 1.0,
	})
	prestige = _section(d, "prestige", {
		"min_run_earnings": 1e9,
		"exponent": 0.5,
		"divisor": 1000.0,
		"mult_per_point": 0.01,
		"reset_research": true,
		"keep_click_upgrades": false,
	})
	ads = _section(d, "ads", {
		"enabled": true,
		"mock": true,
		"duration_seconds": 5.0,
		"daily_cap_production_boost": 3,
		"daily_cap_offline_double": 1,
	})
	store = _section(d, "store", {"mock": true})
	store_products = _normalize_list(store.get("products", []))
	store_products_by_id = _index(store_products)


# ------------------------------------------------------------------ accès indexé

func building(id: String) -> Dictionary:
	return buildings_by_id.get(id, {})


func click_upgrade(id: String) -> Dictionary:
	return click_upgrades_by_id.get(id, {})


func research_tech(id: String) -> Dictionary:
	return research_by_id.get(id, {})


func achievement(id: String) -> Dictionary:
	return achievements_by_id.get(id, {})


func store_product(id: String) -> Dictionary:
	return store_products_by_id.get(id, {})


func research_by_category(category: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for t in research:
		if str(t.get("category", "")) == category:
			out.append(t)
	return out


# ----------------------------------------------------------------------- helpers

static func _num(value: Variant, fallback: BigNum) -> BigNum:
	match typeof(value):
		TYPE_FLOAT, TYPE_INT:
			return BigNum.from_float(float(value))
		TYPE_STRING:
			var parsed := BigNum.parse(str(value))
			return fallback if parsed.is_zero() and str(value).strip_edges() != "0" else parsed
		TYPE_ARRAY:
			return BigNum.deserialize(value)
	return fallback.copy()


static func _section(d: Dictionary, key: String, defaults: Dictionary) -> Dictionary:
	var out := defaults.duplicate(true)
	var raw: Variant = d.get(key, {})
	if typeof(raw) == TYPE_DICTIONARY:
		for k in (raw as Dictionary):
			out[k] = (raw as Dictionary)[k]
	return out


## Copie chaque entrée dans un Dictionary typé, en ignorant les entrées non-dict.
## Les valeurs par défaut restent gérées par le code appelant (accès par .get).
static func _normalize_list(raw: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for entry in (raw as Array):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = (entry as Dictionary).duplicate(true)
		out.append(e)
	return out


static func _index(list: Array[Dictionary]) -> Dictionary:
	var out := {}
	for e in list:
		var id := str(e.get("id", ""))
		if not id.is_empty():
			out[id] = e
	return out
