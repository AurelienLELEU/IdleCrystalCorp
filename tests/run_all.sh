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
	"test_bignum|Nombres et formatage (BigNum)"
	"test_game|Logique de jeu, sauvegarde, hors-ligne, ascension"
	"test_ui_compile|Construction de la scène principale"
	"test_ui_interaction|Interaction réelle de l'interface"
)

total_fail=0
total_checks=0
typeset -a SUMMARY

for entry in $SUITES; do
	name="${entry%%|*}"
	label="${entry#*|}"
	echo ""
	echo "──────────────────────────────────────────────────────────────"
	echo "  $name — $label"
	echo "──────────────────────────────────────────────────────────────"

	log="$(mktemp)"
	if ./tests/run.sh "res://tests/$name.gd" 120 >"$log" 2>&1; then
		grep -vE '^(Godot Engine|$)' "$log"
		checks="$(grep -cE '^  ok ' "$log")"
		total_checks=$((total_checks + checks))
		SUMMARY+=("  OK      ${checks} vérifications   $name")
	else
		grep -vE '^(Godot Engine|$)' "$log"
		total_fail=$((total_fail + 1))
		SUMMARY+=("  ECHEC   $(grep -cE '^  ok ' "$log") vérifications   $name")
	fi
	rm -f "$log"
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
