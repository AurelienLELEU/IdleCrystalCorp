#!/bin/zsh
# Compile l'extension native « IdleAds » (Google AdMob).
#
#   native/ads/build.sh                # macOS + iOS
#   native/ads/build.sh macos          # seulement macOS
#   GODOT_CPP=/chemin/godot-cpp native/ads/build.sh
#
# Prérequis (ce projet ne les installe pas pour vous : ils pèsent plusieurs Go) :
#
#   brew install scons
#   git clone -b master https://github.com/godotengine/godot-cpp native/ads/godot-cpp
#   # ou : GODOT_CPP=/chemin/vers/godot-cpp native/ads/build.sh
#
#   Xcode complet, pas seulement les Command Line Tools :
#   xcode-select --install     # ne suffit PAS
#   # Téléchargez Xcode depuis l'App Store, puis :
#   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
#
# SDK AdMob : voir ADS_SDK ci-dessous. Sans lui, compilez avec NO_SDK=1, ce qui
# produit une extension qui ne fait rien — le jeu bascule alors sur son
# simulateur intégré, ce qui est utile pour valider le reste.
#
# Les binaires produits sont dans native/ads/bin/ et sont ignorés par git : ce
# sont des artefacts, dépendants de la version du SDK et de l'API Godot.

set -eu
cd "$(dirname "$0")"

GODOT_CPP="${GODOT_CPP:-$PWD/godot-cpp}"
TARGETS="${*:-macos ios}"
NO_SDK="${NO_SDK:-0}"

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

# --- SDK AdMob -------------------------------------------------------------
# Emplacement de GoogleMobileAds.framework, soit par variable, soit par
# détection dans les répertoires habituels des pods CocoaPods / Carthage.
## Le qualificatif `(N)` sur le dernier glob n'est pas décoratif : en zsh, un
## glob sans correspondance est une ERREUR, pas une liste vide. Sans lui, le
## simple fait de ne pas encore avoir de DerivedData interrompait le script
## avant même qu'il cherche le SDK, avec un message qui ne parle pas de la
## cause réelle.
find_admob_framework() {
	local candidate
	if [ -n "${ADS_SDK:-}" ]; then
		printf '%s' "$ADS_SDK"
		return
	fi
	for candidate in \
		"$PWD/Pods/GoogleMobileAds" \
		"$PWD/../pods" \
		"$HOME/Library/Developer/Xcode/DerivedData/GoogleMobileAds"*(N); do
		if [ -d "$candidate" ]; then
			printf '%s' "$candidate"
			return
		fi
	done
	printf '%s' ""
}

# --- Construit une cible ---------------------------------------------------
build() {
	local platform="$1" target="$2" arch="$3" extra=("${@:4}")
	local log="$PWD/build-$(print -r -- "$platform-$arch" | tr '/' '_').log"

	echo "── $platform / $arch"
	scons -C "$PWD" platform="$platform" target="$target" arch="$arch" \
		api_version="$GODOT_API_VERSION" \
		google_mobile_ads_path="$ADMOB_DIR" "${extra[@]}" 2>&1 | tee "$log"
	# Le statut d'un pipeline est celui de sa DERNIÈRE commande, donc de `tee`,
	# qui réussit toujours. Tester `if scons | tee` revenait donc à déclarer tout
	# build réussi : le compteur d'échecs restait à zéro, et le manifeste
	# s'activait après une compilation cassée — exactement ce que le `trap`
	# placé plus bas prétend empêcher. D'où le test explicite sur pipestatus.
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

ADMOB_DIR="$(find_admob_framework)"
if [ "$NO_SDK" = "1" ]; then
	ADMOB_DIR=""
	echo "NO_SDK=1 : extension sans AdMob, le jeu utilisera son simulateur."
elif [ -z "$ADMOB_DIR" ]; then
	echo "GoogleMobileAds.framework introuvable." >&2
	echo "  export ADS_SDK=/chemin/vers/GoogleMobileAds" >&2
	echo "  (ou compilez avec NO_SDK=1 pour valider le reste du jeu)" >&2
	exit 1
else
	echo "SDK AdMob : $ADMOB_DIR"
fi

mkdir -p bin
# Le manifeste .dist n'est activé qu'après un build réussi : jusque-là, Godot
# chargerait une .gdextension pointant sur un binaire absent, et quatre lignes
# d'erreur de dlopen masqueraient tout vrai problème au démarrage.
DIST="IdleAds.gdextension.dist"
ACTIVE="IdleAds.gdextension"
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
			build macos template_debug   ""     || fail=1
			build macos template_release ""     || fail=1
			;;
		ios)
			# Appareil réel. -sdk iphoneos.
			build ios template_debug   arm64 SDKROOT=iphoneos ios_simulator=no || fail=1
			build ios template_release arm64 SDKROOT=iphoneos ios_simulator=no || fail=1
			# Simulateur. godot-cpp ne connaît pas « arm64-simulator » comme
			# arch : les valeurs valides sont '', universal, x86_64, arm64,
			# arm32, rv64, wasm32. Le simulateur se demande par le booléen
			# ios_simulator, et « universal » produit un binaire qui tourne
			# sur Apple Silicon ET sur Intel. Les anciennes valeurs
			# « arm64-simulator » / « x86_64-simulator » ne sont pas des
			# erreurs d'avertissement : scons sort en erreur avant même de
			# regarder une seule ligne de notre code.
			build ios template_debug   universal SDKROOT=iphonesimulator ios_simulator=yes || fail=1
			build ios template_release universal SDKROOT=iphonesimulator ios_simulator=yes || fail=1
			;;
		*)
			echo "cible inconnue : $t" >&2
			fail=1
			;;
	esac
done

if [ "$fail" -ne 0 ]; then
	echo
	echo "Au moins une cible a échoué." >&2
	exit 1
fi

if [ "$fail" -ne 0 ]; then
	deactivate
	echo
	echo "Aucun manifeste activé : le jeu reste sur son simulateur." >&2
	exit 1
fi

# Tous les binaires attendus sont là : on active le manifeste pour de bon.
cp "$DIST" "$ACTIVE"
trap - EXIT INT TERM

echo
echo "Binaires produits :"
# `$PWD` vaut native/ads/, et le SConstruct écrit dans le `bin/`
# d'à côté : c'est ce chemin-là que le manifeste annonce.
ls -1 bin/ 2>/dev/null || echo "  (aucun)"
echo
echo "Manifeste activé : $ACTIVE"
echo "Vérifiez que bin/ est importé (l'icône en tête de liste), sinon Godot"
echo "copiera l'extension dans le .ipa sans sa bibliothèque."
echo
echo "Pensez à vérifier que 'bin/' est bien listé dans export_presets.cfg (il ne"
echo "l'est pas : Godot exporte les .gdextension et les bibliothèques qu'elles"
echo "référencent, mais il faut que le dossier bin/ soit importé au préalable)."
