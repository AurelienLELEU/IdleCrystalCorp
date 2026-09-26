class_name BigNum
extends RefCounted

## Représentation décimale flottante : valeur = mantissa * 10^exponent
## avec 1.0 <= |mantissa| < 10.0 (ou 0.0 pour zéro).
##
## Un idle game dépasse rapidement 2^53 (perte de précision des floats) et même
## 1e308 (overflow -> inf). BigNum stocke mantisse + exposant, ce qui autorise
## des plages allant de 1e-1e9 à 1e+1e9 et ne déborde jamais.
##
## Toutes les opérations renvoient une NOUVELLE instance : BigNum est immuable
## par convention, ce qui évite les aliasing accidentels.

const EXP_MAX := 1_000_000_000
const EXP_MIN := -1_000_000_000
## log(10), pour convertir un logarithme népérien en log10.
const LN10 := 2.302585092994046
## Nombre de chiffres significatifs d'un double IEEE-754 : en dessous, l'addition
## de deux termes d'exponents très différents est perdue, ce qui est acceptable.
const PRECISION_DIGITS := 17

## Abréviations d'échelle courte, convention française.
const SUFFIXES: PackedStringArray = [
	"", " K", " M", " Md", " Tn", " Qa", " Qi", " Sx", " Sp", " Oc", " No", " Dc",
]

var mantissa: float = 0.0
var exponent: int = 0


# ---------------------------------------------------------------- constructions

static func make(m: float, e: int) -> BigNum:
	var b := BigNum.new()
	if is_nan(m) or m == 0.0:
		return b
	if is_inf(m):
		b.mantissa = 1.0 if m > 0.0 else -1.0
		b.exponent = EXP_MAX if m > 0.0 else EXP_MIN
		return b
	e = clampi(e, EXP_MIN, EXP_MAX)
	var abs_m := absf(m)
	if abs_m >= 1.0:
		while abs_m >= 10.0:
			abs_m /= 10.0
			e += 1
			if e >= EXP_MAX:
				e = EXP_MAX
				abs_m = 1.0
				break
	else:
		while abs_m < 1.0:
			abs_m *= 10.0
			e -= 1
			if e <= EXP_MIN:
				e = EXP_MIN
				abs_m = 1.0
				break
	b.mantissa = abs_m if m >= 0.0 else -abs_m
	b.exponent = e
	return b


static func from_float(v: float) -> BigNum:
	return BigNum.make(v, 0)


static func from_int(v: int) -> BigNum:
	return BigNum.make(float(v), 0)


static func zero() -> BigNum:
	return BigNum.new()


## Accepte "1.5", "1,5e30", "1.5E+30", "42", "-3".
static func parse(text: String) -> BigNum:
	var s := text.strip_edges().replace(",", ".")
	if s.is_empty():
		return BigNum.new()
	var e_pos := s.find("e")
	if e_pos == -1:
		e_pos = s.find("E")
	if e_pos != -1:
		var mant_txt := s.substr(0, e_pos)
		var exp_txt := s.substr(e_pos + 1)
		if mant_txt.is_empty() or exp_txt.is_empty():
			return BigNum.new()
		var m := mant_txt.to_float()
		var e := exp_txt.to_float()
		if is_nan(m) or is_nan(e):
			return BigNum.new()
		return BigNum.make(m, int(e))
	return BigNum.make(s.to_float(), 0)


## Format de sauvegarde : tableau à 2 éléments, uniquement des types simples
## (donc sérialisable en JSON comme en binaire).
func serialize() -> Array:
	return [mantissa, exponent]


static func deserialize(data: Variant) -> BigNum:
	if data is Array and (data as Array).size() >= 2:
		return BigNum.make(float(data[0]), int(data[1]))
	if data is float or data is int:
		return BigNum.from_float(float(data))
	if data is String:
		return BigNum.parse(data)
	return BigNum.new()


func copy() -> BigNum:
	var b := BigNum.new()
	b.mantissa = mantissa
	b.exponent = exponent
	return b


# ------------------------------------------------------------------- predicates

func is_zero() -> bool:
	return mantissa == 0.0


func is_negative() -> bool:
	return mantissa < 0.0


func is_finite() -> bool:
	return exponent != EXP_MAX and exponent != EXP_MIN


# ------------------------------------------------------------------ arithmétique

func add(o: BigNum) -> BigNum:
	if o == null or o.is_zero():
		return copy()
	if is_zero():
		return o.copy()
	var hi := self
	var lo := o
	if lo.exponent > hi.exponent:
		hi = o
		lo = self
	var d := hi.exponent - lo.exponent
	if d > PRECISION_DIGITS:
		return hi.copy()
	return BigNum.make(hi.mantissa + lo.mantissa * pow(10.0, -float(d)), hi.exponent)


func sub(o: BigNum) -> BigNum:
	if o == null or o.is_zero():
		return copy()
	if is_zero():
		return BigNum.make(-o.mantissa, o.exponent)
	var hi := self
	var lo := o
	# hi - lo : le terme à retrancher est de signe négatif sauf si l'ordre des
	# exposants nous a fait échanger self et o.
	var sign := -1.0
	if lo.exponent > hi.exponent:
		hi = o
		lo = self
		sign = 1.0
	var d := hi.exponent - lo.exponent
	if d > PRECISION_DIGITS:
		return hi.copy()
	return BigNum.make(hi.mantissa + sign * lo.mantissa * pow(10.0, -float(d)), hi.exponent)


func mul(o: BigNum) -> BigNum:
	if o == null or is_zero() or o.is_zero():
		return BigNum.new()
	return BigNum.make(mantissa * o.mantissa, exponent + o.exponent)


func div(o: BigNum) -> BigNum:
	if o == null or o.is_zero() or is_zero():
		return BigNum.new()
	return BigNum.make(mantissa / o.mantissa, exponent - o.exponent)


func mul_float(f: float) -> BigNum:
	return BigNum.make(mantissa * f, exponent)


func div_float(f: float) -> BigNum:
	if f == 0.0:
		return BigNum.new()
	return BigNum.make(mantissa / f, exponent)


## Élévation à une puissance quelconque : 10^(p * log10(v)).
func powf_num(p: float) -> BigNum:
	if is_zero():
		return BigNum.from_int(1) if p == 0.0 else BigNum.new()
	var l := log10v() * p
	if is_inf(l) or is_nan(l):
		return BigNum.new()
	var e := floori(l)
	return BigNum.make(pow(10.0, l - float(e)), e)


## log10 de la valeur. Volontairement nommée log10v et pas log10 : GDScript
## n'expose pas log10() dans @GlobalScope (uniquement log() et log2()).
func log10v() -> float:
	if is_zero():
		return -INF
	return log(absf(mantissa)) / LN10 + float(exponent)


## Nommée absolute() et non abs() : une méthode abs() masquerait le global abs().
func absolute() -> BigNum:
	if is_negative():
		return BigNum.make(-mantissa, exponent)
	return copy()


# ------------------------------------------------------------------ comparaisons

## -1 si self < o, 0 si égal, 1 si self > o
func cmp(o: BigNum) -> int:
	if o == null:
		o = BigNum.new()
	if is_zero() and o.is_zero():
		return 0
	if is_zero():
		return -1 if o.mantissa > 0.0 else 1
	if o.is_zero():
		return 1 if mantissa > 0.0 else -1
	var self_neg := is_negative()
	var other_neg := o.is_negative()
	if self_neg != other_neg:
		return -1 if self_neg else 1
	var d := exponent - o.exponent
	if d > 0:
		return -1 if self_neg else 1
	if d < 0:
		return 1 if self_neg else -1
	if mantissa == o.mantissa:
		return 0
	return -1 if self_neg else (1 if mantissa > o.mantissa else -1)


func equals(o: BigNum) -> bool:
	return cmp(o) == 0


func gt(o: BigNum) -> bool:
	return cmp(o) > 0


func gte(o: BigNum) -> bool:
	return cmp(o) >= 0


func lt(o: BigNum) -> bool:
	return cmp(o) < 0


func lte(o: BigNum) -> bool:
	return cmp(o) <= 0


# -------------------------------------------------------------------- conversions

func to_float() -> float:
	if is_zero():
		return 0.0
	if exponent > 308:
		return INF if not is_negative() else -INF
	if exponent < -308:
		return 0.0
	return mantissa * pow(10.0, float(exponent))


## Saturé à INT64_MAX : un idle game ne manipule jamais un compteur au-delà, et
## int(inf) est un comportement indéfini en GDScript.
func to_int() -> int:
	if is_zero() or is_negative():
		return 0
	if exponent > 18:
		return 9223372036854775807
	var f := to_float()
	if f >= 9.2e18:
		return 9223372036854775807
	return int(f)


func to_int_string() -> String:
	if is_negative():
		return str(-absolute().to_int())
	return str(to_int())


# ----------------------------------------------------------------------- affichage

## "0", "999", "1.23 K", "12.3 Md", "4.56e120"
func format_short(decimals: int = 2) -> String:
	if is_zero():
		return "0"
	var neg := is_negative()
	var m := absf(mantissa)
	var e := exponent
	var num := ""
	var suffix := ""
	if e < 3:
		if e >= 0:
			var v := m * pow(10.0, float(e))
			# Entier si la valeur l'est vraiment : sinon 0.5/s s'afficherait "1".
			if v < 1e15 and v == floorf(v):
				num = str(int(v))
			else:
				num = _trim(v, decimals)
		else:
			num = _trim(m * pow(10.0, float(e)), decimals)
	else:
		# Un palier couvre 3 ordres de grandeur : la mantisse affichée est dans [1, 1000).
		var tier := int(floor(float(e) / 3.0))
		if tier < SUFFIXES.size():
			m *= pow(10.0, float(e - tier * 3))
			num = _trim(m, decimals)
			# "999.99" arrondi en "1000" : on change de palier ("1 Md", pas "1000 K").
			if num.begins_with("1000"):
				tier += 1
				if tier < SUFFIXES.size():
					num = _trim(m / 1000.0, decimals)
					suffix = SUFFIXES[tier]
				else:
					num = _sci(m / 1000.0, e + 3, decimals)
			else:
				suffix = SUFFIXES[tier]
		else:
			num = _sci(m, e, decimals)
	return ("-" + num) if neg else (num + suffix)


## Nombre décimal sans zéros de fin : 1.20 -> "1.2", 0.50 -> "0.5"
static func _trim(v: float, decimals: int) -> String:
	var s := "%.*f" % [decimals, v]
	if s.contains("."):
		s = s.rstrip("0").rstrip(".")
	return s if not s.is_empty() else "0"


static func _sci(m: float, e: int, decimals: int) -> String:
	return "%se%d" % [_trim(m, decimals), e]


func _to_string() -> String:
	return format_short(6)
