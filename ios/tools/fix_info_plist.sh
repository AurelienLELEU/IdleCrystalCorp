#!/bin/zsh
# Nettoie l'Info.plist d'une application iOS après export Godot.
#
#   ./tools/fix_info_plist.sh build/IdleCrystalCorp.app
#
# Pourquoi c'est nécessaire :
# Godot 4.7 inscrit systématiquement NSCameraUsageDescription,
# NSMicrophoneUsageDescription et NSPhotoLibraryUsageDescription dans
# l'Info.plist exporté, même vides et même si le jeu n'utilise ni la caméra, ni
# le micro, ni la photothèque. Apple rejette une app qui déclare une
# autorisation sans motif : c'est un motif de refus direct à la revue.
#
# Ces clés ne sont pas exposées dans le preset d'export, on ne peut donc pas les
# retirer depuis Godot. D'où ce script, à exécuter juste après l'export.
#
# PlistBuddy est fourni par Xcode (Command Line Tools). Sans Xcode installé :
#   xcode-select --install

set -euo pipefail

APP_PATH="${1:?usage: fix_info_plist.sh <chemin/vers/MonAppli.app>}"

if [ ! -d "$APP_PATH" ]; then
	echo "Erreur : '$APP_PATH' n'est pas un dossier .app" >&2
	exit 1
fi

PLIST="$APP_PATH/Info.plist"
if [ ! -f "$PLIST" ]; then
	echo "Erreur : Info.plist introuvable dans '$APP_PATH'" >&2
	exit 1
fi

if ! command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
	echo "Erreur : PlistBuddy introuvable. Installez les Xcode Command Line Tools :" >&2
	echo "  xcode-select --install" >&2
	exit 1
fi

PLISTBUDDY=/usr/libexec/PlistBuddy

# Clés à supprimer : autorisation demandée alors que le jeu ne s'en sert pas.
UNUSED_KEYS=(
	NSCameraUsageDescription
	NSMicrophoneUsageDescription
	NSPhotoLibraryUsageDescription
	NSPhotoLibraryAddUsageDescription
	NSSpeechRecognitionUsageDescription
	NSBluetoothAlwaysUsageDescription
	NSLocationWhenInUseUsageDescription
	NSLocationAlwaysAndWhenInUseUsageDescription
	NSContactsUsageDescription
	NSFaceIDUsageDescription
)

removed=0
for key in "${UNUSED_KEYS[@]}"; do
	# "Print" ne renvoie rien si la clé est absente : c'est le test.
	if "$PLISTBUDDY" -c "Print :$key" "$PLIST" >/dev/null 2>&1; then
		"$PLISTBUDDY" -c "Delete :$key" "$PLIST" >/dev/null
		echo "  supprimé  $key"
		removed=$((removed + 1))
	fi
done

# Marqueur App Store : le jeu n'utilise aucune cryptographie propriétaire, donc
# l'export n'est pas soumis au questionnaire d'export encryption de l'Apple.
"$PLISTBUDDY" -c "Delete :ITSAppUsesNonExemptEncryption" "$PLIST" >/dev/null 2>&1 || true
"$PLISTBUDDY" -c "Add :ITSAppUsesNonExemptEncryption bool false" "$PLIST" >/dev/null

if [ "$removed" -eq 0 ]; then
	echo "Info.plist déjà propre (aucune clé d'autorisation inutile)."
else
	echo "Info.plist nettoyé : $removed clé(s) d'autorisation supprimée(s)."
fi

# Contrôle final : plus aucune description d'usage vide ne doit subsister.
remaining=0
for key in "${UNUSED_KEYS[@]}"; do
	if "$PLISTBUDDY" -c "Print :$key" "$PLIST" >/dev/null 2>&1; then
		echo "  ATTENTION  $key est toujours présent" >&2
		remaining=$((remaining + 1))
	fi
done

if [ "$remaining" -ne 0 ]; then
	echo "Échec : $remaining clé(s) subsistent." >&2
	exit 1
fi

echo "OK — $PLIST"
