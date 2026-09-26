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
#   git clone -b 4.7 https://github.com/godotengine/godot-cpp native/ads/godot-cpp
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
	echo "  git clone -b 4.7 https://github.com/godotengine/godot-cpp $GODOT_CPP" >&2
	exit 1
fi

# --- SDK AdMob -------------------------------------------------------------
# Emplacement de GoogleMobileAds.framework, soit par variable, soit par
# détection dans les répertoires habituels des pods CocoaPods / Carthage.
find_admob_framework() {
	local candidate
	if [ -n "${ADS_SDK:-}" ]; then
		printf '%s' "$ADS_SDK"
		return
	fi
	for candidate in \
		"$PWD/Pods/GoogleMobileAds" \
		"$PWD/../pods" \
		"$HOME/Library/Developer/Xcode/DerivedData/GoogleMobileAds"*; do
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
	if scons -C "$PWD" platform="$platform" target="$target" arch="$arch" \
			google_mobile_ads_path="$ADMOB_DIR" "${extra[@]}" 2>&1 | tee "$log"; then
		return 0
	fi
	echo "   échec — journal : $log" >&2
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
	[ -f "$ACTIVE" ] && mv "$ACTIVE" "$DIST"
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
			build ios template_debug   arm64     SDKROOT=iphoneos        || fail=1
			build ios template_release arm64     SDKROOT=iphoneos        || fail=1
			# Simulateur Apple Silicon. -sdk iphonesimulator.
			build ios template_debug   arm64-simulator SDKROOT=iphonesimulator || fail=1
			build ios template_release arm64-simulator SDKROOT=iphonesimulator || fail=1
			# Simulateur Intel. Inutile si vous n'utilisez qu'un Mac Apple
			# Silicon, mais la build prend deux minutes.
			build ios template_debug   x86_64-simulator SDKROOT=iphonesimulator || fail=1
			build ios template_release x86_64-simulator SDKROOT=iphonesimulator || fail=1
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
ls -1 bin/
echo
echo "Manifeste activé : $ACTIVE"
echo "Vérifiez que bin/ est importé (l'icône en tête de liste), sinon Godot"
echo "copiera l'extension dans le .ipa sans sa bibliothèque."
echo
echo "Pensez à vérifier que 'bin/' est bien listé dans export_presets.cfg (il ne"
echo "l'est pas : Godot exporte les .gdextension et les bibliothèques qu'elles"
echo "référencent, mais il faut que le dossier bin/ soit importé au préalable)."
