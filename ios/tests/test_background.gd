extends SceneTree
## Fond animé de l'écran principal : animation shader et évolution selon les
## achats de jeu.
##
##   ./tests/run.sh res://tests/test_background.gd 180

const TEST_SAVE := "user://test_background_save.dat"
const MAIN_SCENE := "res://scenes/Main.tscn"

var _checks := 0
var _failures := 0


func _initialize() -> void:
	print("=== test_background ===")
	await _run()
	print("=== test_background : %d vérifications, %d échecs ===" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _run() -> void:
	await process_frame
	var game: Variant = root.get_node_or_null("GameManager")
	_check(game != null, "GameManager autoload présent")
	if game == null:
		return

	game.set("save_path_override", TEST_SAVE)
	game.call("hard_reset")
	await process_frame

	var packed := load(MAIN_SCENE) as PackedScene
	_check(packed != null, "Main.tscn chargeable")
	if packed == null:
		return
	var main := packed.instantiate() as Control
	root.add_child(main)
	await process_frame
	await process_frame

	var background := main.get_node_or_null("Background") as ColorRect
	_check(background != null, "le fond est un ColorRect réel de Main.tscn")
	if background == null:
		return
	_check(background.size.x > 0.0 and background.size.y > 0.0,
		"le fond animé couvre la fenêtre (%s)" % str(background.size))

	var shader_material := background.material as ShaderMaterial
	_check(shader_material != null, "le fond utilise un ShaderMaterial")
	if shader_material == null or shader_material.shader == null:
		return
	var strata_texture := load("res://assets/crystal_strata.png") as Texture2D
	_check(strata_texture != null and strata_texture.get_width() >= 128,
		"texture tileable de strates cristallines chargée depuis assets")
	var bound_texture := shader_material.get_shader_parameter("grain_texture") as Texture2D
	_check(bound_texture != null and bound_texture.get_size() == strata_texture.get_size(),
		"le ShaderMaterial utilise réellement la texture de strates")
	_check(shader_material.shader.code.contains("texture(grain_texture"),
		"le shader échantillonne la texture; le PNG n'est pas un asset mort")
	_check(shader_material.shader.code.contains("TIME"),
		"le shader dépend du temps : ce n'est pas une image statique")

	var initial_purchase := float(shader_material.get_shader_parameter("purchase_progress"))
	var initial_research := float(shader_material.get_shader_parameter("research_progress"))
	_check(is_zero_approx(initial_purchase),
		"partie neuve : le niveau visuel des achats commence à zéro (%.3f)" % initial_purchase)
	_check(is_zero_approx(initial_research),
		"partie neuve : le niveau visuel de recherche commence à zéro (%.3f)" % initial_research)

	game.call("grant_resources", BigNum.from_float(1e30), false)
	var building_result: int = int(game.call("buy_building", "b1", 1))
	await process_frame
	var after_building := float(shader_material.get_shader_parameter("purchase_progress"))
	_check(building_result == 1 and after_building > initial_purchase,
		"acheter un bâtiment augmente la progression visuelle (%.3f -> %.3f)"
			% [initial_purchase, after_building])

	var upgrade_result: bool = bool(game.call("buy_upgrade", "c1"))
	await process_frame
	var after_upgrade := float(shader_material.get_shader_parameter("purchase_progress"))
	_check(upgrade_result and after_upgrade > after_building,
		"acheter une amélioration augmente encore la progression visuelle (%.3f -> %.3f)"
			% [after_building, after_upgrade])

	var research_result: bool = bool(game.call("buy_research", "r1"))
	await process_frame
	var after_research := float(shader_material.get_shader_parameter("research_progress"))
	_check(research_result and after_research > initial_research,
		"acheter une recherche fait évoluer la teinte visuelle (%.3f -> %.3f)"
			% [initial_research, after_research])

	game.call("hard_reset")
	await process_frame
	var after_reset_purchase := float(shader_material.get_shader_parameter("purchase_progress"))
	var after_reset_research := float(shader_material.get_shader_parameter("research_progress"))
	_check(is_zero_approx(after_reset_purchase) and is_zero_approx(after_reset_research),
		"une remise à zéro réinitialise aussi la progression visuelle "
		+ "(achats %.3f, recherches %.3f)" % [after_reset_purchase, after_reset_research])

	main.queue_free()
	await process_frame
	game.set("save_path_override", "")
	_remove_test_save()


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  ok    %s" % label)
	else:
		_failures += 1
		print("  ECHEC %s" % label)


func _remove_test_save() -> void:
	var absolute := ProjectSettings.globalize_path(TEST_SAVE)
	if FileAccess.file_exists(TEST_SAVE):
		DirAccess.remove_absolute(absolute)
	if FileAccess.file_exists(TEST_SAVE + ".tmp"):
		DirAccess.remove_absolute(absolute + ".tmp")
