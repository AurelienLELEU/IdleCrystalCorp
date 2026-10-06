# Idle Crystal Corp Android

Export du jeu Godot original, sans réécriture du gameplay. Les scènes, textures, données et scripts sont lus depuis `../ios/` puis copiés dans `%LOCALAPPDATA%/IdleCrystalCorpAndroid/project`. Les sources iOS et leur preset d'export ne sont pas modifiés. Modifier le gameplay dans `ios/`, pas dans la copie générée.

## Version de test

Identifiant Android `fr.btbu.idlecrystalcorp`, version `1.0.0-android-demo`, Android 7.0 (API 24) minimum, cible API 36, architectures arm64-v8a et x86_64. Jeu en portrait, moteur GL Compatibility, sauvegarde locale et progression hors ligne. L'icône, l'écran d'ouverture et les textures d'origine sont réutilisés. Les permissions Internet et la sauvegarde automatique Android sont désactivées.

Les publicités et achats conservent le mode de simulation explicitement indiqué par l'interface originale. Aucun paiement réel, compte Google Play ou SDK AdMob Android n'est connecté. Les plug-ins natifs Apple ne sont pas exportés vers Android. Les notifications natives ne sont pas disponibles. Les prix et récompenses de simulation ne constituent pas une offre commerciale. Cette version sert à tester le jeu, pas à une publication commerciale.

## Construire sous Windows

```powershell
& './IdleCrystalCorp/android/tools/build.ps1'
& './IdleCrystalCorp/android/tools/build.ps1' -TestsOnly
& './IdleCrystalCorp/android/tools/build.ps1' -SkipTests
```

Depuis la racine du workspace. Le script télécharge Godot 4.7.2 standard et ses modèles depuis la publication GitHub officielle, vérifie leurs SHA-256 et les conserve sous `%LOCALAPPDATA%/BTBU/Godot-4.7.2`. Aucun modèle .NET n'est nécessaire. Les journaux de chaque import/test/export y sont conservés, et chaque exécution a une limite de temps.

L'export utilise le JDK 17 et le SDK Android déjà installés pour CashDraft ; autre chemin possible avec `-AndroidToolchain 'chemin/vers/.toolchain'`, contenant `jdk-*` et `android-sdk`. Au besoin, préparer les outils avec le script Android StockChef. Les licences SDK doivent être acceptées par le développeur. Une clé debug locale est créée uniquement pour les tests ; ce n'est pas une clé de publication. L'APK final est `android/artifacts/IdleCrystalCorp-debug.apk`, ignoré par Git.

Le preset versionné `android/export_presets.cfg` est utilisé par le script, avec le chemin du modèle remplacé lors de la préparation. Pour un autre OS, installer Godot 4.7.2 et les modèles Android, puis créer un preset Android dans une copie du projet : le helper fourni vise Windows.

## Vérification

Import Godot, douze suites GDScript, contrôle Python du contrat natif (192 vérifications) et export Android debug réalisés sur Windows. Les tests couvrent notamment les grands nombres, sauvegardes, hors-ligne, UI, interactions, fond animé, économie publicitaire, contrats et zones sûres. Le test de chargement des extensions natives est sans objet sur cette machine, où elles ne sont pas compilées.

Ces tests headless n'équivalent pas à un essai du rendu ou de la reprise de partie sur téléphone Android. Les achats/publicités/rappels réels et la publication Play Store restent à implémenter et à vérifier. La compilation iOS n'a pas été exécutée sur Windows.

L'inspection `aapt2` signale une référence auxiliaire `themed_icon.xml` absente : l'exporteur standard Godot 4.7.2 retire ce fichier du modèle. L'icône de lancement référencée par le manifeste (`icon.xml`) est présente, et la signature APK est valide ; l'icône sur les lanceurs Android à thèmes reste à vérifier sur appareil. Godot utilise aussi Build Tools 35.0.0 en repli pour signer la cible API 36.