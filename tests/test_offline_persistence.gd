extends SceneTree

## Tests de ce qui se passe quand le joueur QUITTE l'application — le moment
## qu'aucun test du jeu ne simulait.
##
##   ./tests/run.sh res://tests/test_offline_persistence.gd
##
## Ces tests ont été écrits après deux défauts trouvés à la revue, tous deux
## invisibles parce que la suite existante ne testait que le cas heureux :
##
##   1. Les gains hors-ligne non réclamés ne sont pas sauvegardés. Le joueur
##      Clique « Plus tard », l'autosave écrit `last_save = maintenant`, et les
##      heures de production sont définitivement perdues. Le test vérifie le
##      voyage complet : calculer → sauvegarder → relire.
##
##   2. Le signal `offline_gains_pending` n'avait aucun récepteur. Revenir au
##      premier plan — le geste le plus courant sur mobile — calculait les gains
##      et n'affichait rien.

const TEST_SAVE := "user://test_offline_persist.dat"

var _game: Node
var _ui: Node = null
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
	print("=== test_offline_persistence ===")
	await process_frame
	await process_frame

	_game.set("save_path_override", TEST_SAVE)
	_wipe()

	_test_pending_survives_save_reload()
	_test_pending_survives_even_without_claiming()
	_test_fresh_state_clears_pending()
	_test_short_absence_counts_towards_totals()
	_test_corrupt_save_is_quarantined()
	_test_foreground_signal_has_a_receiver()
	_test_no_delete_before_rename()

	_wipe()
	print("=== test_offline_persistence : %d vérifications, %d échecs ===" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


# ================================================================== hors-ligne

## Le scénario exact du bug : des gains sont mis en attente, le joueur ne les
## réclame pas, il ferme l'app. Au redémarrage, ils doivent être là.
func _test_pending_survives_save_reload() -> void:
	_fresh()
	var amount := _make_pending(7200.0, 500.0)
	_check(_game.call("has_pending_offline"), "hors-ligne : gains en attente après calcul")

	_game.call("save_game")

	# Le point capital de ce test. Sans cet effacement en mémoire, il passe
	# MÊME SUR LE CODE BUGGUÉ : `_load_game` laissait le dictionnaire
	# `pending_offline` intact, le test relisait le même objet qu'il venait
	# d'écrire, et concluait « les gains ont survécu » alors qu'ils n'avaient
	# jamais quitté la mémoire. Vider la variable force la seule source
	# restante à être le fichier — c'est-à-dire exactement ce que verrait un
	# joueur qui a vraiment fermé l'application.
	_clear_in_memory()
	_check(not _game.call("has_pending_offline"),
		"hors-ligne : l'état en mémoire est bien vidé avant rechargement")

	_game.call("_load_game")
	_check(_game.call("has_pending_offline"),
		"hors-ligne : les gains en attente ont SURVÉCU à la sauvegarde (bug 1)")
	if not _game.call("has_pending_offline"):
		return
	var pending: Dictionary = _game.call("get_pending_offline")
	var restored: BigNum = pending.get("amount", BigNum.zero())
	_check(restored.equals(amount),
		"hors-ligne : montant restauré à l'identique (%s vs %s)" % [
			restored.format_short(), amount.format_short()])
	_check(is_equal_approx(float(pending.get("elapsed", 0.0)), 7200.0),
		"hors-ligne : durée restaurée (%.0f s)" % float(pending.get("elapsed", 0.0)))


## Même chose, mais en laissant passer l'autosave AVANT la fermeture, qui est le
## cas réel : le joueur ne ferme pas l'app dans la milliseconde suivant le calcul.
func _test_pending_survives_even_without_claiming() -> void:
	_fresh()
	# 5 h d'absence, pour dépasser le plafond de 2 h de départ et déclencher
	# l'indicateur `capped`. Avec 1 h, ce test passerait sans jamais exercer le
	# chemin qui compte : c'est cette ligne qui décide si la popup annonce
	# « plafond atteint », donc si le texte dit vrai au joueur.
	_make_pending(18000.0, 250.0)
	# Trois autosaves d'affilée, comme pendant une session.
	for _i in 3:
		_game.call("save_game")
	_check(_game.call("has_pending_offline"),
		"hors-ligne : les gains survivent à des autosaves répétées")

	_clear_in_memory()
	_game.call("_load_game")
	_check(_game.call("has_pending_offline"),
		"hors-ligne : toujours en attente après rechargement, malgré les autosaves")
	# Le plafond doit survivre aussi : la popup annonce « plafond atteint », et
	# une info perdue fait afficher un texte faux au joueur.
	var pending: Dictionary = _game.call("get_pending_offline")
	_check(bool(pending.get("capped", false)) == true,
		"hors-ligne : l'indicateur de plafond est conservé")


## « Remettre à zéro » doit effacer les gains en attente, comme le reste.
## `hard_reset()` le faisait à la main, `_apply_fresh_state()` non — et c'est
## ce dernier qui est emprunté quand la sauvegarde est illisible. Des gains
## en attente de la session précédente subsistaient alors que tout le reste
## retombait à zéro : le joueur se retrouvait crédité d'une somme que rien
## n'expliquait, ce qui est précisément le double comptage que ce fichier
## cherche à rendre impossible.
func _test_fresh_state_clears_pending() -> void:
	_fresh()
	_make_pending(7200.0, 100.0)
	_check(_game.call("has_pending_offline"), "état neuf : gains en attente avant remise à zéro")

	_game.call("_apply_fresh_state")
	_check(not _game.call("has_pending_offline"),
		"état neuf : _apply_fresh_state() efface les gains en attente (bug 3)")

	# Et le chemin de hard_reset, qui passe par là, doit rester cohérent.
	_make_pending(7200.0, 100.0)
	_game.call("hard_reset")
	_check(not _game.call("has_pending_offline"),
		"état neuf : hard_reset() efface toujours les gains en attente")


## Une absence courte est créditée sans popup. Ce crédit doit compter comme les
## autres : sinon un joueur qui fait cinquante mini-absences accumule des
## ressources qui ne comptent ni vers l'ascension, ni vers les succès « gagné au
## total ».
func _test_short_absence_counts_towards_totals() -> void:
	_fresh()
	_game.set("last_save_timestamp",
		Time.get_unix_time_from_system() - 20.0)  # < min_popup_seconds (60)
	var before_run: BigNum = _game.get("run_earnings")
	var before_life: BigNum = _game.get("lifetime_earnings")

	_game.call("_compute_offline_gains")

	_check(not _game.call("has_pending_offline"),
		"absence courte : pas de popup, comme prévu")
	_check(_game.get("run_earnings").gt(before_run),
		"absence courte : le gain entre dans le cumul de la run")
	_check(_game.get("lifetime_earnings").gt(before_life),
		"absence courte : le gain entre dans le cumul total")


# ================================================================== sauvegarde

## Une sauvegarde illisible ne doit pas être écrasée 20 secondes plus tard par
## l'autosave : la progression devient alors irrécupérable, silencieusement.
func _test_corrupt_save_is_quarantined() -> void:
	_fresh()
	_game.call("grant_resources", BigNum.from_float(1234.0), false)
	_game.call("save_game")

	# Corrompre : un fichier vide ne peut pas être décodé.
	var f := FileAccess.open(TEST_SAVE, FileAccess.WRITE)
	_check(f != null, "sauvegarde corrompue : fichier réécrivable")
	if f != null:
		f.store_buffer(PackedByteArray())
		f.close()

	_game.call("_apply_fresh_state")
	_game.call("_load_game")
	_check(_resources().is_zero(), "sauvegarde corrompue : la partie repart de zéro")

	# Le fichier illisible doit avoir été conservé, pas consommé.
	var quarantined := _find_quarantined()
	_check(not quarantined.is_empty(),
		"sauvegarde corrompue : le fichier d'origine a été MIS DE CÔTÉ (pas écrasé)")

	# Et surtout qu'il est intact : une quarantaine qui vidait le fichier ne
	# servirait à rien, puisque c'est la seule copie restante.
	_check(FileAccess.file_exists(quarantined),
		"sauvegarde corrompue : la copie mise de côté existe toujours")
	_check(_size_of(quarantined) == 0,
		"sauvegarde corrompue : la copie mise de côté contient bien les octets d'origine")

	# Le jeu doit repartir normalement : une sauvegarde neuve doit pouvoir
	# être écrite, puis relue. Sans cela le joueur resterait bloqué au lancement
	# suivant, ce qui est le pire scénario.
	_game.call("grant_resources", BigNum.from_float(42.0), false)
	_game.call("save_game")
	_check(FileAccess.file_exists(TEST_SAVE),
		"sauvegarde corrompue : une sauvegarde neuve a bien pu être écrite ensuite")
	_game.call("_apply_fresh_state")
	_game.call("_load_game")
	# `equals()`, pas `eq()` : `eq` n'existe pas sur `BigNum`, et un appel de
	# méthode absente ne lève RIEN en GDScript. La suite perdait donc cette
	# vérification ET les deux suivantes, et annonçait quand même « 0 échec » avec
	# 26 vérifications au lieu de 28. C'est la garde de comptage de
	# `tests/run_all.sh` qui l'a montré — pas le test lui-même, qui ne pouvait
	# pas le voir puisqu'il n'allait pas jusqu'au bout.
	#
	# Et une fois exécutée, elle a échoué : la production continue entre
	# l'écriture et la relecture, donc une égalité stricte est fausse par
	# construction. Mesuré : 42,000469 pour 42, soit 11 ppm — l'écart de quelques
	# images entre le `save_game()` et le `_load_game()`. D'où une tolérance
	# relative, comme partout ailleurs dans ces tests, et non un arrondi.
	var expected := BigNum.from_float(42.0)
	var drift := _resources().sub(expected)
	_check(drift.lt(expected.mul_float(0.01)),
		"sauvegarde corrompue : la reprise fonctionne, la progression repart (%s, écart %.2f ppm)"
			% [_resources().format_short(), absf(drift.to_float() / 42.0) * 1e6])

	for p in _quarantined_paths():
		_remove(p)


## Un contrôle statique, mais qui vaut mieux qu'un test d'exécution : la
## suppression du fichier avant son remplacement est un bug qui ne se manifeste
## QUE si le processus est tué entre deux instructions. Aucun test temporel ne
## le déclencherait de manière fiable, alors que sa présence est parfaitement
## vérifiable.
func _test_no_delete_before_rename() -> void:
	var src := FileAccess.get_file_as_string("res://core_engine/GameManager.gd")
	_check(not src.is_empty(), "lecture de GameManager.gd")
	if src.is_empty():
		return
	var rename_at := src.find("dir.rename(")
	_check(rename_at > 0, "save_game : le rename est présent")
	if rename_at <= 0:
		return
	var window := src.substr(maxi(0, rename_at - 400), rename_at)
	_check(not window.contains("dir.remove("),
		"save_game : AUCUN remove() entre l'ouverture et le rename (fenêtre de perte de sauvegarde)")


# ====================================================================== retour

## Le signal existe, il est émis, et personne ne l'écoute. Une connexion
## oubliée ne produit aucune erreur : `connect` manquant est silencieux.
func _test_foreground_signal_has_a_receiver() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/MainUI.gd")
	_check(not src.is_empty(), "lecture de MainUI.gd")
	if src.is_empty():
		return
	_check(src.contains("offline_gains_pending.connect("),
		"retour au premier plan : MainUI écoute offline_gains_pending (sinon aucun popup)")

	# Le test doit pouvoir échouer : on vérifie qu'un modificateur casse bien
	# la détection, sinon la chaîne de caractères pourrait être fausse.
	_check(not src.contains("offline_gains_pendingX.connect("),
		"le contrôle d'écho ne matche pas une chaîne volontairement fausse")

	# Et que la garde anti-empilement existe, sinon deux popups non-dismissibles
	# se superposent au retour au premier plan.
	_check(src.contains("func _is_modal_open()"),
		"retour au premier plan : la popup ne s'empile pas sur une modale ouverte")
	_check(src.contains("is_open()"),
		"Modal.is_open() est utilisé, et non un simple test de présence du nœud")


# ====================================================================== outils

func _fresh() -> void:
	_game.call("hard_reset")
	_game.set("save_path_override", TEST_SAVE)
	_game.set("pending_offline", {})
	_game.set("last_save_timestamp", 0.0)


## Simule la mort du processus : plus rien en mémoire, seul le fichier subsiste.
## `hard_reset()` ne convient pas ici, puisqu'il REÉCRIT la sauvegarde — on
## testerait alors son propre effacement au lieu de la relecture.
func _clear_in_memory() -> void:
	_game.set("pending_offline", {})


## Remplit `pending_offline` par le vrai chemin du jeu, en injectant un `elapsed`
## cohérent avec le montant. Aucun accès direct au dictionnaire : c'est
## `_compute_offline_gains` qu'on veut exercer.
func _make_pending(elapsed: float, seconds_of_production: float) -> BigNum:
	var prod: BigNum = _game.call("get_production_per_sec")
	_game.set("production_at_save", prod)
	_game.set("last_save_timestamp", Time.get_unix_time_from_system() - elapsed)
	# `min_popup_seconds` est à 60 s : elapsed doit le dépasser pour produire une
	# popup. Le montant suit la production réelle, sans le multiplier.
	_game.call("_compute_offline_gains")
	return prod.mul_float(minf(elapsed, 7200.0))


func _resources() -> BigNum:
	return _game.get("current_resources")


func _size_of(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := f.get_length()
	f.close()
	return n


func _quarantined_paths() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open("user://")
	if dir == null:
		return out
	for name in dir.get_files():
		if name.begins_with(TEST_SAVE.get_file() + ".corrupt"):
			out.append("user://" + name)
	return out


func _find_quarantined() -> String:
	var paths := _quarantined_paths()
	return "" if paths.is_empty() else paths[0]


func _wipe() -> void:
	_remove(TEST_SAVE)
	_remove(TEST_SAVE + ".tmp")
	for p in _quarantined_paths():
		_remove(p)


func _remove(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var dir := DirAccess.open(path.get_base_dir())
	if dir != null:
		dir.remove(path.get_file())


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  ok    ", label)
	else:
		_failures += 1
		print("  ECHEC ", label)
