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
5. [Brancher un vrai SDK de publicité](#brancher-un-vrai-sdk-de-publicité)
6. [Brancher de vrais achats intégrés](#brancher-de-vrais-achats-intégrés)
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

276 vérifications réparties en 4 suites, toutes en headless :

```bash
./tests/run_all.sh                     # tout
./tests/run.sh res://tests/test_game.gd # une seule suite
```

| Suite | Ce qu'elle couvre |
|---|---|
| `test_bignum.gd` | Mantisse/exposant, comparaisons, formatage, grands nombres |
| `test_game.gd` | Économie, achat, sauvegarde, migration, hors-ligne, ascension, succès, boutique |
| `test_ui_compile.gd` | Instanciation réelle de `Main.tscn`, intégrité des 7 pages |
| `test_ui_interaction.gd` | Navigation, récolte, achats, popup hors-ligne, confirmation d'achat, remise à zéro |

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
  MainUI.gd              toute l'interface, construite en code (1 038 lignes)
  ui/Toast.gd            notifications éphémères
  ui/Modal.gd            fenêtres modales
  ui/FloatingNumber.gd   nombres flottants à la récolte
data/game_config.json    tout l'équilibrage
tools/make_assets.py     génère icon.png et assets/splash.png
tools/fix_info_plist.sh  nettoyage de l'Info.plist après export
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

## Brancher un vrai SDK de publicité

Le jeu ne connaît pas AdMob, ni Unity Ads, ni ironSource. Il appelle une
interface unique, `AdService`. Pour passer en réel :

**1. Écrivez une GDExtension exposant une classe `IdleAds`** :

```gdscript
# Interface attendue — c'est tout ce que le jeu appelle.
show_rewarded(reward_id: String) -> void   # démarre la pub
complete(reward_id: String) -> void       # récompense accordée → émet ad_completed
abort(reward_id: String) -> void          # pub interrompue → émet ad_failed
```

Le SDK doit émettre un signal vers le jeu quand la vidéo se termine réellement.
Le plug-in natif n'a pas besoin de connaître `GameManager` : il appelle
`Ads.complete(reward_id)`.

**2. Dans `game_config.json` :**

```json
"ads": {
  "enabled": true,
  "mock": false,
  "duration_seconds": 5.0
}
```

`mock: false` fait déléguer à `IdleAds`. Tant qu'aucun plug-in de ce nom
n'est enregistré, `AdService` retombe automatiquement sur la simulation plutôt
que de ne rien faire.

**3. Testez le parcours complet en leaving le mock actif.** L'overlay de
simulation porte le badge « PUB — SIMULATION » pour qu'on ne le confonde jamais
avec une vraie pub. Vous pouvez donc développer tout le tunnel de conversion
sans SDK.

### Points d'attention

- **Ne créditez la récompense qu'à `ad_completed`.** Jamais à `ad_started` : sur
  iOS l'utilisateur peut quitter la pub, et credited quand même, c'est ce qui
  fait désinstaller.
- **`is_available(reward_id)`** renvoie `false` si le joueur a acheté
  « Supprimer les pubs ». Ne contournez pas ce garde-fou.
- Les rewarded ads d'AdMob exigent un SDK mediation ; l'export Godot ne gère pas
  la mediation tout seul.

---

## Brancher de vrais achats intégrés

**Classe `IdleStore` attendue :**

```gdscript
load_products() -> void                    # remplit la liste des produits
purchase(product_id: String) -> void
restore() -> void
is_purchased(product_id: String) -> bool
```

Sur iOS, `product_id` correspond à un produit StoreKit réel. **Les
identifiants de `game_config.json` doivent correspondre exactement** à ceux
déclarés dans App Store Connect :

| Id interne | `product_id` StoreKit | Type |
|---|---|---|
| `supprimer_pubs` | `com.aurelien.idlegame.noads` | droit (achat unique) |
| `pack_decouverte` | `com.aurelien.idlegame.pack.decouverte` | consommable |
| `pack_cristaux_1` | `com.aurelien.idlegame.pack.t1` | consommable |
| `pack_cristaux_2` | `com.aurelien.idlegame.pack.t2` | consommable |
| `pack_cristaux_3` | `com.aurelien.idlegame.pack.t3` | consommable |
| `pack_cristaux_4` | `com.aurelien.idlegame.pack.t4` | consommable |

Un **droit** (type `entitlement`) ne s'achète qu'une fois et survit à une
remise à zéro. Un **consommable** peut être racheté.

> Les prix affichés dans `game_config.json` ne servent qu'à l'écran en mode
> simulation. En production, le prix affiché doit venir de StoreKit :/App Store
> Connect gère la conversion de devises et les prix par région.

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

- `user://idle_save.dat` — binaire, en-tête magique `IDLS`, `SAVE_VERSION := 2`
- `user://savegame.json` — ancien format, lu et migré automatiquement au premier
  lancement vers la version 2, puis sauvegardé une fois en copie de sécurité

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

1. **Choisir le réseau publicitaire** et écrire le plug-in `IdleAds` (§ 5).
2. **Créer les produits réels** dans App Store Connect avec les identifiants
   exacts du tableau (§ 6).
3. **Remplacer le bundle identifier** `com.aurelien.idlegame` par le vôtre, dans
   `project.godot` **et** dans chaque `product_id` de `game_config.json`.
4. **Renseigner l'équipe de signature** dans `export_presets.cfg`.
5. **Écrire le plug-in `IdleNotifications`** si vous voulez des notifications
   système réelles (§ 7).
6. Remplacer `Auteur du projet` dans `LICENSE`.
7. Vérifier le nom et le logo de l'application — le nom de ce modèle n'est pas
   protégé par une recherche d'antériorité, et « Idle Crystal Corp » est
   très probablement déjà pris.
8. Relaunch `python3 tools/make_assets.py` si vous changez la palette.

```bash
git init && git add -A && git commit -m "Idle Crystal Corp — base complète"
```

Le `.gitignore` exclut `.godot/`, les dossiers d'export, les certificats
(`*.p12`, `*.mobileprovision`, `*.keystore`) et les artefacts système. Les
tests **sont** versionnés : ce sont eux qui garantissent que le jeu n'est pas
cassé au prochain changement.
