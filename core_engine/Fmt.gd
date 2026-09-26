class_name Fmt
extends RefCounted

## Formatage lisible (français) des durées et des multiplicateurs.
## Volontairement une classe à statiques : aucune instanciation.


## "2 h 04 min 09 s", "45 s", "3 j 02 h"
static func duration(seconds: float) -> String:
	var total := int(maxf(0.0, seconds))
	var days := total / 86400
	var hours := (total % 86400) / 3600
	var minutes := (total % 3600) / 60
	var secs := total % 60
	if days > 0:
		return "%d j %02d h" % [days, hours]
	if hours > 0:
		return "%d h %02d min %02d s" % [hours, minutes, secs]
	if minutes > 0:
		return "%d min %02d s" % [minutes, secs]
	return "%d s" % secs


## "2h04", "45s" : pour les libellés compacts d'interface.
static func duration_short(seconds: float) -> String:
	var total := int(maxf(0.0, seconds))
	var days := total / 86400
	var hours := (total % 86400) / 3600
	var minutes := (total % 3600) / 60
	var secs := total % 60
	if days > 0:
		return "%dj%02dh" % [days, hours]
	if hours > 0:
		return "%dh%02d" % [hours, minutes]
	if minutes > 0:
		return "%dm%02d" % [minutes, secs]
	return "%ds" % secs


## "2 h", "3 j", "45 s" : pour un compteur de hepatic fatigue.
static func duration_coarse(seconds: float) -> String:
	var total := int(maxf(0.0, seconds))
	if total >= 86400:
		return "%d j" % (total / 86400)
	if total >= 3600:
		return "%d h" % (total / 3600)
	if total >= 60:
		return "%d min" % (total / 60)
	return "%d s" % total


## Un BigNum passé en float, formaté proprement.
static func number(value: float) -> String:
	return BigNum.from_float(value).format_short()


static func number_bn(value: BigNum) -> String:
	return value.format_short() if value != null else "0"


## "x2.5", "x10", "x1.25" : multiplicateurs de recherche / d'ascension.
static func multiplier(value: float) -> String:
	if value >= 100.0 or value == floorf(value):
		return "x%s" % BigNum.from_float(value).format_short(0)
	return "x%s" % BigNum.from_float(value).format_short(2)


static func percent(ratio: float, decimals: int = 0) -> String:
	return ("%." + str(decimals) + "f %%") % (ratio * 100.0)
