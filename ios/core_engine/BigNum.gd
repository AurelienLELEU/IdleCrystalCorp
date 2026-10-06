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


## Soustraction, écrite comme une addition de l'opposé.
##
## Elle était implémentée à la main, en échangeant `self` et `o` selon leurs
## exposants, et le coefficient du terme de plus grand exposant n'était jamais
## inversé lors de cet échange. Conséquence : `5 - 100000` valait `100005`, et
## tout le domaine des résultats négatifs était faux.
##
## Le domaine n'était pas atteint par le jeu — les trois appelants comparent
## avant de soustraire, donc `self ≥ o`, donc jamais d'échange — ce qui rendait
## le défaut invisible depuis les tests. Il ne l'est plus : `add()` est
## commutative par construction et n'a qu'un seul chemin, sans signe à
## suivre à la main.
func sub(o: BigNum) -> BigNum:
	if o == null:
		return copy()
	return add(o.negated())


## L'opposé. `make()` normalise déjà le signe dans la mantisse, donc il n'y a
## rien à propager à l'exposant.
func negated() -> BigNum:
	return BigNum.make(-mantissa, exponent)


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
	# Exposant identique, donc les deux valeurs sont du même signe. La
	# comparaison des MANTISSES suffit dans les deux cas, et c'est ce qui la rend
	# correcte : pour des positifs, une plus grande mantisse est une plus
	# grande valeur ; pour des négatifs, l'inverse, et la même expression donne
	# le bon résultat par construction.
	#
	# La ligne était `-1 if self_neg else (1 if mantissa > o.mantissa else -1)`,
	# c'est-à-dire un raccourci qui retournait -1 dès que `self` était négatif,
	# SANS regarder la mantisse. `-1000.cmp(-9000)` valait donc -1 : `a.lt(b)`
	# et `b.lt(a)` étaient tous deux vrais, et `gt()` tous deux faux — le
	# contrat d'ordre violé, donc tout `sort()` ou `max()` sur des BigNum
	# négatifs donnait un résultat faux. Les branches `d > 0` / `d < 0`
	# ci-dessus sont, elles, correctes, ce qui explique que le test existant —
	# qui n'utilise que des exposants différents — ne le voyait pas.
	return 1 if mantissa > o.mantissa else -1


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


## Convertit en entier 64 bits, SATURÉ, et ramené à zéro si la valeur est
## négative.
##
## ## L'asymétrie avec `to_float()` est volontaire, et c'est un piège
##
## `to_float()` rend -7 pour une valeur de -7. `to_int()` rend **0**. Ce n'est
## pas une saturation, c'est une politique : une grandeur de jeu — un compteur,
## un solde — n'est jamais négative, et une conversion qui rendrait une valeur
## fausse n'est pas une conversion.
##
## Le piège est que les deux fonctions portent le même nom qu'un seul mot de
## différence. `sub()` rend maintenant un résultat négatif CORRECT (il rendait
## `+99995` pour `5 - 100000` avant d'être réécrit en `add(o.negated())`), donc
## un appelant futur pourrait écrire `a.sub(b).to_int()` et lire 0 sans
## comprendre pourquoi. La saturation positive, elle, est un vrai débordement
## d'entier et vaut INT64_MAX.
##
## `to_int()` n'a aucun appelant dans le jeu ; `tests/test_bignum.gd` verrouille
## les deux comportements pour qu'un changement ultérieur soit délibéré.
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
	# Le suffixe d'échelle va avec le NOMBRE, pas seulement avec le signe
	# positif. La ligne rendait `("-" + num)` dans le cas négatif et oubliait
	# `suffix` : `-1.5e6` s'affichait « -1.5 » au lieu de « -1.5 M ». Ce n'est
	# pas cosmétique — trois ordres de grandeur disparaissent, et un joueur qui
	# lit un solde négatif lit un nombre faux.
	return ("-" + num + suffix) if neg else (num + suffix)


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
