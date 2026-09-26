#!/bin/zsh
# Lance toutes les suites de tests et resume le résultat.
#
#   ./tests/run_all.sh
#
# Chaque suite tourne dans son propre process Godot : c'est plus lent, mais cela
# évite qu'un état laissé par un test (fichier de sauvegarde, autoload modifié)
# ne fausse le suivant. Un seul process qui échoue ne doit pas être masqué par
# les 127 vérifications du suivant.
#
# Le code de sortie reflète la santé globale, ce qui permet de l'utiliser en
# intégration continue : `tests/run_all.sh || exit 1`.

set -u
cd "$(dirname "$0")/.."

SUITES=(
	"test_bignum|Nombres et formatage (BigNum)|161"
	"test_game|Logique de jeu, sauvegarde, hors-ligne, ascension|155"
	"test_offline_persistence|Quitter l'app : gains, quarantaine, retour au premier plan|29"
	"test_save_codec|Intégrité du format de sauvegarde (CRC, longueur, contrat)|57"
	"test_ui_compile|Construction de la scène principale|19"
	"test_ui_interaction|Interaction réelle de l'interface|88"
	"test_background|Fond animé, progression et achats|12"
	"test_plugin_contract|Contrat entre le jeu et les extensions natives|52"
	"test_ads_economy|Plafonds quotidiens, budget commun, fenêtre de pub|34"
	"test_native_load|Chargement réel des extensions compilées|19"
	"test_safe_area|Zone sûre, centrage, combo et débordement de la popup|90"
)

# Le nombre de vérifications ATTENDU par suite, dans la table ci-dessus.
#
# Pourquoi le compter, alors qu'un résumé « N vérifications, 0 échec » semble
# suffire : parce qu'un test GDScript qui avorte en silence est VERT. Un
# `call()` sur une méthode supprimée, un `await` oublié, une propriété
# manquante — rien de tout cela ne lève d'échec, la suite perd des
# vérifications en route et annonce quand même « 0 échec ». C'est arrivé pour
# de vrai : `test_ui_interaction` perdait quatre vérifications et annonçait
# 73 au lieu de 77.
#
# Un écart de compte est donc un échec, avec cette explication, et non un
# chiffre que le lecteur doit remarquer lui-même. Le prix est qu'ajouter une
# vérification oblige à mettre ce nombre à jour : c'est le prix à payer, et
# l'oubli se voit immédiatement.

total_fail=0
total_checks=0
typeset -a SUMMARY

# --- Frontière native, hors Godot ------------------------------------------
#
# Ce contrôle ne lance pas Godot : il vérifie que les en-têtes C, les .mm, le
# Swift et les .cpp racontent la même histoire. Une dérive de signature entre
# deux de ces fichiers se comporte très bien à l'édition, se comporte bien à
# l'export, et plante à la première pub sur l'appareil — sans message d'erreur
# qui pointe vers la cause. Il vérifie aussi que les chemins du manifeste
# .gdextension suivent la règle de suffixe de godot-cpp, et que la liste
# d'interface de test_native_load.gd n'a pas dérivé des .cpp.
echo ""
echo "──────────────────────────────────────────────────────────────"
echo "  check_native_contract — frontières C / C++ / Objective-C++ / Swift"
echo "──────────────────────────────────────────────────────────────"
if native_log="$(python3 tests/check_native_contract.py 2>&1)"; then
	echo "$native_log"
	native_checks="$(printf '%s' "$native_log" | sed -nE 's/.*: ([0-9]+) vérifications.*/\1/p')"
	total_checks=$((total_checks + ${native_checks:-0}))
	SUMMARY+=("  OK      ${native_checks:-?} vérifications   check_native_contract.py")
else
	echo "$native_log"
	total_fail=$((total_fail + 1))
	SUMMARY+=("  ECHEC   0 vérifications   check_native_contract.py")
fi

for entry in $SUITES; do
	name="${entry%%|*}"
	rest="${entry#*|}"
	label="${rest%%|*}"
	expected="${rest##*|}"
	echo ""
	echo "──────────────────────────────────────────────────────────────"
	echo "  $name — $label"
	echo "──────────────────────────────────────────────────────────────"

	log="$(mktemp)"
	suite_status=0
	if ! ./tests/run.sh "res://tests/$name.gd" 120 >"$log" 2>&1; then
		suite_status=1
	fi
	grep -vE '^(Godot Engine|$)' "$log"
	checks="$(grep -cE '^  ok ' "$log")"
	total_checks=$((total_checks + checks))
	rm -f "$log"

	if [ "$checks" != "$expected" ]; then
		echo ""
		echo "  ATTENTION : $name a exécuté $checks vérifications, $expected attendues."
		echo "  Une suite qui avorte en silence est verte : le compte ci-dessus"
		echo "  est le seul indice. Soit un contrôle s'est perdu, soit la table"
		echo "  SUITES de tests/run_all.sh n'a pas été mise à jour."
		suite_status=1
	fi

	if [ "$suite_status" -eq 0 ]; then
		SUMMARY+=("  OK      ${checks} vérifications   $name")
	else
		total_fail=$((total_fail + 1))
		SUMMARY+=("  ECHEC   ${checks}/${expected} vérifications   $name")
	fi
done

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Récapitulatif"
echo "══════════════════════════════════════════════════════════════"
for line in $SUMMARY; do
	echo "$line"
done
echo ""

if [ "$total_fail" -ne 0 ]; then
	echo "  $total_fail suite(s) en échec."
	exit 1
fi
echo "  $total_checks vérifications, 0 échec."
