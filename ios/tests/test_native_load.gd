extends SceneTree

## Vérifie que les extensions natives RÉELLEMENT COMPILÉES se chargent dans
## Godot, s'enregistrent dans ClassDB, et exposent exactement l'interface que
## core_engine/AdService.gd et core_engine/StoreService.gd appellent.
##
##   godot --headless --path . --script res://tests/test_native_load.gd
##
## ## Pourquoi ce test existe, et ce qu'il ne peut pas faire
##
## Avant qu'il existe, le code natif de ce dépôt n'avait jamais été compilé. Il
## ne l'était pas seulement par manque d'environnement : il NE COMPILAIT PAS.
## Un premier essai a révélé au moins huit défauts distincts, dont trois qui
## laissaient le build « réussir » :
##
##   1. `if scons … | tee log` — en zsh le statut d'un pipeline est celui de sa
##      dernière commande, donc de `tee`, qui réussit toujours. Tout build cassé
##      était rapporté réussi, et le manifeste s'activait quand même.
##   2. Le manifeste annonçait des chemins sans fichier derrière (macOS en
##      `.framework`, dossier de sortie `native/bin/` au lieu de
##      `native/<ext>/bin/`). Le build « réussissait », Godot ne trouvait rien.
##   3. `deactivate()` faisait `mv $ACTIVE $DIST`, écrasant la source de vérité
##      par la copie périmée à chaque build : toute correction du manifeste
##      disparaissait silencieusement au build suivant.
##
## Aucun de ces défauts n'est visible depuis GDScript, et aucun ne se voyait
## tant qu'on ne chargeait pas l'extension pour de vrai. C'est ce que fait ce
## test.
##
## ## Ce qu'il ne vérifie pas
##
## Un dlopen réussi ne dit RIEN du comportement d'AdMob ou de StoreKit sur un
## appareil : ni l'affichage d'une vidéo, ni l'achat, ni la restauration. Cela
## exige un iPhone, un certificat, des identifiants App Store Connect réels, et
## des produits publiés. Ce test s'arrête donc exactement là où le matériel
## commence, et le dit.
##
## ## Pourquoi il peut ne rien vérifier
##
## `build.sh` n'active le manifeste (.gdextension) qu'après un build entièrement
## réussi. Son absence signifie donc « pas compilé sur cette machine », pas
## « cassé ». Dans ce cas le test n'effectue aucune vérification et le dit
## explicitement : mieux vaut afficher zéro que faire semblant d'avoir vérifié.
## test_plugin_contract.gd couvre le contrat d'interface par un faux plug-in et
## s'exécute toujours, lui.

var _failed := 0
var _passed := 0

# Ce que le GDScript appelle. Le nom de la classe, ses méthodes et ses signaux.
# Les signatures exactes sont vérifiées par check_native_contract.py, qui
# compare les en-têtes C, les .cpp, le .mm et le Swift entre eux.
# Ce que le GDScript appelle, relevé dans les D_METHOD de src/*.cpp et dans les
# appels réels de AdService.gd / StoreService.gd. Ce n'est PAS une supposition :
# check_native_contract.py compare cette liste à celle des D_METHOD et échoue si
# elles divergent, donc ce test ne peut pas dériver du C++ en silence. (Il l'a
# déjà fait une fois : la première version de ce fichier annonçait
# `IdleStore.is_available()`, `configure()` et le signal `purchases_restored`,
# trois noms qui n'ont jamais existé.)
const CLASSES := {
	"IdleAds": {
		"manifest": "res://native/ads/IdleAds.gdextension",
		"methods": ["is_configured", "configure", "show_rewarded"],
		"signals": ["rewarded_completed", "rewarded_failed"],
	},
	"IdleStore": {
		"manifest": "res://native/store/IdleStore.gdextension",
		"methods": ["is_configured", "start", "purchase", "restore", "is_purchased", "get_price"],
		"signals": ["products_loaded", "purchase_completed", "purchase_failed", "purchase_restored"],
	},
	"IdleNotifications": {
		"manifest": "res://native/notifications/IdleNotifications.gdextension",
		"methods": ["is_configured", "get_permission", "refresh_permission", "request_permission",
			"schedule", "cancel", "cancel_all", "open_settings"],
		"signals": ["permission_changed", "schedule_completed"],
	},
}


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  ok    %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s %s" % [label, detail])


func _initialize() -> void:
	print("== Chargement des extensions natives compilées ==")
	_run()


func _run() -> void:
	# Laisser l'initialisation des GDExtension se terminer : au premier frame,
	# les bibliothèques d'autoload sont enregistrées.
	await process_frame

	var compiled := 0
	for class_name_camel: String in CLASSES:
		var spec: Dictionary = CLASSES[class_name_camel]
		var manifest: String = spec["manifest"]

		if not ResourceLoader.exists(manifest):
			# Le manifeste actif est une copie faite par build.sh, et build.sh ne
			# l'écrit qu'après un succès complet. Son absence = non compilé.
			print("  --    %s : extension non compilée ici, rien à charger" % class_name_camel)
			continue
		compiled += 1

		# Le vrai piège : le manifeste existe, la bibliothèque existe, et le
		# dlopen échoue quand même (chemin faux, architecture fausse, symbole
		# manquant). Godot ne signale PAS l'échec à l'appelant — load() renvoie
		# une ressource vide et trace une erreur. Il faut donc regarder ce que
		# ClassDB contient réellement, pas ce que load() a renvoyé.
		var ext: Resource = null
		if ResourceLoader.exists(manifest):
			ext = ResourceLoader.load(manifest, "GDExtension", ResourceLoader.CACHE_MODE_IGNORE)
		_check("%s : le manifeste se charge" % class_name_camel, ext != null,
			"-> %s" % manifest)

		var registered: bool = ClassDB.class_exists(class_name_camel)
		_check("%s : la classe est enregistrée dans ClassDB" % class_name_camel, registered,
			"-> la bibliothèque a pu être ouverte mais pas initialisée")

		if not registered:
			continue

		for method: String in spec["methods"]:
			_check("%s.%s() existe" % [class_name_camel, method],
				ClassDB.class_has_method(class_name_camel, method, true),
				"-> le C++ et le GDScript ne sont pas d'accord")

		for signal_name: String in spec["signals"]:
			_check("%s émet le signal %s" % [class_name_camel, signal_name],
				ClassDB.class_has_signal(class_name_camel, signal_name),
				"-> le signal manque, AdService attendra indéfiniment")

	if compiled == 0:
		print("")
		print("  Aucune extension compilée sur cette machine : 0 vérification.")
		print("  Pour en compiler : NO_SDK=1 native/ads/build.sh macos ios")
		print("                    native/store/build.sh macos ios")
	else:
		print("")
		print("  %d extension(s) compilée(s) réellement chargées." % compiled)

	print("")
	print("  Rappel : un dlopen réussi ne prouve ni l'affichage d'une pub AdMob,")
	print("  ni un achat StoreKit. Cela demande un appareil, un certificat et des")
	print("  produits publiés dans App Store Connect.")

	if _failed > 0:
		print("")
		print("  %d échec(s), %d vérifications." % [_failed, _passed])
		quit(1)
		return
	print("  %d vérifications, 0 échec." % _passed)
	quit(0)
