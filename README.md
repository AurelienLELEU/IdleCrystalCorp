# Idle Crystal Corp

Jeu idle incrémental complet, en **Godot 4.7**, écrit intégralement en GDScript.
Il est **jouable de bout en bout, gratuitement**, sur mobile et sur ordinateur :
20 bâtiments, 10 améliorations de clic, 17 technologies, 31 succès, une
ascension et des gains hors-ligne.

Les pubs et les achats intégrés n'ont qu'un seul rôle : **faire avancer plus
vite**. Jamais un verrou. Un joueur qui ne regarde aucune pub et n'achète rien
peut atteindre le même contenu qu'un autre — il met simplement plus de temps.
C'est une décision de conception, appliquée dans tout le code, pas une
concession.

![Écran d'accueil](assets/splash.png)

---

## Sommaire

1. [Démarrage rapide](#démarrage-rapide)
2. [Tests](#tests)
3. [Architecture](#architecture)
4. [Conception](#conception)
5. [Pubs : Google AdMob](#pubs-google-admob)
6. [Achats : StoreKit 2](#achats-storekit-2)
7. [Notifications locales](#notifications-locales)
8. [Export iOS](#export-ios)
9. [Images de l'application](#images-de-lapplication)
10. [Équilibrage](#équilibrage)
11. [Format de sauvegarde](#format-de-sauvegarde)
12. [Pièges connus de GDScript](#pièges-connus-de-gdscript)
13. [Avant publication](#avant-publication)

---

## Démarrage rapide

```bash
# Ouvrir le projet dans Godot 4.7
godot --path .

# Ou en ligne de commande, sans interface
godot --headless --path . --import
```

Aucune dépendance, aucun plugin requis pour jouer. Le jeu démarre et fonctionne
avec des pubs et une boutique **simulés** : le parcours complet est testable
sans compte développeur.

L'ordre des autoloads dans `project.godot` est significatif : `GameManager`
interroge `Notifications`, `Ads` et `Audio`, il doit donc être instancié en
dernier.

---

## Tests

846 vérifications, 12 contrôles, tous automatisés en headless ou par script Python :

```bash
./tests/run_all.sh                       # tout
./tests/run.sh res://tests/test_game.gd   # une seule suite Godot
python3 tests/check_native_contract.py   # le contrôle hors Godot
```

| Contrôle | Ce qu'il couvre |
|---|---|
| `test_bignum.gd` | Mantisse/exposant, comparaisons, formatage, grands nombres |
| `test_game.gd` | Économie, achat, sauvegarde, migration, hors-ligne, ascension, succès, boutique |
| `test_offline_persistence.gd` | Gains en attente, autosaves, quarantaine et absence de double comptage |
| `test_save_codec.gd` | CRC32, en-tête, versions, champs obligatoires et corruption binaire |
| `test_ui_compile.gd` | Instanciation réelle de `Main.tscn`, intégrité des 7 pages |
| `test_ui_interaction.gd` | Navigation, récolte, achats, restauration, popups, resets et unicité des toasts |
| `test_background.gd` | Shader animé et évolution effective selon les achats |
| `test_plugin_contract.gd` | Contrat entre le jeu et les extensions `IdleAds` / `IdleStore`, avec un faux plug-in injecté |
| `test_ads_economy.gd` | Plafonds quotidiens, compteur partagé, fenêtres de pubs |
| `test_native_load.gd` | Chargement réel des GDExtensions compilées, si les bibliothèques sont présentes |
| `test_safe_area.gd` | Zone sûre, centrage, débordement, et pièges de `set_anchors_preset` |
| `check_native_contract.py` | Frontières C / C++ / Objective-C++ / Swift et gardes iOS critiques |

`tests/run.sh` impose un délai maximal d'exécution : si un script ne compile
pas, Godot ne quitte jamais et relance silencieusement la scène principale en
boucle. Le wrapper coupe et signale l'échec au lieu de laisser le process
tourner indéfiniment (`timeout` n'existe pas sur macOS, et `gtimeout` n'est pas
installé par défaut).

Chaque suite tourne dans son **propre** process Godot : c'est plus lent, mais un
état laissé par un test (fichier de sauvegarde, autoload modifié) ne peut pas
fausser le suivant.

> Les tests utilisent `save_path_override` pour écrire dans un fichier isolé.
> Ils ne touchent jamais votre vraie sauvegarde.

### `check_native_contract.py`, le contrôle qui ne lance pas Godot

Un build de stubs qui réussit ne compile pas la branche qui importe les SDK
propriétaires. C'est précisément pourquoi ce contrôle est nécessaire : une
extension se charge, `IdleAds` s'inscrit dans `ClassDB`, le jeu « fonctionne » —
puis plante à la première pub parce qu'un paramètre est devenu `long` entre
l'en-tête et le `.mm`. Aucun message d'erreur ne pointe vers la cause.

Le script compare les **deux sens** de chaque frontière :

- **actions** C++ → iOS : déclarées dans l'en-tête C, définies dans le `.mm`
  (ou le `.swift`), appelées depuis le `.cpp` ;
- **passerelles** iOS → C++ : déclarées dans l'en-tête C, définies en
  `extern "C"` dans le `.cpp`, appelées depuis la couche iOS.

Il vérifie aussi que chaque `D_METHOD` de godot-cpp pointe vers une méthode
réellement déclarée, et que le nom exposé à GDScript correspond au nom C++.

Il compare les **types**, pas seulement le nombre de paramètres : un `int` devenu
`long` est un bug d'ABI qui corrompt la pile au premier appel, et un compteur de
paramètres ne le voit pas. Les différences d'écriture sont normalisées
(`const char *`, `char const *` et `char * const` sont le même type, et
`UnsafePointer<CChar>?` de Swift aussi), sinon le script signalerait des
divergences là où il n'y en a pas — et l'on apprendrait à ignorer ses alertes.

Aucune dépendance : uniquement la bibliothèque standard de Python. Les 130
vérifications courantes comprennent aussi des contrats runtime de la branche
iOS, mutés exprès un par un pour prouver que chaque contrôle échoue.

---

## Architecture

```
project.godot            autoloads, splash, icône
core_engine/             aucune référence à l'interface
  BigNum.gd              nombres hors double (mantisse + exposant)
  Fmt.gd                 formatage : 1.5e250, 1 h 23, 12,3 k
  GameConfig.gd          lecture et indexation de game_config.json
  GameManager.gd         simulation, sauvegarde, hors-ligne, ascension, signaux
  SaveCodec.gd           sérialisation binaire versionnée
  AdService.gd           autoload Ads      — interface unique, mock ou SDK
  StoreService.gd        autoload Store    — interface unique, mock ou StoreKit
  NotificationService.gd autoload Notifications
  AudioManager.gd        autoload Audio
  UITheme.gd             palette, StyleBox, helpers de mise en page
scenes/
  Main.tscn              scène racine
  MainUI.gd              toute l'interface, construite en code (1 254 lignes)
  CrystalBackground.*    shader animé, progression liée aux achats
  ui/Toast.gd            notifications éphémères
  ui/Modal.gd            fenêtres modales
  ui/FloatingNumber.gd   nombres flottants à la récolte
native/                  code natif : absent du dépôt compilé, sources présentes
  ads/                   Google AdMob      — Objective-C++
  store/                 StoreKit 2        — Swift
  */build.sh             compile et n'active le manifeste qu'après un succès
data/game_config.json    tout l'équilibrage
tools/make_assets.py     génère icon.png et assets/splash.png
tools/fix_info_plist.sh  nettoyage de l'Info.plist après export
tests/                   5 suites Godot + le contrôle de frontière native
```

### Séparation des responsabilités

`GameManager` ne connaît ni l'interface, ni les pubs, ni les achats. L'UI ne
touche jamais à l'état directement : elle appelle des méthodes publiques et
s'abonne à des signaux.

```gdscript
# 14 signaux, dont :
signal resources_changed(total: BigNum, per_sec: BigNum)
signal building_purchased(id: String, count: int, cost: BigNum)
signal prestige_performed(points_gained: int, total_points: int)
signal offline_gains_claimed(amount: BigNum, doubled: bool)
signal game_reset()
```

### `BigNum`, et pourquoi il existe

Un idle game dépasse `float` très vite. Avec un multiplicateur de 1,15 par
achat, le coût d'un bâtiment atteint 10¹⁵ en quelques centaines d'exemplaires,
puis 10⁴⁰, puis 10⁸⁰… `float` sature à 1,8 × 10³⁰⁸. Au-delà, `%d` et `float`
renvoient `inf` ou plantent, et l'interface affiche « inf ».

`BigNum` stocke une mantisse et un exposant en base 10. Le test vérifie
qu'à 5 000 exemplaires les coûts restent finis et qu'aucun `NaN` n'apparaît.

Deux pièges qui coûtent cher si on les ignore :

| À écrire | Pas | Pourquoi |
|---|---|---|
| `log10(x)` | `log10v(x)` | `log10` n'existe pas dans `@GlobalScope` |
| `abs(x)` | `absolute(x)` | `abs` est réservé |
| `a.copysign(b)` | `signf(x)` | `copysign` n'existe pas |

`BigNum` expose `equals()` et `cmp()` — **pas** `eq()`.

### Cache et invalidation

`game_config.json` est lu **une seule fois** et indexé en `Dictionary` par
`GameConfig` au chargement. La production par seconde et la puissance de clic
sont mises en cache et invalidées à la demande quand un achat ou une recherche
change un multiplicateur. L'interface se rafraîchit à **10 Hz** (`UI_TICK_HZ`),
pas à chaque frame.

Aucune recherche linéaire dans une boucle de rendu.

---

## Conception

### Gains hors-ligne

Le mécanisme est le point le plus délicat d'un idle game, parce qu'il est
facile de tricher involontairement en sa faveur.

1. Au moment de chaque sauvegarde, la production courante est mémorisée dans
   `production_at_save`. Sans cela, acheter juste avant de quitter ne rapporterait
   rien une fois l'application tuée en arrière-plan.
2. Au retour, `_compute_offline_gains()` **calcule** les gains et les dépose
   dans `pending_offline`. **Il ne les crédite jamais.**
3. L'horodatage `last_save_timestamp` est avancé **avant toute sortie de la
   fonction**, ce qui la rend idempotente : l'appeler trois fois ne compte la
   période qu'une fois.
4. Le crédit n'a lieu que dans `claim_offline_gains(doubled)`, appelé par un
   bouton explicite.

Conséquence : un joueur qui ferme l'application cinq fois de suite, ou qui laisse
le jeu en arrière-plan, ne peut jamais obtenir plus que la somme de ses vraies
périodes. Les gains en attente **cumulent** au lieu de s'écraser. Le plafond est
de 2 h par défaut, extensible jusqu'à 4 h, 6 h… par les technologies de
recherche.

### La popup de retour

```
👋 Bon retour !

Vous étiez absent·e pendant 1 h 47.
Vos cristaux continuaient de produire.

        [ 💎 Collecter 12,4 M ]      ← le montant réel, affiché d'abord
        [ 🎬 Voir une pub → doubler ]
        [      Plus tard     ]
```

Le gain réel est affiché **avant** toute proposition de pub. On ne cache jamais
la récompense pour créer un sentiment d'urgence artificiel. « Plus tard » ne
crédite rien et les gains restent réclamables au prochain lancement.

Si le joueur a acheté « Supprimer les pubs », le bouton « 🎬 Voir une pub »
est remplacé par **« 💎💎 Double gratuit »** : payer pour supprimer les pubs ne
doit pas retirer une récompense déjà obtenue.

La popup refuse de s'ouvrir s'il n'y a rien à réclamer, plutôt que
d'afficher « Collecter 0 ».

### Aucune confirmation trompeuse

Pas de « X » qui achète, pas de « Continuer » qui surplombe un « Non ».
L'écran de confirmation affiche le vrai nom et le **vrai prix**, et « Annuler »
est aussi visible que « Acheter ». C'est ce qui fait la différence entre un jeu
qui gagne de l'argent et un jeu qui se fait détester.

### Plafonds quotidiens

Une pub récompensée n'est pas infinie. C'est la pratique standard des réseaux,
et surtout cela évite un jeu dégradé pour le joueur.

| Récompense | Plafond par jour |
|---|---|
| Double des gains hors-ligne | 1 |
| Boost de production | 3 |
| Cadeau de bienvenue | 5 |

### Ascension

« Éclats d'Éternité » : `points = (cumul gagné / 1e9) ^ 0,5`, soit +1 % de
production permanente par éclat. Le seuil est à 1 milliard de cumul. La recherche
est remise à zéro, les améliorations de clic non — c'est un choix, ajustez-le
dans `prestige` de `game_config.json`.

---

## Pubs : Google AdMob

Le choix retenu est **AdMob**, et l'extension est **déjà écrite** dans
`native/ads/`. Il ne reste qu'à la compiler. En attendant, le jeu tourne sur son
simulateur intégré, ce qui permet de développer tout le reste sans SDK.

```
native/ads/
  IdleAds.gdextension.dist   manifeste (activé par build.sh après un build réussi)
  SConstruct                 règles de compilation
  build.sh                   compile macOS + iOS (appareil et simulateurs)
  src/idle_ads.{h,cpp}       la classe vue par GDScript
  src/register_types.cpp     point d'entrée de la GDExtension
  ios/idle_ads_ios.{h,mm}    l'appel à AdMob, en Objective-C++
```

### Compiler

```bash
brew install scons                                   # ou : pip3 install --user scons
git clone -b master https://github.com/godotengine/godot-cpp native/ads/godot-cpp
native/ads/build.sh              # macOS + iOS
native/ads/build.sh ios          # iOS seul
```

Les cibles sont `macos` et `ios`. Il n'existe **pas** de cible
`target=ios_simulator` : ce nom ne veut rien dire pour ce script, qui le
rejette au lieu de le deviner.

Xcode **complet** est requis, pas seulement les Command Line Tools :

```bash
xcode-select --install           # ne suffit PAS
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Sans `sudo`, la même effet s'obtient par variable d'environnement, et c'est
**préférable** pour ce projet :

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Cette variable est indispensable, et pas seulement pour `xcodebuild`. Le
`swiftc` trouvé par `command -v` est celui des Command Line Tools ; compilé
avec le SDK d'Xcode 27, il échoue sur des dizaines de messages
« consecutive statements on a line must be separated by `;` » **à l'intérieur
des `.swiftinterface` du SDK lui-même**, qui ne sont pas du code à nous.
`native/store/SConstruct` va donc chercher le bon `swiftc` par
`xcrun --find swiftc`, qui respecte `DEVELOPER_DIR`, et avertit
explicitement s'il retombe sur les Command Line Tools.

La version de l'API GDExtension est **lue dans `project.godot`**, jamais
codée en dur dans les scripts : une extension compilée contre une autre
version est refusée au chargement, et le pire moment pour l'apprendre est
après toute la chaîne d'export et de signature. `build.sh` refuse de
compiler si le `godot-cpp` cloné ne fournit pas cette version, et liste
celles qu'il fournit.

Le SDK AdMob s'obtient via CocoaPods (`pod install` récupère
`Google-Mobile-Ads-SDK`). `build.sh` le cherche dans les emplacements
habituels, ou renseignez `ADS_SDK=/chemin/vers/GoogleMobileAds`. Sans SDK,
`NO_SDK=1 native/ads/build.sh` compile une extension neutre : le jeu bascule
alors sur son simulateur, ce qui sert à valider le reste.

`build.sh` n'active le manifeste `.gdextension` **qu'après** un build complet.
Tant que le binaire manque, Godot spammerait quatre lignes d'erreur de
`dlopen` à chaque lancement, dans l'éditeur comme dans les tests.

`tests/test_native_load.gd` va jusqu'au bout : il charge les deux extensions
réellement compilées, vérifie que leurs classes arrivent dans `ClassDB`, et
que les méthodes et signaux que le jeu appelle existent vraiment. C'est le
seul test qui prouve que la chaîne entière fonctionne, et il ne s'exécute
que si une extension a été compilée — sinon il affiche « rien à vérifier »
plutôt qu'un nombre qui ferait croire à une couverture.

### Ce que la première compilation a révélé

Le code natif n'avait jamais été compilé. Il ne compilait pas. Les défauts
suivants étaient invisibles sans un vrai `scons` — ils sont documentés ici
parce que chacun se camoufle en succès :

| Défaut | Pourquoi ça passait |
|---|---|
| `if scons … \| tee log` | en zsh, le statut d'un pipeline est celui de `tee`, qui réussit toujours : **tout build cassé était rapporté réussi** |
| `deactivate()` faisait `mv $ACTIVE $DIST` | le build écrasait la source de vérité par la copie périmée ; corriger le manifeste puis compiler l'effaçait silencieusement |
| Le manifeste pointait `native/bin/` | le SConstruct écrivait ailleurs : binaires produits, manifeste activé, extension introuvable |
| macOS annoncé en `.framework` | godot-cpp produit un `.dylib` ; le nom n'est pas choisi, il est calculé |
| `arm64-simulator` comme arch scons | valeur inventée : scons sort en erreur avant de lire une ligne du projet |
| `#ifdef __APPLE__` autour d'un `#import <UIKit>` | `__APPLE__` est vrai sur **macOS** aussi : la cible `macos` échouait |
| `IDLE_ADS_NO_SDK` mentionné, jamais défini | le garde-fou du `.mm` ne protégeait rien |
| `env.Command(..., [liste])` pour swiftc | SCons n'exécute que le premier élément : la commande lançait `swiftc` seul, « error: no input files » |
| `SDKROOT=iphoneos` passé à swiftc | c'est un *nom*, pas un dossier : « unable to load standard library » |
| `SKError.Code.storeKitErrorFailedLoadProducts` | nom Objective-C, pas Swift : le cas n'existe pas. Les 16 cas réels ont été relevés en compilant des sondes |
| archive Swift en arm64 seule | godot-cpp produit un macOS « universal » : il faut compiler par tranche puis `lipo` |
| `libswiftCompatibility56` introuvable | le runtime est dans le **toolchain**, pas dans le SDK |

`tests/check_native_contract.py` vérifie désormais, sans rien compiler, les
frontières C/Swift/Objective-C++, les chemins du manifeste, la liste d'interface
de `test_native_load.gd` et les gardes runtime iOS. Parmi ces dernières : unité
de test iOS, récompense seulement après `userDidEarnReward`, retour d'erreur au
SDK pas prêt, timeout, durée de vie des pointeurs C et récupération des droits
StoreKit. Chaque garde nouvelle a été testée **négativement** par mutation.

Le build local `NO_SDK=1` ne compile que les stubs AdMob : le chemin qui importe
`GoogleMobileAds.framework` n'a pas pu être compilé ici, car le SDK n'est pas
fourni. Les appels et noms d'API ci-dessus ont été recoupés avec la référence
Google actuelle; un build iOS final avec le SDK reste obligatoire avant
publication.

### Le mode test

C'est le point sur lequel les projets se cassent, donc il est traité à trois
niveaux.

| Où | Quoi |
|---|---|
| `project.godot` | `application/admob_app_id` et `application/admob_rewarded_unit_id` contiennent **les identifiants de test publics de Google** |
| `idle_ads_ios.mm` | en debug, force aussi l'unité officielle **Rewarded iOS** (suffixe `1712485313`), même si un ID de production est configuré |
| `application/ads_use_test_ads` | déclare le simulateur iOS comme appareil de test |
| `GameManager._configure_services()` | force `false` dans une build **release**, quoi que dise le fichier |

Le troisième niveau est le filet de sécurité : un binaire livré ne peut pas
afficher de vraies annonces par accident, même si le réglage est resté à `true`
dans la configuration.

**En production**, remplacez les deux identifiants dans `project.godot` par les
vôtres. Rien d'autre ne change.

### Le contrat, en une phrase

`rewarded_completed` n'est émis **qu'après** le callback `userDidEarnReward` de
Google, puis la fermeture de la vidéo. La fermeture seule ne prouve pas que le
joueur a gagné la récompense; le callback de chargement a aussi un timeout de 15
secondes et chaque refus remonte à `AdService` au lieu de laisser `_busy` bloqué.
Ces règles se jouent dans `idle_ads_ios.mm`, pas en GDScript.

`tests/test_plugin_contract.gd` vérifie que seule la fin de vidéo crédite, avec
un faux plug-in qui reproduit l'interface exacte de `idle_ads.h`.

### Points d'attention

- **`abort(reward_id, reason)`** propage la raison du SDK. « Réseau
  indisponible » et « pub interrompue » ne demandent pas la même réaction, et
  un message générique sur une coupure passagère donne l'impression d'un bug.
- **Une pub échouée ne coûte rien au joueur** : il garde son gain hors-ligne, il
  perd seulement l'accélérateur. C'est la seule sanction acceptable quand on a
  promis qu'aucune pub n'est requise.
- **`is_available(reward_id)`** renvoie `false` si « Supprimer les pubs » a été
  acheté, et le plug-in n'est jamais appelé. Ne contournez pas ce garde-fou.
- Les rewarded ads d'AdMob exigent la mediation ; l'export Godot ne la gère pas.

---

## Achats : StoreKit 2

StoreKit 2 est **Swift uniquement** — il n'a aucun équivalent Objective-C. C'est
pourquoi ce module est en Swift avec des exports `@_cdecl`, là où AdMob est en
Objective-C++. Un seul des deux a besoin de Swift, pas les deux.

```
native/store/
  IdleStore.gdextension.dist
  SConstruct
  build.sh
  src/idle_store.{h,cpp}        la classe vue par GDScript
  ios/idle_store_ios.swift      StoreKit 2
```

```bash
git clone -b master https://github.com/godotengine/godot-cpp native/store/godot-cpp
native/store/build.sh
```

iOS 15 minimum — c'est la version qui a introduit StoreKit 2.

### Quatre pièges traités explicitement

1. **Vérification des transactions.** `Transaction.verificationResult` est
   systématiquement contrôlé. Sans cela, un reçu forgé accorde un entitlement
   gratuit.
2. **`PurchaseResult.pending` n'est pas un échec.** Le joueur a payé, l'App
   Store attend. Le traiter comme un échec lui fait perdre son argent ;
   `Transaction.updates` s'en charge à la place.
3. **Une annulation n'est pas une erreur.** Message neutre, jamais un « échec »
   en rouge qui suggère un bug.
4. **Le prix affiché vient de StoreKit**, jamais du JSON. `get_display_price()`
   fait la bascule. Si StoreKit n'a pas encore renvoyé de prix, le bouton reste
   désactivé jusqu'au signal `products_loaded`; le prix du JSON ne sert qu'en
   simulation. Un prix codé en dur est soit faux dans 150 devises, soit un
   motif de refus de la revue.

### Le piège de l'état local

`Transaction.currentEntitlements` remplit le cache au démarrage, avant le signal
qui rafraîchit la boutique; `is_purchased()` interroge ensuite cet état local.
La restauration manuelle compte tous les droits actifs, pas seulement ceux qui
n'étaient pas encore dans le cache. Un joueur qui réinitialise sa partie et qui
doit racheter ce qu'il a déjà payé, c'est le bug le plus coûteux d'un jeu à
achats. Le test `_test_store_entitlement_survives_hard_reset()` verrouille la
remise à zéro; les contrôles natifs verrouillent aussi le chargement au
démarrage. En mode StoreKit réel, `AdService` refuse aussi d'afficher une pub
tant que ce chargement n'a pas répondu : un acheteur « Supprimer les pubs » ne
voit pas de pub pendant la fenêtre de réinstallation.

### Les identifiants

Le `product_id` de `game_config.json` doit correspondre **exactement** à celui
déclaré dans App Store Connect :

| Id interne | `product_id` StoreKit | Type |
|---|---|---|
| `supprimer_pubs` | `com.aurelien.idlegame.noads` | droit (achat unique) |
| `pack_decouverte` | `com.aurelien.idlegame.pack.decouverte` | consommable |
| `pack_cristaux_1` | `com.aurelien.idlegame.pack.t1` | consommable |
| `pack_cristaux_2` | `com.aurelien.idlegame.pack.t2` | consommable |
| `pack_cristaux_3` | `com.aurelien.idlegame.pack.t3` | consommable |
| `pack_cristaux_4` | `com.aurelien.idlegame.pack.t4` | consommable |

Un **droit** ne s'achète qu'une fois et survit à une remise à zéro. Un
**consumable** peut être racheté. Le jeu traduit l'un dans l'autre : StoreKit
parle en `product_id`, le jeu en identifiants internes.

---

## Notifications locales

> **Godot 4.7 n'expose aucune API de notification locale dans son core.** C'est
> une limite du moteur, pas du projet. Sur iOS, il faut un plug-in natif.

`NotificationService` est la couche d'abstraction. Elle cherche une
GDExtension `IdleNotifications` ; si elle est absente, le jeu **fonctionne
quand même** : la popup de retour hors-ligne et le bandeau in-game font le même
travail, et `is_supported()` vaut `false`.

**Interface attendue :**

```gdscript
request_permission() -> void   # émet permission_changed(bool)
schedule(id: String, title: String, body: String, delay_seconds: float) -> bool
cancel(id: String) -> void
cancel_all() -> void
```

Le rappel est programmé pour **2 h** après la mise en arrière-plan
(`notify_after_hours` dans la configuration). Passé ce délai, le joueur reçoit
« vos gains vous attendent ».

**Exemple Swift pour le plug-in :**

```swift
import UserNotifications

@objc(IdleNotifications)
public class IdleNotifications: NSObject, UNUserNotificationCenterDelegate {

    @objc public func request_permission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                NotificationCenter.default.post(
                    name: Notification.Name("IdleNotificationsPermission"),
                    object: nil, userInfo: ["granted": granted])
            }
    }

    @objc public func schedule(_ id: String, title: String, body: String,
                               delaySeconds: Double) -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // iOS ne fusionne pas deux rappels identiques : on remplace toujours.
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1.0, delaySeconds), repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content,
                                            trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            guard error == nil else { return }
            NotificationCenter.default.post(
                name: Notification.Name("IdleNotificationsScheduled"),
                object: nil, userInfo: ["delay": delaySeconds])
        }
        return true
    }

    @objc public func cancel(_ id: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id])
    }

    @objc public func cancel_all() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
```

`add(_:)` est asynchrone : ne le remplacez pas par une valeur de retour
`true` sans vérifier, sinon vous programmerez des rappels fantômes. Le code
ci-dessus poste un notification pour prévenir le jeu du résultat réel.

---

## Export iOS

```bash
# 1. Renseigner l'identifiant et l'équipe dans export_presets.cfg
#    application/bundle_identifier, application/app_store_team_id
# 2. Exporter depuis l'éditeur, ou :
godot --headless --path . --export-release "iOS" build/IdleCrystalCorp.ipa

# 3. Nettoyer l'Info.plist (voir plus bas)
zsh tools/fix_info_plist.sh
```

### `tools/fix_info_plist.sh`

Godot 4.7 écrit dans l'`Info.plist` exporté **10 clés d'autorisation iOS
inutiles** (caméra, micro, photothèque, localisation, contacts…) avec des
chaînes vides. Elles ne sont pas paramétrables depuis le preset d'export.

Ce script les supprime avec `PlistBuddy`, et pose
`ITSAppUsesNonExemptEncryption = false` pour éviter une question de conformité à
l'export App Store.

> Exécutez-le **après** chaque export, sinon les clés reviennent.

---

## Images de l'application

L'icône et l'écran de démarrage sont **générés par le code**, pas versionnés en
binaire :

```bash
python3 tools/make_assets.py
```

Produit `icon.png` (1024 × 1024) et `assets/splash.png` (1280 × 720). Le rendu
est déterministe : relancer le script ne change rien. Le script n'utilise que
la bibliothèque standard Python.

Deux contraintes techniques à connaître avant de modifier ce fichier :

1. **L'icône iOS doit être un PNG plein, 1024 × 1024, sans canal alpha.** iOS
   applique sa propre pastille et masque les coins : arrondir les angles ici
   n'aurait aucun effet, et un fond transparent devient noir.
2. **Le splash de démarrage n'accepte que du PNG.** Un SVG y est refusé et
   remplacé par le logo Godot par défaut (message
   `Non-existing or invalid boot splash at '...' The only supported format is
   PNG.`).

---

## Équilibrage

Tout est dans `data/game_config.json` : bâtiments, améliorations, recherches,
succès, produits, production, paliers, multiplicateurs, coûts. **Aucune constante
d'équilibrage n'est écrite dans le code GDScript.**

```json
"offline": {
  "base_hours": 2.0,
  "hours_per_research_level": 2.0,
  "min_popup_seconds": 60.0,
  "notify_after_hours": 2.0
},
"combo": {
  "base_window": 1.2,
  "max_stacks": 25,
  "power_per_stack": 0.04,
  "window_per_research_level": 1.0
},
"prestige": {
  "min_run_earnings": 1000000000.0,
  "exponent": 0.5,
  "divisor": 1000.0,
  "mult_per_point": 0.01,
  "reset_research": true
}
```

Le fichier ne contient **aucun commentaire** : le JSON n'en accepte pas, et les
commentaires Objective-C qui traînent dans un JSON sont un piège classique
pendant un remplacement de fichier.

---

## Format de sauvegarde

- `user://idle_save.dat` — binaire, en-tête magique `IDLS`, `CURRENT_VERSION := 3`
- `user://savegame.json` — ancien format (v1), lu et migré automatiquement au
  premier lancement vers le format courant, puis sauvegardé une fois en copie de
  sécurité

L'en-tête v3 fait 13 octets : `IDLS`, la version, la longueur de la charge utile
sur 4 octets, puis son CRC32 sur 4 octets. Une sauvegarde v2 (en-tête de 5
octets, sans longueur ni CRC) reste lisible, avec un avertissement : refuser une
sauvegarde pour un défaut de format qu'aucun octet de son contenu ne prouve
reviendrait à punir le joueur d'une version antérieure du jeu. Plus rien
n'écrit ce format.

Le CRC est là parce que `var_to_bytes()` ne le fait pas. Mesuré sur une
sauvegarde réelle, une inversion d'un seul bit dans la charge utile se
reconformait **sans erreur** : 31 cas refusés sur 144, et **21 sauvegardes
acceptées avec une valeur fausse**. Un compteur de bâtiments passé de 42 à 43 est
invisible, et l'autosave réécrivait ensuite la version fausse par-dessus la
vraie. `tests/test_save_codec.gd` vérifie maintenant, pour chaque octet et
plusieurs masques, que toute inversion est SOIT refusée, SOIT redécodée à
l'identique — avec un contrôle d'écho, sans quoi un décodeur qui refuse tout
passerait aussi.

Une charge utile syntaxiquement correcte mais incomplète est refusée elle aussi,
et part en quarantaine comme une corruption. Sans cela, un `{}` passait,
`GameManager` comblait les champs manquants, le joueur repartait d'une partie
neuve et l'autosave réécrivait le fichier vingt secondes plus tard : perte
totale, invisible, irrécupérable.

L'écriture est **atomique** : le fichier est écrit en `.tmp` puis renommé. Un
tué au milieu de l'écriture ne peut pas corrompre la sauvegarde. Un limiteur de
débit de 3 s évite d'écrire 60 fois par seconde quand l'UI rafraîchit.

Sauvegarde automatique toutes les 15 à 30 s, **et** sur `application_paused`,
`focus_out`, et à la fermeture.

La production est mémorisée au moment du point de contrôle
(`production_at_save`) : c'est elle qui sert au calcul des gains hors-ligne.

---

## Pièges connus de GDScript

 relevés en développant ce projet. Chacun coûte une heure à retrouver.

| Piège | Correctif |
|---|---|
| `obj.get("clé", défaut)` sur une variable **typée** se résout vers `Object.get(propriété)` — 1 argument, erreur « Expected 1 argument(s) » | typer explicitement (`as GameConfig`) puis accès direct à la propriété |
| Un `class_name` tout juste ajouté n'est pas connu | `--headless --path . --import` avant de compiler |
| Les warnings « type inféré depuis un Variant » sont traités comme des **erreurs** | toujours typer explicitement les variables issues d'un `Dictionary` |
| `DirAccess.remove()` est une **méthode d'instance** en 4.7, pas une fonction statique | `DirAccess.remove_absolute()` pour un chemin absolu |
| `var_to_bytes` / `bytes_to_var` n'acceptent **qu'un** argument | pas de `allow_objects` en 4.x |
| `propagate_notification()` prend 1 argument | ID à l'intérieur d'un tableau |
| Une constante de script n'est pas lisible via `Object.get()` | accès direct |
| `Toast.show` entre en collision avec `CanvasItem.show()` | renommé `push` |
| Dans un script étendant `SceneTree`, les constantes de `Node` doivent être préfixées | `Node.PROCESS_MODE_ALWAYS` |

Et un piège GDScript général, pas spécifique au moteur : **une fonction qui
contient `await` est une coroutine.** L'appeler sans `await` ne fait pas ce qu'on
croît — elle démarre, s'interrompt à son premier `await`, rend la main, et
continue en arrière-plan. Toutes les fonctions de test s'entrelacent alors, et
le moindre `queue_free()` libère une scène encore utilisée ailleurs.

---

## Avant publication

Ce qui reste à faire avant une mise en ligne, par ordre d'importance :

1. **Brancher Google Mobile Ads réel.** `native/ads/build.sh` a été exécuté sur
   macOS et iOS en `NO_SDK=1`; ces builds vérifient les stubs, pas
   `GoogleMobileAds.framework`. Installer le SDK et recompiler sans `NO_SDK`
   (`ADS_SDK=/chemin/vers/GoogleMobileAds native/ads/build.sh ios`). L'identifiant
   d'application et l'unité Rewarded iOS réels restent à fournir dans
   `project.godot`. Le code debug force l'unité de test iOS; valider les pubs
   réelles ensuite sur un appareil de test AdMob.
2. **Finaliser App Store Connect** : créer les sept produits avec les IDs exacts
   du tableau (§ 6), définir leurs prix, accepter les accords de vente et
   vérifier les transactions/restaurations avec un compte Sandbox.
3. **Remplacer le bundle identifier** `com.aurelien.idlegame` par le vôtre, dans
   `project.godot` et dans chaque `product_id` de `game_config.json`; vérifier
   aussi l'identifiant d'application AdMob qui doit correspondre à l'`Info.plist`.
4. **Renseigner l'équipe de signature**, les certificats et le profil de
   provisionnement dans `export_presets.cfg`; exporter, ouvrir l'archive Xcode,
   signer et valider l'IPA.
5. **Vérifier confidentialité et conformité** : politique de confidentialité,
   déclaration des données dans App Store Connect, consentement publicitaire
   (UMP/ATT selon les régions et les usages retenus) et texte des fiches de
   boutique. Le projet ne contient pas actuellement d'intégration UMP/ATT.
6. **Écrire `IdleNotifications`** si les notifications système réelles sont
   voulues (§ 7). Le code actuel ne programme que des rappels internes au jeu.
7. **Game Center n'est pas implémenté.** Décider de l'exclure du produit ou
   ajouter l'extension, les succès/classements, les capacités Apple et les tests
   sur appareil avant de le mentionner dans la fiche.
8. Remplacer `Auteur du projet` dans `LICENSE` et vérifier la propriété du nom,
   du logo et des illustrations — aucune recherche d'antériorité n'a été faite.
9. Préparer les icônes, captures d'écran et textes localisés des fiches App
   Store; vérifier le nom, la classification d'âge et les URLs de support.
10. Tester sur au moins un iPhone réel : achats Sandbox, restauration après
    réinstallation, pubs test, retour après absence, zones sûres, rotation,
    pause/reprise et export final.
11. Relancer `python3 tools/make_assets.py` seulement si vous changez la palette
    ou les assets générés.

### Ce qui a réellement été compilé ici

- `native/ads/build.sh macos` et `native/ads/build.sh ios` avec `NO_SDK=1` :
  stubs AdMob macOS, appareil iOS et simulateur iOS.
- `native/store/build.sh macos` et `native/store/build.sh ios` : le pont C++ et
  le Swift StoreKit, pour macOS, appareil iOS et simulateur iOS.
- Les extensions macOS ont été chargées par Godot (`test_native_load.gd`).
- **Non vérifié** : la branche iOS qui importe Google Mobile Ads, l'affichage
  réel d'une annonce, StoreKit contre les produits de votre compte, la signature
  IPA et la soumission Apple. Il faut le SDK, les IDs et les comptes réels.

### Le contrôle final, avant d'envoyer à Apple

```bash
./tests/run_all.sh                 # 846 vérifications, 0 échec attendu
zsh tools/fix_info_plist.sh        # à exécuter APRÈS chaque export
```

Builds sans AdMob (stubs) et StoreKit réel :

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
NO_SDK=1 native/ads/build.sh ios
native/store/build.sh ios
python3 tests/check_native_contract.py
```

Les cibles s'appellent `ios` (appareil et simulateur sont construits ensemble);
`target=ios_simulator` n'est pas un argument valide de ces scripts. Le build
AdMob de production nécessite en plus son framework et doit être fait sans
`NO_SDK=1`.

`fix_info_plist.sh` n'est pas optionnel : Godot 4.7 inscrit dans l'`Info.plist`
exporté dix clés d'autorisation iOS inutiles (caméra, micro, photothèque…) avec
des chaînes vides. Apple rejette une application qui déclare une autorisation
sans motif, et c'est un motif de refus direct à la revue.

Le `.gitignore` exclut `.godot/`, les dossiers d'export, les certificats
(`*.p12`, `*.mobileprovision`, `*.keystore`), les binaires d'extension
(`native/*/bin/`, `native/*/godot-cpp/`) et les artefacts système. Les
**tests sont versionnés** : ce sont eux qui garantissent que le jeu n'est pas
cassé au prochain changement, et `tests/run_all.sh` sort non-zéro en cas
d'échec, ce qui suffit pour une intégration continue.
