class_name SaveCodec
extends RefCounted

## Encodage binaire des saves.
##
## Le format historique était un JSON brut, fragile et lent (et sans version). Le
## nouveau format est un en-tête suivi de var_to_bytes() : compact, rapide, et
## porte un numéro de version qui autorise les migrations.
##
##   [4 octets] "IDLS" (magic)
##   [1 octet ] version du format
##   [n octets] var_to_bytes(dictionary)

const MAGIC := "IDLS"
const CURRENT_VERSION := 2
const HEADER_SIZE := 5


static func encode(data: Dictionary) -> PackedByteArray:
	var out := MAGIC.to_ascii_buffer()
	out.append(CURRENT_VERSION & 0xFF)
	out.append_array(var_to_bytes(data))
	return out


## Retourne un dictionnaire, ou null si les données sont illisibles.
## Ne lève jamais : une save corrompue ne doit pas empêcher le jeu de démarrer.
static func decode(bytes: PackedByteArray) -> Variant:
	if bytes.size() <= HEADER_SIZE:
		return null
	if bytes.slice(0, 4).get_string_from_ascii() != MAGIC:
		return null
	var version := bytes[4]
	if version > CURRENT_VERSION:
		# Save produite par une version plus récente du jeu : refusée proprement.
		push_warning("Save en version %d, le jeu ne comprend que la version %d." % [version, CURRENT_VERSION])
		return null
	var parsed: Variant = bytes_to_var(bytes.slice(HEADER_SIZE))
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	return parsed
