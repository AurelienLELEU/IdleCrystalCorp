extends ColorRect
## Fond animé de l'écran principal.
##
## `purchase_progress` fait apparaître progressivement des facettes cristallines
## à mesure que le joueur achète bâtiments, améliorations et recherches. Le
## `research_progress` teinte la lumière vers le cyan à mesure que la R&D avance.
## Le shader anime les halos en continu; ce script ne recalcule les paramètres
## qu'à l'achat, à l'ascension, à la remise à zéro et au chargement.

const PURCHASE_SATURATION := 60.0
const RESEARCH_SATURATION := 12.0

var _shader_material: ShaderMaterial


func _ready() -> void:
	_shader_material = material as ShaderMaterial
	if _shader_material == null:
		push_error("CrystalBackground : ShaderMaterial absent de Main.tscn.")
		return

	GameManager.building_purchased.connect(_on_purchase_changed)
	GameManager.upgrade_purchased.connect(_on_purchase_changed)
	GameManager.research_purchased.connect(_on_purchase_changed)
	GameManager.prestige_performed.connect(_on_prestige_performed)
	GameManager.game_reset.connect(_on_game_reset)
	_refresh_progress()


func _on_purchase_changed(_id: String, _level_or_count: int, _cost: BigNum) -> void:
	_refresh_progress()


func _on_prestige_performed(_gained: int, _total: int) -> void:
	_refresh_progress()


func _on_game_reset() -> void:
	_refresh_progress()


func _refresh_progress() -> void:
	if _shader_material == null or not is_instance_valid(_shader_material):
		return

	var purchases := int(GameManager.buildings_total_owned)
	for count: Variant in GameManager.click_upgrades_owned.values():
		purchases += int(count)
	for level: Variant in GameManager.research_levels.values():
		purchases += int(level)
	# Une ascension garde la lumière acquise au lieu de faire « régresser » le
	# décor quand les bâtiments et améliorations du run sont remis à zéro.
	purchases += int(GameManager.prestige_count) * 12

	var purchase_progress := clampf(
		log(1.0 + float(purchases)) / log(1.0 + PURCHASE_SATURATION), 0.0, 1.0)
	var research_progress := clampf(
		float(GameManager.research_levels_total) / RESEARCH_SATURATION, 0.0, 1.0)
	_shader_material.set_shader_parameter("purchase_progress", purchase_progress)
	_shader_material.set_shader_parameter("research_progress", research_progress)
