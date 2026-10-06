#!/bin/zsh
# Lance un script de test Godot sans affichage, avec un garde-fou temporel.
#
#   ./tests/run.sh res://tests/test_bignum.gd
#
# Pourquoi le timeout : si le script échoue au chargement, Godot ne quit() jamais
# et lance la scène principale en boucle silencieuse. Le wrapper coupe et
# signale l'échec au lieu de laisser le process tourner indéfiniment.

set -u
GODOT="${GODOT:-/Users/admin/Downloads/Godot.app/Contents/MacOS/Godot}"
SCRIPT="${1:?usage: run.sh res://tests/test_xxx.gd [timeout_s]}"
LIMIT="${2:-120}"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"

TMP="$(mktemp)"
"$GODOT" --headless --path "$PROJECT" --script "$SCRIPT" >"$TMP" 2>&1 &
PID=$!

ELAPSED=0
while kill -0 "$PID" 2>/dev/null; do
	sleep 1
	ELAPSED=$((ELAPSED + 1))
	if [ "$ELAPSED" -ge "$LIMIT" ]; then
		kill -9 "$PID" 2>/dev/null
		pkill -9 -f "Godot --headless" 2>/dev/null
		echo "TIMEOUT après ${LIMIT}s : le script n'a pas appelé quit() (échec de compilation ?)"
		cat "$TMP"
		rm -f "$TMP"
		exit 2
	fi
done
wait "$PID"
CODE=$?
cat "$TMP"
rm -f "$TMP"

if [ "$CODE" -ne 0 ]; then
	echo "EXIT=$CODE"
fi
exit "$CODE"
