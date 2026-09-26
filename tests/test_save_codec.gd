extends SceneTree
## Intégrité du format de sauvegarde.
##
##   godot --headless --path . --script res://tests/test_save_codec.gd
##
## Le test central est `_test_every_bit_flip_is_caught()`. Une inversion d'un
## seul bit dans la charge utile ne brise pas `var_to_bytes()` : la
## sauvegarde redevenait VALIDE et FAUSSE, et l'autosave réécrivait ensuite la
## version fausse par-dessus la vraie. C'est le mode de corruption le plus
## coûteux, parce qu'il ne se voit pas.
##
## Le test est donc écrit pour ne pas pouvoir passer par erreur : il vérifie que
## chaque octet inversé est SOIT refusé, SOIT redécodé à l'identique. Une
## régression du CRC ne peut pas passer inaperçue — et un décodeur qui refuse tout
## ne passerait pas non plus, d'où le contrôle d'écho sur la référence.

var _failed := 0
var _passed := 0


func _check(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  ok    %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s %s" % [label, detail])


func _initialize() -> void:
	print("=== Format de sauvegarde ===")
	# Une attente : `GameManager.config` est `null` tant que son `_ready()` n'a
	# pas tourné, et `_serialize()` en a besoin.
	await process_frame
	_test_round_trip()
	_test_header_layout()
	_test_every_bit_flip_is_caught()
	_test_header_fields_are_protected()
	_test_truncation_and_foreign_files()
	_test_missing_required_keys_are_refused()
	_test_required_keys_match_what_the_game_writes()
	_test_older_and_newer_formats()
	print("=== test_save_codec : %d vérifications, %d échecs ===" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


# ------------------------------------------------------------------ référence

## Une sauvegarde réaliste : mêmes types et mêmes noms de champs que
## `GameManager._serialize()`.
func _sample() -> Dictionary:
	return {
		"version": 2,
		"resources": [1.0, 42],
		"click_bonus": [0.5, 0],
		"buildings": {"b1": 42, "b2": 7},
		"click_upgrades": {"c1": 3},
		"research": {"r1": 2},
		"achievements": ["first_crystal", "ten_buildings"],
		"prestige_points": 19,
		"prestige_count": 3,
		"run_earnings": [1.5, 12],
		"lifetime_earnings": [1.5, 340],
		"research_levels_total": 2,
		"buildings_total_owned": 49,
		"boost_multiplier": 10.0,
		"boost_ends_at": 0.0,
		"boost_started_at": 0.0,
		"boost_stacks": 0,
		"flags": {"no_ads": true},
		"stats": {"clicks": 128, "play_time": 3600.0},
		"last_save": 1700000000.0,
		"production_at_save": [2.5, 8],
		"pending_offline": {"amount": [9.0, 3], "elapsed": 7200.0, "capped": true},
	}


# ------------------------------------------------------------------ aller-retour

func _test_round_trip() -> void:
	var original := _sample()
	var decoded: Variant = SaveCodec.decode(SaveCodec.encode(original))
	_check(decoded != null, "aller-retour : la sauvegarde se relit")
	_check(typeof(decoded) == TYPE_DICTIONARY, "aller-retour : le corps est un dictionnaire")
	_check(decoded == original, "aller-retour : contenu strictement identique")
	if typeof(decoded) != TYPE_DICTIONARY:
		return
	var d := decoded as Dictionary
	# Le piège du « presque identique » : sans relire champ par champ, une
	# différence sur un seul octet passerait pour un succès.
	_check(d.get("buildings") == {"b1": 42, "b2": 7},
		"aller-retour : les compteurs de bâtiments sont exacts", "-> %s" % [d.get("buildings")])
	_check((d.get("pending_offline", {}) as Dictionary).get("capped") == true,
		"aller-retour : l'indicateur de plafond hors-ligne survit")
	_check(d.get("boost_stacks") == 0,
		"aller-retour : le compteur de surcharges survit (0, pas absent)")
	_check(d.has("boost_stacks"),
		"aller-retour : le champ ajouté récemment est bien écrit et relu")


func _test_header_layout() -> void:
	var bytes := SaveCodec.encode(_sample())
	_check(bytes.size() > SaveCodec.HEADER_SIZE, "en-tête : la charge utile suit l'en-tête")
	_check(bytes.slice(0, 4).get_string_from_ascii() == SaveCodec.MAGIC, "en-tête : magic « IDLS »")
	_check(bytes[4] == SaveCodec.CURRENT_VERSION,
		"en-tête : version %d écrite" % SaveCodec.CURRENT_VERSION, "-> %d" % bytes[4])
	var declared := _read_u32(bytes, 5)
	_check(declared == bytes.size() - SaveCodec.HEADER_SIZE,
		"en-tête : la longueur déclarée correspond au fichier (%d)" % declared, "-> %d" % declared)
	_check(_read_u32(bytes, 9) == SaveCodec.crc32(bytes.slice(SaveCodec.HEADER_SIZE)),
		"en-tête : le CRC correspond à la charge utile")
	# Le CRC est calculé sur les OCTETS, pas sur le dictionnaire : le
	# sérialiser deux fois ne donnerait pas forcément le même octet, alors que le
	# champ de contrôle ne peut porter que sur ce qui va réellement sur le disque.
	_check(SaveCodec.crc32(bytes.slice(SaveCodec.HEADER_SIZE))
			== SaveCodec.crc32(bytes.slice(SaveCodec.HEADER_SIZE)),
		"en-tête : le CRC est stable sur les mêmes octets")
	_check(SaveCodec.crc32(PackedByteArray([0x01])) != SaveCodec.crc32(PackedByteArray([0x02])),
		"en-tête : le CRC distingue deux charges utiles d'un octet")


# ------------------------------------------------------------------ corruption

## Le test qui vaut le fichier entier : chaque octet de la charge utile est
## inversé, et aucune ne doit produire une sauvegarde ACCEPTÉE et DIFFÉRENTE.
##
## Mesuré avant correction : sur 144 inversions d'un seul bit, 31 refusées et 21
## acceptées avec une valeur fausse. Le pire n'est pas l'octet inversé, c'est
## qu'un compteur de bâtiments passe de 42 à 43 sans que rien ne le signale, puis
## que l'autosave réécrit par-dessus.
func _test_every_bit_flip_is_caught() -> void:
	var original := _sample()
	var good := SaveCodec.encode(original)
	var header_size := SaveCodec.HEADER_SIZE
	# Contrôle d'écho : la référence doit être ACCEPTÉE. Sans lui, un décodeur qui
	# refuse tout passerait ce test — et c'est un défaut aussi grave que l'autre :
	# le joueur perdrait sa partie à chaque sauvegarde.
	_check(SaveCodec.decode(good) == original,
		"inversion d'un bit : la référence est acceptée (contrôle d'écho)")

	var blind := 0
	for mask: int in [0x01, 0x02, 0x80, 0x55]:
		var accepted := 0
		var wrong := 0
		var first_wrong := -1
		for i in range(header_size, good.size()):
			var copy := good.duplicate()
			copy[i] = copy[i] ^ mask
			var decoded: Variant = SaveCodec.decode(copy)
			if decoded == null:
				continue
			accepted += 1
			if decoded != original:
				wrong += 1
				if first_wrong < 0:
					first_wrong = i
		var label := "inversion 0x%02X" % mask
		_check(wrong == 0,
			"%s : aucune sauvegarde fausse acceptée (%d testés, %d acceptées, %d fausses)"
				% [label, good.size() - header_size, accepted, wrong],
			"-> premier octet fautif : %d" % first_wrong)
		# Non-vacuité. Une première version de ce test exigeait « au moins une
		# sauvegarde acceptée », en supposant que certaines inversions
		# survivraient. C'est faux : avec un CRC, AUCUNE ne survit, et c'est le
		# meilleur résultat possible. La condition à vérifier n'est donc pas
		# « des solutions passent » mais « le contrôle a du pouvoir » : pour
		# chaque position inversée, le CRC doit CHANGER. Un octet pour lequel il
		# resterait identique serait un angle mort du CRC — et alors la
		# vérification précédente passerait pour la mauvaise raison.
		blind += _blind_spots(good, header_size, mask)
	_check(blind == 0,
		"inversion d'un bit : le CRC distingue chaque position (%d angles morts sur %d)"
			% [blind, 4 * (good.size() - header_size)])


## Nombre de positions dont l'inversion ne change PAS le CRC. Un tel octet
## serait invisible au contrôle d'intégrité : le fichier modifié serait accepté.
## Un CRC32 n'en a aucun en pratique ; le test le vérifie plutôt que de le
## supposer, parce qu'un « ça ne peut pas arriver » non mesuré est un nœud
## papillon.
func _blind_spots(good: PackedByteArray, header_size: int, mask: int) -> int:
	var reference := SaveCodec.crc32(good.slice(header_size))
	var blind := 0
	for i in range(header_size, good.size()):
		var copy := good.duplicate()
		copy[i] = copy[i] ^ mask
		if SaveCodec.crc32(copy.slice(header_size)) == reference:
			blind += 1
	return blind


## Les deux champs de l'en-tête protègent le corps. Les garder sans les vérifier
## reviendrait à écrire une adresse sans maison : le fichier se ferait passer pour
## une sauvegarde valide alors qu'il n'en est pas une.
func _test_header_fields_are_protected() -> void:
	var good := SaveCodec.encode(_sample())

	var bad_crc := good.duplicate()
	bad_crc[9] = bad_crc[9] ^ 0x01
	_check(SaveCodec.decode(bad_crc) == null, "en-tête : un CRC falsifié est refusé")

	var bad_len := good.duplicate()
	bad_len[5] = bad_len[5] ^ 0x01
	_check(SaveCodec.decode(bad_len) == null, "en-tête : une longueur falsifiée est refusée")

	# Le champ de version est lui aussi protégé : un fichier qui prétend être
	# d'une autre version doit être refusé, pas décodé sous une autre règle.
	var bad_version := good.duplicate()
	bad_version[4] = 0
	_check(SaveCodec.decode(bad_version) == null,
		"en-tête : une version falsifiée est refusée")

	# Des octets ajoutés à la fin : le fichier dérive au-delà de sa longueur
	# déclarée, ce que le seul CRC ne remarque pas — il ne couvre que ce qu'il
	# déclare.
	var trailing := good.duplicate()
	trailing.append(0x00)
	_check(SaveCodec.decode(trailing) == null,
		"en-tête : des octets surnuméraires à la fin sont refusés")

	# Un octet retiré.
	_check(SaveCodec.decode(good.slice(0, good.size() - 1)) == null,
		"en-tête : un octet de moins est refusé")
	# Un fichier trop court pour lire son propre en-tête.
	_check(SaveCodec.decode(good.slice(0, SaveCodec.HEADER_SIZE - 1)) == null,
		"en-tête : un fichier trop court pour son en-tête est refusé")


func _test_truncation_and_foreign_files() -> void:
	var good := SaveCodec.encode(_sample())
	_check(SaveCodec.decode(good.slice(0, SaveCodec.HEADER_SIZE)) == null,
		"troncature : un en-tête sans charge utile est refusé")
	_check(SaveCodec.decode(PackedByteArray()) == null, "troncature : fichier vide refusé")
	_check(SaveCodec.decode(SaveCodec.MAGIC.to_ascii_buffer()) == null,
		"troncature : le magic seul est refusé")
	_check(SaveCodec.decode('{"version": 1, "last_save": 0}'.to_utf8_buffer()) == null,
		"corps étranger : un JSON brut n'est pas accepté par ce décodeur")
	_check(SaveCodec.decode(PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])) == null,
		"corps étranger : des octets nuls sont refusés")

	# Un corps CORRECTEMENT enveloppé mais qui n'est pas un dictionnaire. Le CRC
	# et la longueur sont valides, donc seul le contrôle de type peut le refuser —
	# c'est ce qui rend la sonde utile.
	var str_body := _wrap(var_to_bytes("une chaîne"))
	_check(SaveCodec.decode(str_body) == null,
		"corps étranger : une chaîne, enveloppée et vérifiée, est refusée")
	var nil_body := _wrap(var_to_bytes(null))
	_check(SaveCodec.decode(nil_body) == null,
		"corps étranger : null, enveloppé et vérifié, est refusé")
	var arr_body := _wrap(var_to_bytes([1, 2, 3]))
	_check(SaveCodec.decode(arr_body) == null,
		"corps étranger : un tableau, enveloppé et vérifié, est refusé")


## Construit un fichier v3 valide autour d'une charge utile quelconque, en
## calculant une longueur et un CRC CORRECTS. Sans cela, un refus ne prouverait
## rien de la structure : le refus viendrait des octets de contrôle.
func _wrap(payload: PackedByteArray) -> PackedByteArray:
	var out := SaveCodec.MAGIC.to_ascii_buffer()
	out.append(SaveCodec.CURRENT_VERSION)
	for i in 4:
		out.append((payload.size() >> (i * 8)) & 0xFF)
	for i in 4:
		out.append((SaveCodec.crc32(payload) >> (i * 8)) & 0xFF)
	out.append_array(payload)
	return out


# ------------------------------------------------------- champs obligatoires

## Un dictionnaire se décode sans garantie de contenu. Une charge utile tronquée
## — ou un `{}` — passait, `GameManager._apply_save_data()` comblait les champs
## manquants, le joueur repartait d'une partie neuve, et l'autosave réécrivait le
## fichier vingt secondes plus tard : perte totale, invisible, irrécupérable.
func _test_missing_required_keys_are_refused() -> void:
	var original := _sample()

	# Le cas de tête : le dictionnaire vide.
	_check(SaveCodec.decode(SaveCodec.encode({})) == null,
		"champs obligatoires : un dictionnaire vide est refusé")

	# Un seul champ sur quatre manque.
	for key in SaveCodec.REQUIRED_KEYS:
		var partial := original.duplicate()
		partial.erase(key)
		_check(SaveCodec.decode(SaveCodec.encode(partial)) == null,
			"champs obligatoires : refus sans « %s »" % key)

	# Un seul champ sur quatre est présent : c'est le cas réel d'une charge
	# utile tronquée au milieu d'un gros dictionnaire.
	for key in SaveCodec.REQUIRED_KEYS:
		var partial2: Dictionary = {}
		partial2[key] = original[key]
		_check(SaveCodec.decode(_wrap(var_to_bytes(partial2))) == null,
			"champs obligatoires : seul « %s » présent, refusé" % key)

	# Et l'inverse, pour que la liste ne soit pas simplement un liste de refus :
	# une sauvegarde complète passe, une sauvegarde amputée d'un seul champ
	# échoue. C'est la différence entre une règle et une interdiction.
	_check(SaveCodec.decode(SaveCodec.encode(original)) == original,
		"champs obligatoires : la sauvegarde complète est acceptée (contre-écho)")


## Le contrat entre `REQUIRED_KEYS` et ce que le jeu ÉCRIT réellement.
##
## Une première version de `REQUIRED_KEYS` utilisait les noms des variables
## d'état (`buildings_owned`, `click_upgrades_owned`, `research_levels`) au lieu
## de ceux de `_serialize()` (`buildings`, `click_upgrades`, `research`). Toutes
## les sauvegardes ont alors été refusées à la première lecture, et
## `test_offline_persistence` a perdu ses gains hors-ligne. Ce test appelle
## `_serialize()` pour de vrai : il ne peut pas dériver du code d'écriture.
func _test_required_keys_match_what_the_game_writes() -> void:
	var game: Variant = root.get_node_or_null("GameManager")
	_check(game != null, "contrat d'écriture : autoload GameManager présent")
	if game == null:
		return
	var written: Variant = game.call("_serialize")
	_check(typeof(written) == TYPE_DICTIONARY,
		"contrat d'écriture : _serialize() rend un dictionnaire")
	if typeof(written) != TYPE_DICTIONARY:
		return
	var d := written as Dictionary
	for key in SaveCodec.REQUIRED_KEYS:
		_check(d.has(key), "contrat d'écriture : _serialize() écrit bien « %s »" % key,
			"-> absent : la sauvegarde sera refusée")
	_check(SaveCodec.decode(SaveCodec.encode(d)) == d,
		"contrat d'écriture : la sauvegarde réelle du jeu se relit à l'identique")


# ------------------------------------------------------------------ versions

## v2 reste lisible, sans CRC : refuser une sauvegarde pour un défaut de format
## qu'aucun octet de son contenu ne prouve reviendrait à punir le joueur d'une
## version antérieure du jeu. v4, elle, doit être refusée proprement, et v1 doit
## rendre `null` pour que `GameManager` prenne le chemin de migration.
func _test_older_and_newer_formats() -> void:
	var original := _sample()

	var v2 := SaveCodec.MAGIC.to_ascii_buffer()
	v2.append(2)
	v2.append_array(var_to_bytes(original))
	_check(v2.size() == 5 + var_to_bytes(original).size(),
		"versions : le format v2 n'a bien ni longueur ni CRC")
	_check(SaveCodec.decode(v2) == original, "versions : une sauvegarde v2 reste lisible")

	# v2 reste soumise à la règle des champs obligatoires : on ne sacrifie pas le
	# contrat de contenu sous prétexte que le format est ancien.
	var v2_empty := SaveCodec.MAGIC.to_ascii_buffer()
	v2_empty.append(2)
	v2_empty.append_array(var_to_bytes({}))
	_check(SaveCodec.decode(v2_empty) == null,
		"versions : v2 n'échappe pas aux champs obligatoires")

	var v4 := SaveCodec.encode(original)
	v4[4] = 4
	_check(SaveCodec.decode(v4) == null,
		"versions : une sauvegarde plus récente que le jeu est refusée")

	var v1 := 'IDL'.to_ascii_buffer()
	v1.append(1)
	v1.append_array('{"version": 1}'.to_utf8_buffer())
	_check(SaveCodec.decode(v1) == null,
		"versions : v1 renvoie null pour laisser le jeu migrer le JSON")

	var alien := v2.duplicate()
	alien[0] = 0x41
	_check(SaveCodec.decode(alien) == null, "versions : un magic inconnu est refusé")


static func _read_u32(bytes: PackedByteArray, offset: int) -> int:
	return bytes[offset] | (bytes[offset + 1] << 8) \
		| (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)
