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
#   git clone -b 4.7 https://github.com/godotengine/godot-cpp native/store/godot-cpp
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
	echo "  git clone -b 4.7 https://github.com/godotengine/godot-cpp $GODOT_CPP" >&2
	exit 1
fi
if ! command -v swiftc >/dev/null 2>&1; then
	echo "swiftc absent : installez Xcode complet (pas seulement les CLT)." >&2
	exit 1
fi

build() {
	local platform="$1" target="$2" arch="$3" swift_target="$4" extra=("${@:5}")
	local log="$PWD/build-$(print -r -- "$platform-$arch" | tr '/' '_').log"

	echo "── $platform / $arch ($swift_target)"
	if scons -C "$PWD" platform="$platform" target="$target" arch="$arch" \
			swift_target="$swift_target" "${extra[@]}" 2>&1 | tee "$log"; then
		return 0
	fi
	echo "   échec — journal : $log" >&2
	return 1
}

mkdir -p bin
# Voir native/ads/build.sh : le manifeste n'est activé qu'après un build
# complet, sinon Godot hurle au démarrage sur une bibliothèque absente.
DIST="IdleStore.gdextension.dist"
ACTIVE="IdleStore.gdextension"
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
			build macos template_debug   "" arm64-apple-macos13.0
			build macos template_release "" arm64-apple-macos13.0
			;;
		ios)
			# iOS 15 minimum : c'est la version qui a introduit StoreKit 2.
			build ios template_debug   arm64            arm64-apple-ios15.0   SDKROOT=iphoneos
			build ios template_release arm64            arm64-apple-ios15.0   SDKROOT=iphoneos
			build ios template_debug   arm64-simulator  arm64-apple-ios15.0-simulator SDKROOT=iphonesimulator
			build ios template_release arm64-simulator  arm64-apple-ios15.0-simulator SDKROOT=iphonesimulator
			build ios template_debug   x86_64-simulator x86_64-apple-ios15.0-simulator SDKROOT=iphonesimulator
			build ios template_release x86_64-simulator x86_64-apple-ios15.0-simulator SDKROOT=iphonesimulator
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
ls -1 bin/
echo
echo "Manifeste activé : $ACTIVE"
