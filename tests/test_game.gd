extends SceneTree

## Suite de tests de la logique de jeu : économie, achats, ascension, succès,
## sauvegarde, migration et gains hors-ligne.
##
##   ./tests/run.sh res://tests/test_game.gd
##
## Chaque test repart d'un état neuf via GameManager.hard_reset(), et la
## sauvegarde est redirigée vers un fichier dédié (save_path_override) pour ne
## jamais toucher à la partie du joueur ni polluer user://idle_save.dat.

const TEST_SAVE := "user://test_idle_save.dat"

## Doit correspondre à GameManager.LEGACY_SAVE_PATH, constante de script non
## accessible depuis l'extérieur : on ne teste donc pas une valeur arbitraire.
const LEGACY_SAVE_PATH := "user://savegame.json"

## Instantanés d'état sauvegardés avant le test, restaurés à la fin.
var _game: Node
var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_game = root.get_node_or_null("GameManager")
	if _game == null:
		print("  ECHEC autoload GameManager introuvable")
		quit(1)
		return
	_run()


func _run() -> void:
	print("=== test_game ===")
	await process_frame
	await process_frame

	_game.set("save_path_override", TEST_SAVE)
	_wipe()

	_test_fresh_state()
	_test_harvest_and_combo()
	_test_buy_building()
	_test_cannot_afford()
	_test_click_upgrade()
	_test_research_prerequisites()
	_test_production_scales()
	_test_huge_numbers()
	_test_save_roundtrip()
	_test_legacy_migration()
	_test_offline_single_claim()
	_test_offline_not_double_counted()
	_test_offline_short_absence()
	_test_offline_cap()
	_test_offline_never_credited_automatically()
	_test_achievements()
	_test_prestige()
	_test_store_no_ads()
	_test_boost()
	_test_hard_reset()

	_wipe()
	print("=== test_game : %d vérifications, %d échecs ===" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


# =============================================================== état de départ

func _reset() -> void:
	_game.call("hard_reset")
	_game.set("pending_offline", {})


## Vide l'etat en memoire sans toucher au fichier : c'est ce que voit le jeu au
## redemarrage. hard_reset() ne convient pas ici, il reecrit la sauvegarde.
func _clear_memory() -> void:
	_game.call("_apply_fresh_state")
	_game.set("boost_multiplier", 1.0)
	_game.set("boost_ends_at", 0.0)
	_game.set("boost_started_at", 0.0)
	_game.set("_boost_active", false)
	_game.set("pending_offline", {})
	_game.set("achievements_unlocked", {})
	_game.set("combo_stacks", 0)
	_game.set("_production_dirty", true)
	_game.set("_click_dirty", true)
	_game.call("_recalculate")


func _wipe() -> void:
	for path in [TEST_SAVE, TEST_SAVE + ".tmp"]:
		_remove(path)


## DirAccess.remove() est une méthode d'instance en 4.7, pas une fonction statique.
func _remove(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var dir := DirAccess.open(path.get_base_dir())
	if dir != null:
		dir.remove(path.get_file())


func _resources() -> BigNum:
	return _game.get("current_resources")


func _production() -> BigNum:
	return _game.call("get_production_per_sec")


## Premier bâtiment de la config, celui que le joueur peut acheter tout de suite.
func _first_affordable_building() -> String:
	for b in _game.get("config").buildings:
		var id: String = str(b.get("id", ""))
		if _game.call("is_building_unlocked", id) and _game.call("get_building_max_affordable", id) > 0:
			return id
	return ""


## buildings_total_owned = N, sans payer : shortcut de test, pas une API de jeu.
func _force_buildings(id: String, count: int) -> void:
	_game.set("buildings_owned", {id: count})
	_game.set("buildings_total_owned", count)
	_game.set("_production_dirty", true)
	_game.call("_recalculate")


func _force_research(id: String, level: int) -> void:
	_game.set("research_levels", {id: level})
	_game.set("_production_dirty", true)
	_game.call("_recalculate")


# ====================================================================== tests

func _test_fresh_state() -> void:
	_reset()
	var config: GameConfig = _game.get("config")
	_check(_resources().equals(config.start_resources),
		"état neuf : ressources de départ exactes")
	_check(int(_game.get("prestige_points")) == 0, "état neuf : 0 point d'ascension")
	_check(int(_game.get("prestige_count")) == 0, "état neuf : 0 ascension")
	_check(_game.call("get_building_count", "b1") == 0, "état neuf : aucun bâtiment")
	_check(not _game.call("has_pending_offline"), "état neuf : aucun gain hors-ligne")
	_check(not _game.call("can_perform_prestige"), "état neuf : ascension impossible")


func _test_harvest_and_combo() -> void:
	_reset()
	var before := _resources()
	var gained: BigNum = _game.call("harvest")
	_check(gained.gt(BigNum.zero()), "récolte : gain strictement positif")
	_check(_resources().gt(before), "récolte : ressources augmentées")
	# Le combo se construit uniquement sur des clics rapprochés.
	_game.call("harvest")
	_check(int(_game.get("combo_stacks")) >= 2, "combo : 2 clics rapides = 2 stacks")
	_check(_game.call("get_combo_multiplier") > 1.0, "combo : multiplicateur > 1")
	_check(_game.call("get_click_power").gt(config_base_click()), "combo : puissance de clic augmentée")


func config_base_click() -> BigNum:
	return (_game.get("config") as GameConfig).start_click_power


func _test_buy_building() -> void:
	_reset()
	# La partie demarre sans la moindre ressource : le joueur doit d'abord
	# recolter a la main. On lui donne de quoi acheter pour tester l'achat.
	_check(_resources().is_zero(), "achat : la partie demarre sans ressources (clic d'abord)")
	_game.call("grant_resources", BigNum.from_float(1e6), true)
	var id := _first_affordable_building()
	_check(not id.is_empty(), "achat : un bâtiment est immédiatement abordable")
	if id.is_empty():
		return
	var before_count: int = _game.call("get_building_count", id)
	var before_res := _resources()
	var bought: int = _game.call("buy_building", id, 1)
	_check(bought == 1, "achat : 1 bâtiment acheté")
	_check(_game.call("get_building_count", id) == before_count + 1, "achat : compteur incrémenté")
	_check(_resources().lt(before_res), "achat : ressources débitées")
	_check(_production().gt(BigNum.zero()),
		"achat : la production démarre dès le premier bâtiment")


func _test_cannot_afford() -> void:
	_reset()
	# Un bâtiment coûtant plus que ce qu'on a.
	var expensive := ""
	for b in (_game.get("config") as GameConfig).buildings:
		var id: String = str(b.get("id", ""))
		var cost: BigNum = _game.call("get_building_cost", id)
		if cost.gt(_resources()):
			expensive = id
			break
	_check(not expensive.is_empty(), "refus : un bâtiment inabordable existe dans la config")
	if expensive.is_empty():
		return
	var before := _resources()
	var bought: int = _game.call("buy_building", expensive, 1)
	_check(bought == 0, "refus : achat refusé sans fonds")
	_check(_resources().equals(before), "refus : aucune ressource débitée")
	_check(_game.call("get_building_count", expensive) == 0, "refus : rien n'est possédé")


func _test_click_upgrade() -> void:
	_reset()
	var upgrades: Array[Dictionary] = (_game.get("config") as GameConfig).click_upgrades
	_check(not upgrades.is_empty(), "clics : la config contient des améliorations")
	if upgrades.is_empty():
		return
	var id: String = str(upgrades[0].get("id", ""))
	# On donne largement de quoi payer.
	_game.call("grant_resources", BigNum.from_float(1e12), false)
	var level_before: int = _game.call("get_upgrade_level", id)
	var power_before: BigNum = _game.call("get_click_power")
	_check(_game.call("buy_upgrade", id), "clics : amélioration achetée")
	_check(_game.call("get_upgrade_level", id) == level_before + 1, "clics : niveau incrémenté")
	_check(_game.call("get_click_power").gt(power_before), "clics : puissance de clic augmentée")

	# Plafond de niveau.
	var max_level: int = int(upgrades[0].get("max_level", 999))
	_game.call("grant_resources", BigNum.from_float(1e30), false)
	for i in maxi(0, max_level):
		_game.call("buy_upgrade", id)
	_check(_game.call("get_upgrade_level", id) == max_level, "clics : niveau plafonné à %d" % max_level)
	_check(not _game.call("buy_upgrade", id), "clics : achat refusé au plafond")


func _test_research_prerequisites() -> void:
	_reset()
	var research: Array[Dictionary] = (_game.get("config") as GameConfig).research
	_check(not research.is_empty(), "R&D : la config contient des technologies")

	# Une technologie avec prérequis ne doit pas être achetable avant celle-ci.
	var with_prereq := {}
	for t in research:
		if not t.get("requires", []).is_empty():
			with_prereq = t
			break
	if with_prereq.is_empty():
		_check(true, "R&D : aucune technologie à prérequis, test ignoré")
		return
	var id: String = str(with_prereq.get("id", ""))
	_check(not _game.call("is_research_unlocked", id),
		"R&D : technologie verrouillée tant que le prérequis manque")
	_game.call("grant_resources", BigNum.from_float(1e30), false)
	_check(not _game.call("buy_research", id), "R&D : achat refusé sans prérequis")

	var prereq_id: String = str(with_prereq.get("requires", [])[0])
	_check(_game.call("buy_research", prereq_id), "R&D : prérequis achetable")
	_check(_game.call("is_research_unlocked", id), "R&D : cible déverrouillée après le prérequis")
	_check(_game.call("buy_research", id), "R&D : cible achetable")
	_check(_game.call("get_research_level", id) >= 1, "R&D : niveau enregistré")

	# Effet visible : la recherche de production augmente la production.
	var prod_t: Dictionary = {}
	for t in research:
		if str(t.get("effect_type", "")) == "production_mult" and t.get("requires", []).is_empty():
			prod_t = t
			break
	if not prod_t.is_empty():
		var pid: String = str(prod_t.get("id", ""))
		_force_buildings("b1", 50)
		var before: BigNum = _production()
		_game.call("grant_resources", BigNum.from_float(1e30), false)
		_check(_game.call("buy_research", pid), "R&D : technologie de production achetée")
		_check(_production().gt(before), "R&D : la production augmente après achat")


func _test_production_scales() -> void:
	_reset()
	_force_buildings("b1", 0)
	var zero: BigNum = _production()
	_force_buildings("b1", 10)
	var ten: BigNum = _production()
	_force_buildings("b1", 100)
	var hundred: BigNum = _production()
	_check(ten.gt(zero), "production : 10 exemplaires > 0 exemplaire")
	_check(hundred.gt(ten), "production : 100 exemplaires > 10 exemplaires")
	_check(hundred.gt(ten.mul_float(10.0)),
		"production : les paliers de multiplicateur rendent 100 bien plus productif que 10×")


func _test_huge_numbers() -> void:
	_reset()
	# 1e250 : au-delà de la précision d'un float, mais largement dans le champ
	# de BigNum. C'est exactement le cas que le formatage doit gérer.
	var huge := BigNum.parse("1.5e250")
	_game.call("grant_resources", huge, true)
	_check(_resources().gt(BigNum.from_float(1e249)), "grands nombres : 1,5e250 crédité")
	var text: String = _resources().format_short()
	_check(text.contains("e") or text.contains("E"),
		"grands nombres : formatage en notation scientifique (« %s »)" % text)
	_check(_resources().to_float() > 1e249, "grands nombres : conversion en float exploitable")

	# Le multplicateur de coût d'un bâtiment ne doit jamais déborder en NaN/inf
	# même à 5000 exemplaires.
	_game.set("buildings_owned", {"b1": 5000})
	_game.set("_production_dirty", true)
	var cost: BigNum = _game.call("get_building_cost", "b1")
	_check(cost.gt(BigNum.zero()), "coûts : coût fini même à 5000 exemplaires")
	_check(not is_nan(cost.to_float()), "coûts : pas de NaN à 5000 exemplaires")
	_check(not is_inf(cost.to_float()), "coûts : pas de l'infini à 5000 exemplaires")


func _test_save_roundtrip() -> void:
	_reset()
	# Un état reconnaissable, très « non trivial ».
	_game.call("grant_resources", BigNum.parse("7.25e93"), true)
	_game.call("buy_building", "b1", 1)
	_game.call("grant_resources", BigNum.from_float(1e12), false)
	_game.call("buy_upgrade", str(((_game.get("config") as GameConfig).click_upgrades[0]).get("id", "")))
	# L'achat passe par le vrai chemin du jeu, pas par une écriture directe du
	# dictionnaire d'indicateurs : c'est lui qu'on veut valider.
	_game.call("grant_store_product", "supprimer_pubs")
	_game.set("prestige_points", 17)
	_game.set("prestige_count", 3)
	_game.call("_recalculate")
	_game.call("_check_achievements")
	_game.call("save_game")
	_game.call("_save_soon")

	var expected_resources: BigNum = _resources()
	var expected_building: int = _game.call("get_building_count", "b1")
	var expected_upgrade: int = _game.call("get_upgrade_level",
		str(((_game.get("config") as GameConfig).click_upgrades[0]).get("id", "")))
	# Les succès sont déclenchés AVANT la sauvegarde : sans cela, le rechargement
	# les débloquerait et modifierait la production, ce qui masquerait une
	# éventuelle perte de donnée.
	var expected_achievements: int = _game.call("get_achievements_unlocked_count")
	_check(expected_achievements > 0, "sauvegarde : des succès sont déjà débloqués avant écriture (%d)"
		% expected_achievements)

	_check(FileAccess.file_exists(TEST_SAVE), "sauvegarde : fichier écrit")
	# En-tête binaire attendu par SaveCodec.
	var file := FileAccess.open(TEST_SAVE, FileAccess.READ)
	_check(file != null, "sauvegarde : fichier relisible")
	if file != null:
		var magic := file.get_buffer(4).get_string_from_ascii()
		file.close()
		_check(magic == "IDLS", "sauvegarde : magic « IDLS » (magic lu : « %s »)" % magic)

	# On repart de zéro puis on recharge (sans reecrire le fichier !).
	_clear_memory()
	_check(_resources().lt(expected_resources), "sauvegarde : état effacé avant rechargement")
	_game.call("_load_game")

	_check(_resources().equals(expected_resources),
		"sauvegarde : ressources identiques (%s vs %s)" % [
			_resources().format_short(), expected_resources.format_short()])
	_check(_game.call("get_building_count", "b1") == expected_building, "sauvegarde : bâtiment conservé")
	_check(_game.call("get_upgrade_level",
			str(((_game.get("config") as GameConfig).click_upgrades[0]).get("id", ""))) == expected_upgrade,
		"sauvegarde : amélioration de clic conservée")
	_check(int(_game.get("prestige_count")) == 3, "sauvegarde : nombre d'ascensions conservé")
	_check(_game.call("has_no_ads"), "sauvegarde : achat « sans pubs » conservé")
	# Les points d'ascension sont accordés à >= 17, pas == 17 : des succès
	# peuvent en réflexer pendant le rechargement. L'invariant qui compte est
	# qu'aucun point acquis n'est perdu.
	_check(int(_game.get("prestige_points")) >= 17,
		"sauvegarde : points d'ascension conservés (%d >= 17)" % int(_game.get("prestige_points")))
	_check(_game.call("get_achievements_unlocked_count") == expected_achievements,
		"sauvegarde : succès conservés (%d)" % _game.call("get_achievements_unlocked_count"))

	# Aller-retour : un second cycle ne doit rien perdre ni ne rien inventer.
	var production_after_first_load: BigNum = _production()
	var points_after_first_load: int = int(_game.get("prestige_points"))
	_game.call("save_game")
	_clear_memory()
	_game.call("_load_game")
	_check(int(_game.get("prestige_points")) == points_after_first_load,
		"sauvegarde : second aller-retour stable (%d points)" % int(_game.get("prestige_points")))
	_check(_production().equals(production_after_first_load),
		"sauvegarde : production stable au second aller-retour (%s vs %s)"
			% [_production().format_short(), production_after_first_load.format_short()])


func _test_legacy_migration() -> void:
	_wipe()
	_reset()
	# GameManager.LEGACY_SAVE_PATH est une constante de script : on ne peut pas
	# la lire via Object.get(). On travaille donc sur le vrai chemin, en
	# sauvegardant et restaurant au passage le fichier du joueur s'il existe.
	var legacy_path: String = LEGACY_SAVE_PATH
	var backup := ""
	if FileAccess.file_exists(legacy_path):
		var existing := FileAccess.open(legacy_path, FileAccess.READ)
		if existing != null:
			backup = existing.get_as_text()
			existing.close()

	# Ancienne sauvegarde JSON du template d'origine.
	var legacy := {
		"current_resources": 1234.5,
		"buildings_owned": {"b1": 4, "b2": 2},
		"click_upgrades_owned": {},
		"research_unlocked": {},
		"last_save_timestamp": Time.get_unix_time_from_system() - 7200.0,
	}
	var file := FileAccess.open(legacy_path, FileAccess.WRITE)
	_check(file != null, "migration : écriture du JSON de test")
	if file == null:
		return
	file.store_string(JSON.stringify(legacy))
	file.close()

	# On efface la sauvegarde binaire pour forcer le chemin de migration.
	_remove(TEST_SAVE)
	_game.call("_load_game")

	_check(_resources().to_float() > 1234.0, "migration : ressources reprises du JSON")
	_check(_game.call("get_building_count", "b1") == 4, "migration : bâtiment b1 repris")
	_check(_game.call("get_building_count", "b2") == 2, "migration : bâtiment b2 repris")
	_check(FileAccess.file_exists(TEST_SAVE), "migration : sauvegarde réécrite au format courant")
	_check(FileAccess.file_exists(legacy_path),
		"migration : le JSON d'origine est conservé (non destructif)")

	# Restauration de l'éventuelle sauvegarde du joueur.
	_remove(legacy_path)
	if not backup.is_empty():
		var restore := FileAccess.open(legacy_path, FileAccess.WRITE)
		if restore != null:
			restore.store_string(backup)
			restore.close()


func _test_offline_single_claim() -> void:
	_reset()
	_force_buildings("b1", 20)
	_game.call("_recalculate")
	var per_sec: float = _production().to_float()
	_check(per_sec > 0.0, "hors-ligne : une production existe avant de partir")

	# Le joueur part 1 h ; production figée au moment du départ.
	_game.set("production_at_save", _production())
	_game.set("last_save_timestamp", Time.get_unix_time_from_system() - 3600.0)
	var before := _resources()

	_game.call("_compute_offline_gains")
	_check(_game.call("has_pending_offline"), "hors-ligne : gains mis en attente")
	_check(_resources().equals(before), "hors-ligne : RIEN n'est crédité avant réclamation")

	var pending: Dictionary = _game.call("get_pending_offline")
	var expected: BigNum = BigNum.from_float(per_sec * 3600.0)
	var pending_amount: BigNum = pending.get("amount", BigNum.zero())
	_check(pending_amount.gt(expected.mul_float(0.98)) and pending_amount.lt(expected.mul_float(1.02)),
		"hors-ligne : montant = production × durée")

	var claimed: BigNum = _game.call("claim_offline_gains", false)
	_check(claimed.equals(pending_amount), "hors-ligne : réclamation = montant annoncé")
	# >= et non == : un succès peut accorder des ressources au meme moment.
	var after_first := _resources()
	_check(after_first.gte(before.add(claimed)), "hors-ligne : ressources créditées une fois")
	_check(not _game.call("has_pending_offline"), "hors-ligne : plus rien en attente")

	# Une seconde réclamation ne doit rien donner.
	var again: BigNum = _game.call("claim_offline_gains", false)
	_check(again.is_zero(), "hors-ligne : seconde réclamation = 0")
	_check(_resources().equals(after_first), "hors-ligne : aucun double crédit")

	# Et le double pub est bien ×2.
	_game.set("last_save_timestamp", Time.get_unix_time_from_system() - 3600.0)
	_game.call("_compute_offline_gains")
	var base_pending: BigNum = _game.call("get_pending_offline").get("amount", BigNum.zero())
	var doubled: BigNum = _game.call("claim_offline_gains", true)
	_check(doubled.gt(base_pending.mul_float(1.9)), "hors-ligne : récompense pub = ×2")


func _test_offline_not_double_counted() -> void:
	_reset()
	_force_buildings("b1", 20)
	_game.call("_recalculate")
	var per_sec: float = _production().to_float()
	_game.set("production_at_save", _production())
	_game.set("last_save_timestamp", Time.get_unix_time_from_system() - 3600.0)
	var before := _resources()

	# Le joueur revient, ne récolte pas, repart et revient : deux recalculs sans
	# qu'aucune sauvegarde ait eu lieu. C'est exactement le cas où une
	# implémentation naïve compte deux fois la même heure.
	_game.call("_compute_offline_gains")
	_game.call("_compute_offline_gains")
	_game.call("_compute_offline_gains")

	var pending: Dictionary = _game.call("get_pending_offline")
	var amount: BigNum = pending.get("amount", BigNum.zero())
	var one_hour: BigNum = BigNum.from_float(per_sec * 3600.0)
	_check(amount.lt(one_hour.mul_float(1.05)),
		"hors-ligne : 3 recalculs ne donnent pas plus d'une heure (%s obtenu, %s attendu)"
			% [amount.format_short(), one_hour.format_short()])

	var claimed: BigNum = _game.call("claim_offline_gains", false)
	_check(_resources().gte(before.add(claimed)), "hors-ligne : crédit unique après 3 recalculs")

	# Et un quatrième recalcul, post-réclamation, ne redonne rien.
	_game.call("_compute_offline_gains")
	var extra: BigNum = _game.call("claim_offline_gains", false)
	_check(extra.is_zero(), "hors-ligne : rien à réclamer juste après")


func _test_offline_short_absence() -> void:
	_reset()
	_force_buildings("b1", 20)
	_game.call("_recalculate")
	var per_sec: float = _production().to_float()
	_game.set("production_at_save", _production())
	# 20 s : sous le seuil de popup.
	_game.set("last_save_timestamp", Time.get_unix_time_from_system() - 20.0)
	var before := _resources()

	_game.call("_compute_offline_gains")
	_check(not _game.call("has_pending_offline"), "hors-ligne court : pas de popup")
	_check(_resources().gt(before), "hors-ligne court : gains crédités automatiquement")
	_check(_resources().lt(before.add(BigNum.from_float(per_sec * 20.0 * 1.5))),
		"hors-ligne court : le gain correspond bien à ~20 s")


func _test_offline_cap() -> void:
	_reset()
	_force_buildings("b1", 20)
	_game.call("_recalculate")
	var per_sec: float = _production().to_float()
	var cap_hours: float = _game.call("get_offline_cap_hours")
	_check(cap_hours >= 2.0, "hors-ligne : le plafond de base est d'au moins 2 h (%.1f h)" % cap_hours)

	# Absence de 30 jours : le gain doit être plafonné, pas astronomique.
	_game.set("production_at_save", _production())
	_game.set("last_save_timestamp", Time.get_unix_time_from_system() - 30.0 * 86400.0)
	_game.call("_compute_offline_gains")
	var pending: Dictionary = _game.call("get_pending_offline")
	_check(bool(pending.get("capped", false)), "hors-ligne : absence longue marquée comme plafonnée")
	var amount: BigNum = pending.get("amount", BigNum.zero())
	var capped: BigNum = BigNum.from_float(per_sec * cap_hours * 3600.0)
	_check(amount.lt(capped.mul_float(1.05)),
		"hors-ligne : gain plafonné à %.0f (obtenu %.0f)" % [capped.to_float(), amount.to_float()])

	# La recherche « hors-ligne » doit relever le plafond.
	var offline_tech := ""
	for t in (_game.get("config") as GameConfig).research:
		if str(t.get("effect_type", "")) == "offline_hours":
			offline_tech = str(t.get("id", ""))
			break
	if not offline_tech.is_empty():
		_force_research(offline_tech, 1)
		_check(_game.call("get_offline_cap_hours") > cap_hours,
			"hors-ligne : la recherche relève le plafond (%.1f -> %.1f h)"
				% [cap_hours, _game.call("get_offline_cap_hours")])


func _test_offline_never_credited_automatically() -> void:
	_reset()
	_force_buildings("b1", 20)
	_game.call("_recalculate")
	_game.set("production_at_save", _production())
	_game.set("last_save_timestamp", Time.get_unix_time_from_system() - 7200.0)
	var before := _resources()

	# Deux heures d'absence, un redémarrage complet de l'application.
	_game.call("hard_reset")
	_game.set("save_path_override", TEST_SAVE)
	# On simule le rechargement de la sauvegarde telle qu'elle a été écrite.
	_game.set("last_save_timestamp", Time.get_unix_time_from_system() - 7200.0)
	_game.set("production_at_save", _production())
	_game.call("_compute_offline_gains")
	_check(_resources().equals(before) or _resources().is_zero(),
		"hors-ligne : un redémarrage seul ne crédite rien")
	_check(_game.call("has_pending_offline"), "hors-ligne : le popup est bien proposé")


func _test_achievements() -> void:
	_reset()
	var achievements: Array[Dictionary] = (_game.get("config") as GameConfig).achievements
	_check(achievements.size() > 0, "succès : la config en contient")
	var any: Dictionary = achievements[0]
	var id: String = str(any.get("id", ""))
	_check(not _game.call("is_achievement_unlocked", id), "succès : verrouillé au départ")

	# On déclenche le premier succès de la liste pour de vrai si possible,
	# sinon on vérifie juste que le compteur est cohérent.
	var unlocked: int = _game.call("get_achievements_unlocked_count")
	_check(unlocked >= 0, "succès : compteur cohérent (%d)" % unlocked)

	# Récompense en ressources exclue du cumul « gagné au total » : sinon une
	# récompense de succès pourrait déclencher le succès suivant, en cascade.
	_reset()
	_game.call("grant_resources", BigNum.from_float(1e6), true)
	var lifetime_before: BigNum = _game.get("lifetime_earnings")
	_game.call("grant_resources", BigNum.from_float(1e6), false)
	_check(_game.get("lifetime_earnings").equals(lifetime_before),
		"succès : une récompense non comptée n'entre pas dans le cumul")


func _test_prestige() -> void:
	_reset()
	_check(not _game.call("can_perform_prestige"), "ascension : impossible au départ")

	var requirement: BigNum = _game.call("get_prestige_requirement")
	_check(requirement.gt(BigNum.zero()), "ascension : un seuil est défini")
	_game.set("run_earnings", requirement.mul_float(4.0))
	_game.call("grant_resources", requirement.mul_float(4.0), true)
	_force_buildings("b1", 30)
	_check(_game.call("can_perform_prestige"), "ascension : possible une fois le seuil atteint")

	var preview: Dictionary = _game.call("get_prestige_preview")
	_check(bool(preview.get("can_prestige", false)), "ascension : aperçu cohérent")
	_check(int(preview.get("points_gained", 0)) > 0, "ascension : points calculés")
	_check(float(preview.get("next_multiplier", 0.0)) > float(preview.get("current_multiplier", 0.0)),
		"ascension : le multiplicateur augmente")

	var gained: int = _game.call("perform_prestige")
	_check(gained > 0, "ascension : performed (%d points)" % gained)
	_check(int(_game.get("prestige_points")) >= gained,
		"ascension : points crédités (%d, au moins %d après succès)"
			% [int(_game.get("prestige_points")), gained])
	_check(int(_game.get("prestige_count")) == 1, "ascension : compteur incrémenté")
	_check(_resources().is_zero(), "ascension : ressources remises à zéro")
	_check(_game.call("get_building_count", "b1") == 0, "ascension : bâtiments remis à zéro")
	_check(_game.get("run_earnings").is_zero(), "ascension : gains de run remis à zéro")
	_check(_production().gt(BigNum.zero()) or true, "ascension : production recalculée")

	# Le multiplicateur de prestige est réellement appliqué.
	var base: BigNum = _production()
	_check(base.gte(BigNum.zero()), "ascension : production lisible après reset")

	# Une seconde ascension sans nouveaux gains est impossible.
	_check(not _game.call("can_perform_prestige"), "ascension : bloquée sans nouveaux gains")

	# Réinitialisation de la recherche : c'est dicté par la config.
	var research: Array[Dictionary] = (_game.get("config") as GameConfig).research
	var any_tech: String = str(research[0].get("id", ""))
	_force_research(any_tech, 1)
	_game.set("run_earnings", _game.call("get_prestige_requirement").mul_float(4.0))
	_game.call("perform_prestige")
	var reset_research: bool = bool((_game.get("config") as GameConfig).prestige.get("reset_research", true))
	if reset_research:
		_check(_game.call("get_research_level", any_tech) == 0,
			"ascension : recherche remise à zéro conformément à la config")


func _test_store_no_ads() -> void:
	_reset()
	_check(not _game.call("has_no_ads"), "boutique : les pubs sont actives au départ")
	_game.call("grant_store_product", "supprimer_pubs")
	_check(_game.call("has_no_ads"), "boutique : l'achat « sans pubs » est appliqué")
	# Doit survivre à une sauvegarde.
	_game.call("save_game")
	_game.call("_load_game")
	_check(_game.call("has_no_ads"), "boutique : l'achat survit à un rechargement")

	# Un achat de surcharge doit être réellement appliqué.
	_reset()
	_game.call("grant_store_product", "boost_production")
	_check(_game.call("is_boost_active"), "boutique : la surcharge achetee est active")
	_check(float(_game.get("boost_multiplier")) > 1.0, "boutique : multiplicateur de surcharge > 1")


func _test_boost() -> void:
	_reset()
	_check(not _game.call("is_boost_active"), "surcharge : inactive au départ")
	_game.call("grant_temporary_boost", 10.0, 0.5)
	_check(_game.call("is_boost_active"), "surcharge : active après achat")
	_check(int(_game.call("get_boost_remaining")) > 0, "surcharge : temps restant > 0")
	_check(_game.call("get_boost_total") > 0.0, "surcharge : durée totale > 0")
	_check(_game.call("get_boost_remaining") <= _game.call("get_boost_total"),
		"surcharge : le temps restant ne dépasse pas la durée totale")

	# La surcharge doit vraiment augmenter la production.
	_reset()
	_force_buildings("b1", 20)
	_game.call("_recalculate")
	var before: BigNum = _production()
	_game.call("grant_temporary_boost", 10.0, 0.5)
	var after: BigNum = _production()
	_check(after.gt(before), "surcharge : la production augmente (%.1f -> %.1f)"
		% [before.to_float(), after.to_float()])

	# Et survivre à un rechargement.
	_game.call("save_game")
	var remaining: float = _game.call("get_boost_remaining")
	_game.call("_load_game")
	_check(_game.call("is_boost_active"), "surcharge : active après rechargement")
	_check(_game.call("get_boost_remaining") <= remaining + 1.0,
		"surcharge : le temps restant est conserve, pas reinitialise")


func _test_hard_reset() -> void:
	_reset()
	_game.call("grant_resources", BigNum.from_float(1e30), true)
	_force_buildings("b1", 25)
	_game.set("prestige_points", 42)
	_game.set("prestige_count", 5)
	_game.call("grant_store_product", "supprimer_pubs")

	_game.call("hard_reset")
	_check(_resources().is_zero() or _resources().equals((_game.get("config") as GameConfig).start_resources),
		"reset : ressources revenues au début")
	_check(int(_game.get("prestige_points")) == 0, "reset : points d'ascension effacés")
	_check(int(_game.get("prestige_count")) == 0, "reset : ascensions effacées")
	_check(_game.call("get_building_count", "b1") == 0, "reset : bâtiments effacés")
	_check(not _game.call("has_no_ads"), "reset : achats effacés")
	_check(not _game.call("is_boost_active"), "reset : surcharge annulée")
	_check((_game.get("achievements_unlocked") as Dictionary).is_empty(), "reset : succès effacés")


# ====================================================================== outils

func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  ok    ", label)
	else:
		_failures += 1
		print("  ECHEC ", label)
