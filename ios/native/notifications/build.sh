#!/bin/zsh
# Compile IdleNotifications (UserNotifications) pour macOS et iOS.
#
#   native/notifications/build.sh ios
#   GODOT_CPP=/chemin/godot-cpp native/notifications/build.sh ios
#
# Par défaut, godot-cpp est partagé avec native/store/godot-cpp.

set -eu
cd "$(dirname "$0")"

GODOT_CPP="${GODOT_CPP:-$PWD/../store/godot-cpp}"
TARGETS="${*:-macos ios}"
export GODOT_CPP

if ! command -v scons >/dev/null 2>&1; then
	echo "scons absent : brew install scons" >&2
	exit 1
fi
if [ ! -d "$GODOT_CPP" ]; then
	echo "godot-cpp absent dans $GODOT_CPP" >&2
		echo "  lancez native/store/build.sh ou renseignez GODOT_CPP" >&2
	exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
	echo "swiftc/Xcode absent : UserNotifications natif nécessite Xcode complet." >&2
	exit 1
fi

_project_dir="$PWD"
while [ "$_project_dir" != "/" ] && [ ! -f "$_project_dir/project.godot" ]; do
	_project_dir="${_project_dir:h}"
done
GODOT_API_VERSION="${GODOT_API_VERSION:-$(sed -nE 's/^config\/features=PackedStringArray\("([0-9]+(\.[0-9]+)*).*/\1/p' "$_project_dir/project.godot" | head -1)}"
if [ -z "$GODOT_API_VERSION" ]; then
	echo "version GDExtension introuvable depuis $PWD" >&2
	exit 1
fi
export GODOT_API_VERSION

_api_json="$GODOT_CPP/gdextension/extension_api-$(print -r -- "$GODOT_API_VERSION" | tr '.' '-').json"
if [ ! -f "$_api_json" ]; then
	echo "godot-cpp ne fournit pas l'API $GODOT_API_VERSION : $_api_json" >&2
	exit 1
fi
echo "API GDExtension $GODOT_API_VERSION (${_api_json:t})"

build() {
	local platform="$1" target="$2" arch="$3" swift_target="$4" extra=("${@:5}")
	echo "── $platform / $arch ($swift_target)"
	scons -C "$PWD" platform="$platform" target="$target" arch="$arch" \
		api_version="$GODOT_API_VERSION" \
		swift_target="$swift_target" "${extra[@]}" 2>&1 | tee "$PWD/build-$platform-$arch.log"
	local rc="${pipestatus[1]}"
	if [ "$rc" -ne 0 ]; then
		echo "scons a échoué ($rc); consultez build-$platform-$arch.log" >&2
		return "$rc"
	fi
}

mkdir -p bin
DIST="IdleNotifications.gdextension.dist"
ACTIVE="IdleNotifications.gdextension"
deactivate() { rm -f "$ACTIVE"; }
trap deactivate EXIT INT TERM
deactivate

fail=0
for target in ${(z)TARGETS}; do
	case "$target" in
		macos)
			build macos template_debug "" arm64-apple-macos13.0 SDKROOT=macosx || fail=1
			build macos template_release "" arm64-apple-macos13.0 SDKROOT=macosx || fail=1
			;;
		ios)
			build ios template_debug arm64 arm64-apple-ios15.0 \
				SDKROOT=iphoneos ios_simulator=no ios_min_version=15.0 || fail=1
			build ios template_release arm64 arm64-apple-ios15.0 \
				SDKROOT=iphoneos ios_simulator=no ios_min_version=15.0 || fail=1
			build ios template_debug universal arm64-apple-ios15.0-simulator \
				SDKROOT=iphonesimulator ios_simulator=yes ios_min_version=15.0 || fail=1
			build ios template_release universal arm64-apple-ios15.0-simulator \
				SDKROOT=iphonesimulator ios_simulator=yes ios_min_version=15.0 || fail=1
			;;
		*)
			echo "cible inconnue : $target" >&2
			fail=1
			;;
	esac
done

if [ "$fail" -ne 0 ]; then
	echo "Aucun manifeste activé : le jeu garde ses rappels in-game." >&2
	exit 1
fi

cp "$DIST" "$ACTIVE"
trap - EXIT INT TERM
echo "Manifeste activé : $ACTIVE"
