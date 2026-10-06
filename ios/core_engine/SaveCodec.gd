class_name SaveCodec
extends RefCounted

## Encodage binaire des sauvegardes.
##
## Le format historique était un JSON brut : fragile, lent, sans version. Le
## format courant est un en-tête vérifié suivi de `var_to_bytes()`.
##
##   v3 — courant
##   [4 octets] "IDLS" (magic)
##   [1 octet ] version du format
##   [4 octets] longueur de la charge utile, uint32 petit-boutiste
##   [4 octets] CRC32 de la charge utile, uint32 petit-boutiste
##   [n octets] var_to_bytes(dictionary)
##
##   v2 — lecture seule : ni longueur ni CRC, donc invérifiable
##   [4 octets] "IDLS" (magic)
##   [1 octet ] version du format
##   [n octets] var_to_bytes(dictionary)
##
##   v1 — JSON brut, lu par `GameManager._load_legacy_json()`.
##
## POURQUOI LA LONGUEUR ET LE CRC.
##
## `var_to_bytes()` écrit sa propre longueur, donc un octet inversé au milieu
## d'une chaîne se décodait sans erreur : la sauvegarde redevenait VALIDE et
## FAUSSE. Mesuré sur une sauvegarde réelle, 144 inversions d'un seul bit :
## 31 refusées, 21 acceptées avec une valeur fausse. Un compteur de bâtiments
## passé de 42 à 43 est invisible, et l'autosave réécrit ensuite la version
## fausse par-dessus la vraie — la progression disparaît définitivement.
##
## C'est le pire mode de corruption possible : non pas un refus qui laisse le
## joueur repartir de zéro avec sa sauvegarde intacte, mais une valeur plausible
## qui s'installe en silence. Un CRC ne dit pas quel octet est faux ; il dit
## qu'il y en a un, ce qui suffit à ne rien écraser.
##
## v2 reste lisible, sans CRC et avec un avertissement. Refuser une sauvegarde
## pour un défaut de format qu'aucun octet de son contenu ne prouve reviendrait
## à punir le joueur d'une version antérieure du jeu. Mais plus rien n'écrit ce
## format : toute sauvegarde neuve est vérifiable.
##
## POURQUOI DES CHAMPS OBLIGATOIRES.
##
## Un Dictionary se décode sans garantie de contenir quoi que ce soit. Une
## charge utile tronquée — ou un `{}` — passait, et
## `GameManager._apply_save_data()` comblait les champs manquants par des
## valeurs par défaut. Le joueur repartait d'une partie neuve, l'autosave
## réécrivait le fichier vingt secondes plus tard, et la vraie sauvegarde
## disparaissait sans avoir jamais été signalée ni mise à l'écart : perte totale,
## invisible, irrécupérable.
##
## Une sauvegarde valide a un CONTRAT, pas seulement une syntaxe.

const MAGIC := "IDLS"
const CURRENT_VERSION := 3
## Longueur de l'en-tête v3 : magic, version, longueur, CRC.
const HEADER_SIZE := 13
## Longueur de l'en-tête v2, qui n'a ni longueur ni CRC.
const HEADER_SIZE_V2 := 5

## Champs qu'aucune sauvegarde écrite par ce jeu ne peut omettre.
##
## `last_save` est l'ancre des gains hors-ligne : sans lui, le jeu ne peut pas
## distinguer « absent depuis dix minutes » de « absent depuis dix secondes ».
## Les trois dictionnaires de progression sont les trois axes du jeu ; un `{}`
## ne peut pas être une sauvegarde.
##
## Ces noms sont ceux de `GameManager._serialize()`, pas ceux des variables
## d'état (`buildings_owned`, …). Une première version utilisait les seconds, et
## toute sauvegarde a été refusée à la première lecture : la liste est un
## CONTRAT avec l'en-tête d'écriture, et les deux se vérifient l'un l'autre par
## le test. `test_save_codec.gd` l'attrape.
const REQUIRED_KEYS: Array[String] = [
	"last_save",
	"buildings",
	"click_upgrades",
	"research",
]

## Table de CRC32 construite à la demande. 256 entrées : la construction coûte
## donc moins cher que le calcul pour toute charge utile de plus de 256 octets,
## ce qui est le cas de toute sauvegarde réelle.
static var _crc_table: Array[int] = []


static func encode(data: Dictionary) -> PackedByteArray:
	var payload := var_to_bytes(data)
	var out := MAGIC.to_ascii_buffer()
	out.append(CURRENT_VERSION & 0xFF)
	out.append_array(_u32(payload.size()))
	out.append_array(_u32(crc32(payload)))
	out.append_array(payload)
	return out


## Retourne un dictionnaire, ou null si les données sont illisibles.
## Ne lève jamais : une sauvegarde corrompue ne doit pas empêcher le jeu de
## démarrer. `null` signifie explicitement « ne fais confiance à rien de ce
## fichier », et l'appelant le met alors à l'écart au lieu de le réécrire.
static func decode(bytes: PackedByteArray) -> Variant:
	if bytes.size() <= HEADER_SIZE_V2:
		return null
	if bytes.slice(0, 4).get_string_from_ascii() != MAGIC:
		return null
	var version := bytes[4]
	if version > CURRENT_VERSION:
		# Écrit par une version plus récente du jeu : refusée proprement.
		push_warning("Sauvegarde en version %d, le jeu ne comprend que la version %d."
			% [version, CURRENT_VERSION])
		return null
	if version < 2:
		# v1 est du JSON brut, sans en-tête binaire : rien à lire ici.
		return null
	if version == 2:
		push_warning("Sauvegarde v2 lue sans CRC : format antérieur, plus rien ne l'écrit.")
		return _validated(bytes_to_var(bytes.slice(HEADER_SIZE_V2)))
	if bytes.size() <= HEADER_SIZE:
		return null
	# La longueur est vérifiée AVANT le décodage : décoder une charge utile
	# tronquée est au mieux inutile, au pire une lecture d'une structure fausse.
	if _read_u32(bytes, 5) != bytes.size() - HEADER_SIZE:
		return null
	var payload := bytes.slice(HEADER_SIZE)
	if _read_u32(bytes, 9) != crc32(payload):
		return null
	return _validated(bytes_to_var(payload))


## Rejette une charge utile syntaxiquement correcte mais sémantiquement vide.
##
## `bytes_to_var()` rend un Dictionary vide sans difficulté, et un Dictionary
## vide est indiscernable d'une sauvegarde neuve — or une sauvegarde neuve
## n'existe pas, `save_game()` écrit toujours tous les champs. Le corps est donc
## traité comme une corruption, ce qui mène à la mise à l'écart : le joueur
## repart de zéro mais sa sauvegarde reste sur le disque, récupérable.
static func _validated(parsed: Variant) -> Variant:
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	var d := parsed as Dictionary
	for key in REQUIRED_KEYS:
		if not d.has(key):
			push_warning("Sauvegarde incomplète : champ « %s » absent." % key)
			return null
	return d


# --------------------------------------------------------------------- utilitaires

## CRC32 (polynôme 0xEDB88320), calculé sur les octets RÉELS de la charge utile.
##
## Sur le dictionnaire, jamais : le sérialiser deux fois ne donnerait pas
## forcément le même octet, alors que le champ de contrôle ne peut porter que sur
## ce qui est effectivement écrit sur le disque.
static func crc32(payload: PackedByteArray) -> int:
	if _crc_table.is_empty():
		for i in 256:
			var c := i
			for _bit in 8:
				c = (c >> 1) ^ (0xEDB88320 if c & 1 else 0)
			_crc_table.append(c)
	var crc := 0xFFFFFFFF
	for byte in payload:
		crc = (crc >> 8) ^ _crc_table[(crc ^ byte) & 0xFF]
	return crc ^ 0xFFFFFFFF


static func _u32(value: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	for i in 4:
		out[i] = (value >> (i * 8)) & 0xFF
	return out


static func _read_u32(bytes: PackedByteArray, offset: int) -> int:
	if offset + 4 > bytes.size():
		return -1
	return bytes[offset] | (bytes[offset + 1] << 8) \
		| (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)
