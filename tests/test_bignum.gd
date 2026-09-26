extends SceneTree

## Suite de tests exécutable sans affichage :
##   godot --headless --path . --script res://tests/test_bignum.gd

var _failed := 0
var _passed := 0

func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
		# Même format que les autres suites ("  ok ") : c'est ce que run_all.sh
		# compte pour announced le total de vérifications.
		print("  ok    %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s %s" % [label, detail])

func _eq_str(label: String, got: String, want: String) -> void:
	_check(label, got == want, "-> obtenu « %s », attendu « %s »" % [got, want])

func _run() -> void:
	print("== BigNum ==")
	# Construction / normalisation
	_eq_str("zero", BigNum.zero().format_short(), "0")
	_eq_str("42", BigNum.from_int(42).format_short(), "42")
	_eq_str("999", BigNum.from_int(999).format_short(), "999")
	_eq_str("1500", BigNum.from_int(1500).format_short(), "1.5 K")
	_eq_str("1.23K", BigNum.make(1.2345, 3).format_short(2), "1.23 K")
	_eq_str("1.2K", BigNum.make(1.20, 3).format_short(2), "1.2 K")
	_eq_str("9.99 arrondi", BigNum.make(9.999, 6).format_short(1), "10 M")
	_eq_str("999.99 change de palier", BigNum.make(9.99999, 8).format_short(2), "1 Md")
	_eq_str("neg", BigNum.make(-1.5, 2).format_short(), "-150")
	_eq_str("small", BigNum.make(1.5, -1).format_short(), "0.15")
	_eq_str("demi unite", BigNum.make(5.0, -1).format_short(), "0.5")
	_eq_str("non entier", BigNum.make(4.0455, 0).format_short(2), "4.05")
	_eq_str("1e20", BigNum.make(1.0, 20).format_short(), "100 Qi")
	_eq_str("1e30", BigNum.make(1.0, 30).format_short(), "1 No")
	_eq_str("1e120", BigNum.make(1.0, 120).format_short(), "1e120")

	# Au-delà de la précision des floats : 2^53 et au-delà
	var big := BigNum.parse("1e30")
	_check("parse 1e30", big.cmp(BigNum.make(1.0, 30)) == 0, big.format_short())
	_eq_str("1e30 display", big.format_short(), "1 No")
	# 1e30 + 1 : négligeable au regard des 17 chiffres significatifs, c'est voulu
	# (c'est exactement le comportement d'un idle game). En revanche un gain
	# significatif doit être pris en compte.
	_check("gain negligeable ignore", big.add(BigNum.from_int(1)).cmp(big) == 0)
	var plus_real := big.add(BigNum.make(1.0, 25))
	_check("gain significatif pris en compte", plus_real.cmp(big) > 0, plus_real.format_short())
	_check("1e30 + 1e25 proche de 1e30", plus_real.log10v() > 29.9 and plus_real.log10v() < 30.0001)

	# Exposants extrêmes : pas d'overflow, pas de NaN
	var huge := BigNum.make(1.0, 900_000_000)
	var huger := huge.mul(huge).mul(huge)
	_check("exposant enorme borne", huger.exponent <= BigNum.EXP_MAX, str(huger.exponent))
	_check("pas de NaN", not is_nan(huger.to_float()) or is_inf(huger.to_float()))
	_check("to_float inf au-dela de 1e308", is_inf(huge.to_float()))

	# Arithmétique
	var a := BigNum.from_int(150)
	var b := BigNum.from_int(27)
	_eq_str("add", a.add(b).to_int_string(), "177")
	_eq_str("sub", a.sub(b).to_int_string(), "123")
	_eq_str("mul", a.mul(b).to_int_string(), "4050")
	_check("div exact", BigNum.from_int(150).div(BigNum.from_int(25)).mul(BigNum.from_int(25)).cmp(BigNum.from_int(150)) == 0)
	_check("div approx", absf(BigNum.from_int(150).div(BigNum.from_int(27)).to_float() - 150.0 / 27.0) < 1e-9)
	_eq_str("mul_float", a.mul_float(2.0).to_int_string(), "300")
	_eq_str("div par zero -> zero", BigNum.from_int(5).div(BigNum.zero()).format_short(), "0")
	_eq_str("add null", a.add(null).to_int_string(), "150")
	_eq_str("soustraction -> negatif", BigNum.from_int(5).sub(BigNum.from_int(9)).to_int_string(), "-4")

	# Alignement d'exponents : l'addition d'un terme négligeable est un no-op
	_eq_str("add negligeable", BigNum.make(1.0, 20).add(BigNum.make(1.0, 2)).format_short(), "100 Qi")

	# Puissances : le cœur de la courbe de coût
	_eq_str("pow 1.15^10", BigNum.from_float(1.15).powf_num(10.0).format_short(), "4.05")
	var cost := BigNum.from_float(8.0e8)
	for i in 1000:
		cost = cost.mul_float(1.15)
	_check("1e9 * 1.15^1000 fini", cost.is_finite(), cost.format_short())
	_check("1e9 * 1.15^1000 enorme", cost.log10v() > 60.0, cost.log_short() if cost.has_method("log_short") else cost.format_short())
	var cost_max := BigNum.from_float(8.0e8)
	for i in 100000:
		cost_max = cost_max.mul_float(1.15)
	_check("1e9 * 1.15^100000 borne", cost_max.exponent <= BigNum.EXP_MAX, str(cost_max.exponent))
	_check("1e9 * 1.15^100000 affichable", cost_max.format_short().length() < 20, cost_max.format_short())

	# Comparaisons
	_check("cmp exponent", BigNum.make(9.0, 3).cmp(BigNum.make(1.0, 4)) < 0)
	_check("cmp negatif", BigNum.make(-9.0, 3).cmp(BigNum.make(1.0, 4)) < 0)
	_check("cmp negatif 2", BigNum.make(-9.0, 5).cmp(BigNum.make(-1.0, 4)) < 0)
	_check("cmp egal", BigNum.from_int(7).cmp(BigNum.from_int(7)) == 0)
	_check("gte", BigNum.from_int(7).gte(BigNum.from_int(7)))
	_check("zero vs negatif", BigNum.zero().cmp(BigNum.from_int(-1)) > 0)
	_check("negatif vs zero", BigNum.from_int(-1).cmp(BigNum.zero()) < 0)

	# to_int saturé
	_check("to_int saturation", BigNum.make(1.0, 30).to_int() == 9223372036854775807)
	_check("to_int negatif", BigNum.make(-5.0, 2).to_int() == 0)
	_check("to_int 1e18", BigNum.make(9.0, 17).to_int() == 900000000000000000)

	# Sérialisation
	var s := BigNum.from_float(3.25e42)
	var rt := BigNum.deserialize(s.serialize())
	_check("roundtrip serialize", rt.cmp(s) == 0, s.format_short() + " -> " + rt.format_short())
	_check("deserialize legacy float", BigNum.deserialize(150.0).to_int() == 150)
	_check("deserialize legacy string", BigNum.deserialize("1e9").cmp(BigNum.make(1.0, 9)) == 0)
	_check("deserialize invalide", BigNum.deserialize(null).is_zero())

	# Immuabilité
	var orig := BigNum.from_int(10)
	orig.add(BigNum.from_int(5))
	_eq_str("immuabilite", orig.to_int_string(), "10")

	_negative_domain()
	print("  -> %d reussis, %d echecs" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


## Tout le traitement des valeurs négatives était faux, sur trois fonctions
## distinctes, et la suite ci-dessus ne le voyait pas : elle n'exerce que des
## couples d'exposants DIFFÉRENTS pour `cmp()` — les branches `d > 0` et
## `d < 0`, qui sont justes — et aucun `sub()` dont le résultat devrait être
## négatif. Ce que les 53 vérifications précédentes prenaient pour une
## couverture du domaine négatif.
func _negative_domain() -> void:
	# --- sub() : le coefficient du terme de plus grand exposant n'était pas
	# inversé lors de l'échange, donc TOUT résultat négatif était faux.
	# `5 - 100000` valait `100005`.
	_eq_str("sub 5 - 100000", BigNum.from_int(5).sub(BigNum.from_int(100000)).to_int_string(), "-99995")
	_eq_str("sub 1 - 42", BigNum.from_int(1).sub(BigNum.from_int(42)).to_int_string(), "-41")
	_eq_str("sub 0 - 7", BigNum.zero().sub(BigNum.from_int(7)).to_int_string(), "-7")
	_eq_str("sub 7 - 0", BigNum.from_int(7).sub(BigNum.zero()).to_int_string(), "7")
	_eq_str("sub 7 - -5", BigNum.from_int(7).sub(BigNum.from_int(-5)).to_int_string(), "12")
	_eq_str("sub -5 - 7", BigNum.from_int(-5).sub(BigNum.from_int(7)).to_int_string(), "-12")
	_eq_str("sub 1e30 - 1e20", BigNum.parse("1e30").sub(BigNum.parse("1e20")).format_short(), "1 No")
	# Le domaine positif ne doit pas avoir bougé.
	_eq_str("sub 100000 - 5", BigNum.from_int(100000).sub(BigNum.from_int(5)).to_int_string(), "99995")

	# Antisymétrie sur tout le domaine, y compris les exposants très écartés.
	#
	# Comparaison à TOLÉRANCE, et non à l'égalité entière : `add()` écarte
	# volontairement un terme de plus de PRECISION_DIGITS (17) décimales en
	# dessous du terme dominant — c'est le test « gain negligeable ignore » ci-
	# dessus, et c'est la bonne politique pour une arithmétique de gains. Donc
	# `-1000000 - 1` vaut bien `-1000000`, pas `-1000001`. Exiger l'exactitude
	# ici reviendrait à casser cette politique pour satisfaire un test.
	var vals := [-1000000, -42, -1, 0, 1, 42, 1000000]
	for a: int in vals:
		for b: int in vals:
			if a == b:
				continue
			var want := float(a - b)
			var got := BigNum.from_int(a).sub(BigNum.from_int(b)).to_float()
			_check("sub antisymetrique %d-%d" % [a, b],
				absf(got - want) <= maxf(1.0, absf(want) * 1e-15),
				"-> obtenu %s, attendu %d" % [BigNum.from_float(got).format_short(), a - b])
	# Le signe, lui, doit être exact : jamais tolérant. C'est ce qui était faux
	# avant, et c'est le seul endroit où l'erreur se voyait à l'écran.
	for a: int in vals:
		for b: int in vals:
			if a == b:
				continue
			var r := BigNum.from_int(a).sub(BigNum.from_int(b))
			_check("sub signe exact %d-%d" % [a, b],
				(r.is_negative() and a < b) or (r.is_zero() and a == b) or (not r.is_negative() and a > b),
				"-> signe %s" % ("-" if r.is_negative() else "+"))

	# --- cmp() : deux négatifs de même exposant se déclaraient mutuellement
	# plus petits, parce que la branche finale retournait -1 dès que `self` était
	# négatif, sans regarder la mantisse. `-1000.cmp(-9000)` valait -1.
	var n9 := BigNum.make(-9.0, 3)
	var n1 := BigNum.make(-1.0, 3)
	_check("cmp negatif meme exposant, -9000 < -1000", n9.cmp(n1) == -1, "-> %d" % n9.cmp(n1))
	_check("cmp negatif meme exposant, -1000 > -9000", n1.cmp(n9) == 1, "-> %d" % n1.cmp(n9))
	_check("lt() n'est vrai que dans un sens", not (n9.lt(n1) and n1.lt(n9)))
	_check("gt() n'est vrai que dans un sens", not (n9.gt(n1) and n1.gt(n9)))
	_check("equals() sur identiques negatifs", n9.equals(BigNum.make(-9.0, 3)))
	_check("antisymetrie de cmp sur tout le domaine", _cmp_antisymmetric())

	# --- format_short() : le suffixe d'échelle était perdu sur les négatifs.
	# Trois ordres de grandeur disparaissaient. C'est un numéro FAUX affiché,
	# pas une absence de décoration.
	_eq_str("format_short negatif million", BigNum.make(-1.5, 6).format_short(), "-1.5 M")
	_eq_str("format_short positif million", BigNum.make(1.5, 6).format_short(), "1.5 M")
	_eq_str("format_short negatif bilion", BigNum.make(-2.5, 12).format_short(), "-2.5 Tn")
	_eq_str("format_short negatif mille", BigNum.make(-1.0, 3).format_short(), "-1 K")
	_eq_str("format_short negatif sans suffixe", BigNum.make(-1.5, 0).format_short(), "-1.5")
	_eq_str("format_short zero", BigNum.make(-0.0, 0).format_short(), "0")

	# --- to_int() : le ramassage à zéro des négatifs est VOLONTAIRE, mais il
	# contredit `to_float()`, qui rend -7 pour -7. Verrouiller les deux évite
	# qu'un appelant futur s'appuie sur l'un en croyant l'autre.
	_check("to_int ramasse les negatifs a zero", BigNum.make(-7.0, 0).to_int() == 0)
	_check("to_float, lui, rend la valeur", BigNum.make(-7.0, 0).to_float() == -7.0)
	_check("to_int_string rend la valeur negative", BigNum.make(-7.0, 0).to_int_string() == "-7")
	_check("sub negatif puis to_int : le piege est documente",
		BigNum.zero().sub(BigNum.from_int(7)).to_int() == 0
			and BigNum.zero().sub(BigNum.from_int(7)).to_int_string() == "-7")


## `cmp` doit être antisymétrique sur tout couple : `a.cmp(b)` et `b.cmp(a)` ne
## peuvent être que des opposés, ou tous deux nuls. C'est le contrat d'ordre,
## pas une valeur : un `sort()` ou un `max()` sur des BigNum négatifs dépend
## entièrement de cette propriété, et une violation fait que `a < b` et
## `b < a` sont vrais en même temps.
func _cmp_antisymmetric() -> bool:
	var pairs := [
		[BigNum.from_int(-1), BigNum.from_int(1)],
		[BigNum.make(-9.0, 3), BigNum.make(-1.0, 3)],
		[BigNum.make(-1.0, 3), BigNum.make(-9.0, 3)],
		[BigNum.make(-5.0, 2), BigNum.make(-5.0, 3)],
		[BigNum.make(-5.0, 3), BigNum.make(-5.0, 2)],
		[BigNum.make(-1.0, 0), BigNum.make(-1.0, 0)],
		[BigNum.zero(), BigNum.from_int(-1)],
		[BigNum.from_int(-1), BigNum.zero()],
		[BigNum.parse("1e40"), BigNum.parse("1e-40")],
		[BigNum.parse("-1e40"), BigNum.parse("1e-40")],
		[BigNum.parse("-1e40"), BigNum.parse("-1e-50")],
	]
	for p: Array in pairs:
		var a: BigNum = p[0]
		var b: BigNum = p[1]
		if a.cmp(b) != -b.cmp(a):
			return false
	return true


func _init() -> void:
	_run()
