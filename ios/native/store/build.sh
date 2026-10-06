#!/bin/zsh
# Compile l'extension native « IdleStore » (StoreKit 2).
#
#   native/store/build.sh                # macOS + iOS
#   native/store/build.sh ios
#   GODOT_CPP=/chemin/godot-cpp native/store/build.sh
#
# Prérequis :
#
#   brew install scons
#   git clone -b master https://github.com/godotengine/godot-cpp native/store/godot-cpp
#
#   Xcode COMPLET, pas seulement les Command Line Tools. StoreKit 2 n'existe
#   pas dans les CLT, et swiftc n'y est que partiellement présent :
#     xcode-select --install          # ne suffit PAS
#     sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
#
# Sans cette extension, le jeu fonctionne quand même : StoreService bascule sur
# sa boutique simulée, ce qui est le mode par défaut sur ordinateur.
#
# Les binaires produits sont dans native/store/bin/ et sont ignorés par git.

set -eu
cd "$(dirname "$0")"

GODOT_CPP="${GODOT_CPP:-$PWD/godot-cpp}"
TARGETS="${*:-macos ios}"

if ! command -v scons >/dev/null 2>&1; then
	echo "scons absent : brew install scons" >&2
	exit 1
fi
if [ ! -d "$GODOT_CPP" ]; then
	echo "godot-cpp absent dans $GODOT_CPP" >&2
	echo "  git clone -b master https://github.com/godotengine/godot-cpp $GODOT_CPP" >&2
	exit 1
fi
# --- Version de l'API GDExtension ------------------------------------------
# Elle doit correspondre exactement au moteur : une extension compilée contre
# une autre version est refusée au chargement. La lire dans project.godot
# plutôt que de la coder en dur ici ferme le seul piège silencieux du bâtiment
# natif — un « 4.6 » oublié ne produit aucune erreur, ici, ni à la
# compilation ; il se voit au premier lancement sur l'appareil.
# Remonter jusqu'au project.godot plutôt que coder un « ../../ » : le nombre
# de niveaux dépend de l'arborescence de chacun, et un chemin faux échouerait
# ici, ce qui est mieux que silencieusement.
_project_dir="$PWD"
while [ "$_project_dir" != "/" ] && [ ! -f "$_project_dir/project.godot" ]; do
	_project_dir="${_project_dir:h}"
done
GODOT_API_VERSION="${GODOT_API_VERSION:-$(sed -nE 's/^config\/features=PackedStringArray\("([0-9]+(\.[0-9]+)*)".*/\1/p' "$_project_dir/project.godot" | head -1)}"
if [ -z "$GODOT_API_VERSION" ]; then
	echo "version du moteur introuvable : aucun project.godot lisible depuis $PWD" >&2
	exit 1
fi
export GODOT_API_VERSION

_api_json="$GODOT_CPP/gdextension/extension_api-$(print -r -- "$GODOT_API_VERSION" | tr '.' '-').json"
if [ ! -f "$_api_json" ]; then
	echo "godot-cpp ne fournit pas l'API $GODOT_API_VERSION." >&2
	echo "  Attendu : $_api_json" >&2
	echo "  Versions disponibles dans votre godot-cpp :" >&2
	for f in "$GODOT_CPP"/gdextension/extension_api-*.json(N); do
		echo "    ${${f:t}%.json}" >&2
	done
	echo "  Si la bonne y est, mettez à jour godot-cpp (git -C $GODOT_CPP pull)," >&2
	echo "  ou compilez contre l'API exacte du moteur local :" >&2
	echo "    godot --headless --dump-extension-api && scons custom_api_file=extension_api.json" >&2
	exit 1
fi
echo "API GDExtension $GODOT_API_VERSION (${_api_json:t})"

if ! command -v swiftc >/dev/null 2>&1; then
	echo "swiftc absent : installez Xcode complet (pas seulement les CLT)." >&2
	exit 1
fi

build() {
	local platform="$1" target="$2" arch="$3" swift_target="$4" extra=("${@:5}")
	local log="$PWD/build-$(print -r -- "$platform-$arch" | tr '/' '_').log"

	echo "── $platform / $arch ($swift_target)"
	scons -C "$PWD" platform="$platform" target="$target" arch="$arch" \
		api_version="$GODOT_API_VERSION" \
		swift_target="$swift_target" "${extra[@]}" 2>&1 | tee "$log"
	# Voir native/ads/build.sh : le statut d'un pipeline est celui de `tee`.
	# `pipestatus` doit être CAPTURÉ immédiatement. La commande `[` qui suit
	# réécrit déjà `pipestatus`, si bien qu'un test naïf lit le statut de son
	# propre test — et conclut qu'un build cassé a réussi, ou l'inverse.
	local rc="${pipestatus[1]}"
	if [ "$rc" -eq 0 ]; then
		return 0
	fi
	echo "   échec (scons a rendu $rc) — journal : $log" >&2
	return 1
}

mkdir -p bin
# Voir native/ads/build.sh : le manifeste n'est activé qu'après un build
# complet, sinon Godot hurle au démarrage sur une bibliothèque absente.
DIST="IdleStore.gdextension.dist"
ACTIVE="IdleStore.gdextension"
deactivate() {
	# `rm`, et surtout pas `mv $ACTIVE $DIST`. Le manifeste « actif » était
	# une COPIE de la version du dépôt ; le rapatrier ainsi détruisait la source
	# de vérité à chaque build. Concrètement : corriger les chemins de
	# bibliothèques du .dist, relancer le build, et le build remettait l'ancien
	# contenu par-dessus. La correction disparaissait sans laisser de trace,
	# et l'extension continuait de ne pas se charger.
	rm -f "$ACTIVE"
	return 0
}
trap deactivate EXIT INT TERM
deactivate

fail=0

for t in ${(z)TARGETS}; do
	case "$t" in
		macos)
			build macos template_debug   "" arm64-apple-macos13.0 SDKROOT=macosx
			build macos template_release "" arm64-apple-macos13.0 SDKROOT=macosx
			;;
		ios)
			# iOS 15 minimum : c'est la version qui a introduit StoreKit 2.
			# Les arches suivent la même règle que native/ads/build.sh :
			# « arm64-simulator » n'est pas une valeur d'arch acceptée par
			# godot-cpp, et le simulateur se demande par ios_simulator=yes.
			build ios template_debug   arm64     arm64-apple-ios15.0 SDKROOT=iphoneos        ios_simulator=no ios_min_version=15.0
			build ios template_release arm64     arm64-apple-ios15.0 SDKROOT=iphoneos        ios_simulator=no ios_min_version=15.0
			build ios template_debug   universal arm64-apple-ios15.0-simulator SDKROOT=iphonesimulator ios_simulator=yes ios_min_version=15.0
			build ios template_release universal arm64-apple-ios15.0-simulator SDKROOT=iphonesimulator ios_simulator=yes ios_min_version=15.0
			;;
		*)
			echo "cible inconnue : $t" >&2
			fail=1
			;;
	esac
done

if [ "$fail" -ne 0 ]; then
	deactivate
	echo
	echo "Aucun manifeste activé : le jeu reste sur sa boutique simulée." >&2
	exit 1
fi

cp "$DIST" "$ACTIVE"
trap - EXIT INT TERM

echo
echo "Binaires produits :"
ls -1 bin/ 2>/dev/null || echo "  (aucun)"
echo
echo "Manifeste activé : $ACTIVE"
