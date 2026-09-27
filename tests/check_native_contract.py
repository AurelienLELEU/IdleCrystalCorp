#!/usr/bin/env python3
"""Vérifie la cohérence des frontières entre C++, C, Objective-C++ et Swift.

    python3 tests/check_native_contract.py

Ce contrôle ne remplace PAS la compilation : il vérifie ce qu'une compilation
ne rattrape pas de lisible. Une GDExtension se charge, l'extension s'enregistre,
et le jeu « fonctionne » — puis plante à la première pub parce que le nom d'une
fonction diffère d'une lettre entre le `.h` et le `.mm`. Aucun message d'erreur
ne pointe vers la cause réelle.

Ce que le script contrôle, sur les quatre frontières :

  1. Toute fonction déclarée dans un en-tête C est définie dans son implémentation.
  2. Toute fonction appelée depuis le C++ est déclarée dans l'en-tête C.
  3. Les signatures (nombre et type de paramètres) concordent partout.
  4. Chaque `@_silgen_name` du Swift a une définition `extern "C"` en C++.
  5. Chaque `D_METHOD` de godot-cpp correspond à une méthode déclarée dans le
     header de la classe — un nom de méthode typé de travers ne compile pas
     chez godot-cpp, mais donne un message trompeur.

Aucune dépendance : uniquement la bibliothèque standard.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Une déclaration C : type de retour, nom, paramètres.
# Le type peut contenir des espaces (const char *) ou des étoiles.
C_SIGNATURE = re.compile(
    r"^\s*(?:const\s+)?[A-Za-z_][\w\s\*]*?\**\s*"
    r"(?P<name>idle_\w+)\s*\((?P<args>[^;{)]*)\)\s*;",
    re.MULTILINE,
)
# Une définition C : même forme, mais terminée par un corps ou une accolade.
C_DEFINITION = re.compile(
    r"^(?:int|void|const char \*)\s*(?P<name>idle_\w+)\s*\((?P<args>[^;{)]*)\)",
    re.MULTILINE,
)
SWIFT_DEF = re.compile(r"^public func (?P<name>idle_\w+)\s*\((?P<args>[^)]*)\)", re.MULTILINE)
SILGEN = re.compile(r'@_silgen_name\("(?P<name>\w+)"\)')
CXX_DEF = re.compile(
    r"^void (?P<name>idle_\w+)\s*\((?P<args>[^;{)]*)\)", re.MULTILINE
)
DMETHOD = re.compile(r'D_METHOD\("(?P<method>\w+)"(?:,\s*"(?P<arg>\w+)")?')
CPP_METHOD_DECL = re.compile(
    r"^\s*(?:void|bool|String|int|double|float)\s+(?P<name>\w+)\s*\(", re.MULTILINE
)


class Report:
    def __init__(self):
        self.errors: list[str] = []
        self.checks = 0

    def check(self, ok: bool, label: str, detail: str = "") -> None:
        self.checks += 1
        if not ok:
            self.errors.append(f"{label}{'  ->  ' + detail if detail else ''}")


def args_of(text: str) -> int:
    """Nombre de paramètres déclarés."""
    return len(params_of(text))


def params_of(text: str) -> list:
    """Paramètres déclarés, sous forme de (type canonique, nom).

    Deux langages, deux syntaxes :

      C      ``const char *p_reason``
      Swift  ``_ p_reason: UnsafePointer<CChar>?``

    L'étiquette externe `_` de Swift ne porte aucune information : seul le nom
    déclaré compte.
    """
    out = []
    for raw in text.split(","):
        part = re.sub(r"\s+", " ", raw.strip())
        if not part or part == "void":
            continue
        if ":" in part:
            # Swift : `étiquette nom: Type`. L'étiquette peut être multiple
            # (`from productID: String`) : seul le dernier identifiant est le nom.
            #
            # Le motif exige un identifiant AVANT le deux-points et refuse le
            # deux-points de portée C++, sinon « godot::String p_reason » serait
            # lu comme une étiquette vide suivie du type « :String p_reason ».
            swift = re.match(r"^(?P<label>[A-Za-z_][\w ]*?)\s*:\s*(?!:)(?P<type>.+)$", part)
            if swift:
                words = swift.group("label").split()
                out.append((canonical_type(swift.group("type")), words[-1] if words else ""))
                continue
        # C : le nom est le dernier identifiant, précédé du type et d'éventuels
        # `*`. `const char *` seul (sans nom) doit aussi passer.
        match = re.match(r"^(?P<type>.*?)(?P<name>[A-Za-z_]\w*)$", part)
        if match:
            out.append((canonical_type(match.group("type")), match.group("name")))
        else:
            out.append((canonical_type(part), ""))
    return out


# `UnsafePointer<CChar>?` et `const char *` sont le même type : C n'a pas de
# nullabilité, donc un pointeur Swift optionnel se projette sur un pointeur C
# pouvant valoir NULL. C'est bien la même convention que celle déjà employée
# dans les deux couches, mais l'ignorer ferait crier le script quatre fois sur
# du code parfaitement correct.
SWIFT_TO_C = {
    "UnsafePointer<CChar>": "const char *",
    "UnsafePointer<CChar>?": "const char *",
    "UnsafeMutablePointer<CChar>": "char *",
    "UnsafeMutablePointer<CChar>?": "char *",
    "Int32": "int",
    "UInt32": "unsigned int",
    "Int": "long",
    "Bool": "bool",
    "Double": "double",
    "String": "const char *",
}


def canonical_type(text: str) -> str:
    """Ramène les variantes d'écriture d'un même type à une forme unique.

    `const char *`, `char const *` et `char * const` sont le même type ; `int`
    et `const int` non. Sans ce regroupement, la comparaison de signatures
    signalerait des différences là où il n'y en a pas — et l'on apprendrait à
    ignorer les avertissements, donc à ignorer les vraies divergences.
    """
    t = re.sub(r"\s+", " ", text.strip())
    if t in SWIFT_TO_C:
        return SWIFT_TO_C[t]

    tokens = t.replace("*", " * ").split()
    pointers = tokens.count("*")
    words = [w for w in tokens if w != "*"]
    n_const = words.count("const")
    base = " ".join(w for w in words if w != "const")

    out = " ".join(["const"] * n_const + [base]).strip()
    if pointers:
        out = (out + " " + "*" * pointers).strip()
    return out


def sig_of(text: str) -> str:
    """Signature complète, pour un message d'erreur lisible."""
    return ", ".join(f"{t} {n}".strip() for t, n in params_of(text)) or "void"


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def check_ads(rep: Report) -> None:
    header = read("native/ads/ios/idle_ads_ios.h")
    impl = read("native/ads/ios/idle_ads_ios.mm")
    cpp = read("native/ads/src/idle_ads.cpp")
    cls_h = read("native/ads/src/idle_ads.h")

    _check_both_directions(
        rep,
        label="IdleAds",
        header=header,
        impl=impl,
        impl_def=C_DEFINITION,
        impl_name="idle_ads_ios.mm",
        cpp=cpp,
        # Le .mm appelle les passerelles par leur vrai nom, sans passerelle
        # intermédiaire : on relève donc tous les idle_ads_bridge_* qu'il cite.
        cpp_called_bridges=set(re.findall(r"\b(idle_ads_bridge_\w+)\s*\(", impl)),
        native_bridges=set(),
    )
    _check_dmethods(rep, cpp, cls_h, "IdleAds")


def check_store(rep: Report) -> None:
    header = read("native/store/ios/idle_store_ios.h")
    swift = read("native/store/ios/idle_store_ios.swift")
    cpp = read("native/store/src/idle_store.cpp")
    cls_h = read("native/store/src/idle_store.h")

    # En Swift, les passerelles ne sont pas des fonctions : ce sont des
    # déclarations @_silgen_name sans corps, dont le symbole doit exister en C++.
    native_bridges = set(SILGEN.findall(swift))
    cpp_called_bridges = {
        m.group(1)
        for m in re.finditer(r"@_silgen_name\(\"(?P<name>idle_store_bridge_\w+)\"\)", swift)
    }
    # Les enveloppes Swift content des appels bridge_*(...) qu'il ne faut pas
    # confondre avec les noms de symboles : seules les déclarations comptent.
    _check_both_directions(
        rep,
        label="IdleStore",
        header=header,
        impl=swift,
        impl_def=SWIFT_DEF,
        impl_name="idle_store_ios.swift",
        cpp=cpp,
        cpp_called_bridges=cpp_called_bridges,
        native_bridges=native_bridges,
    )
    _check_dmethods(rep, cpp, cls_h, "IdleStore")


def check_notifications(rep: Report) -> None:
    """Vérifie la frontière C++/Swift du rappel local UserNotifications."""
    header = read("native/notifications/ios/idle_notifications_ios.h")
    swift = read("native/notifications/ios/idle_notifications_ios.swift")
    cpp = read("native/notifications/src/idle_notifications.cpp")
    cls_h = read("native/notifications/src/idle_notifications.h")
    native_bridges = set(SILGEN.findall(swift))
    cpp_called_bridges = {
        m.group(1)
        for m in re.finditer(
            r'@_silgen_name\("(?P<name>idle_notifications_bridge_\w+)"\)', swift)
    }
    _check_both_directions(
        rep,
        label="IdleNotifications",
        header=header,
        impl=swift,
        impl_def=SWIFT_DEF,
        impl_name="idle_notifications_ios.swift",
        cpp=cpp,
        cpp_called_bridges=cpp_called_bridges,
        native_bridges=native_bridges,
    )
    _check_dmethods(rep, cpp, cls_h, "IdleNotifications")


def _check_both_directions(
    rep: Report,
    *,
    label: str,
    header: str,
    impl: str,
    impl_def: re.Pattern,
    impl_name: str,
    cpp: str,
    cpp_called_bridges: set,
    native_bridges: set,
) -> None:
    """Vérifie les deux sens de la frontière entre le C++ et la couche iOS.

    Une frontière a toujours deux sens, et les confondre est l'erreur classique :

      - **actions**   C++  -> iOS   : déclarées dans l'en-tête C, définies dans
                                     le `.mm` (ou le `.swift`), appelées depuis
                                     le `.cpp`.
      - **passerelles** iOS -> C++  : déclarées dans l'en-tête C, définies en
                                     `extern "C"` dans le `.cpp`, appelées depuis
                                     la couche iOS.

    Un en-tête qui déclare une action sans définition compile quand même sur
    certaines plateformes, et le lien échoue au pire moment sur l'appareil.
    """
    declared = {m.group("name"): m.group("args") for m in C_SIGNATURE.finditer(header)}
    actions = {n for n in declared if "_bridge_" not in n}
    bridges = {n for n in declared if "_bridge_" in n}

    defined_in_impl = {m.group("name"): m.group("args") for m in impl_def.finditer(impl)}
    defined_in_cpp = {m.group("name"): m.group("args") for m in CXX_DEF.finditer(cpp)}
    called_from_cpp = set(re.findall(r"\b(idle_(?:ads|store|notifications)_ios_\w+)\s*\(", cpp))

    # --- sens 1 : C++ -> iOS ------------------------------------------------
    for name in sorted(actions):
        rep.check(name in defined_in_impl, f"{label} : {name} déclaré mais non défini",
                  f"absent de {impl_name}")
        if name in defined_in_impl:
            _compare_signature(rep, label, name, declared[name], defined_in_impl[name], impl_name)
        rep.check(name in called_from_cpp, f"{label} : {name} n'est jamais appelé",
                  "le C++ ne s'en sert pas : l'en-tête ment sur l'API")

    for name in sorted(called_from_cpp - set(declared)):
        rep.check(False, f"{label} : {name} appelé sans être déclaré",
                  f"absent de l'en-tête C")

    # --- sens 2 : iOS -> C++ ------------------------------------------------
    for name in sorted(bridges):
        rep.check(name in defined_in_cpp, f"{label} : passerelle {name} sans définition C++",
                  "absente du .cpp")
        if name in defined_in_cpp:
            _compare_signature(rep, label, name, declared[name], defined_in_cpp[name], ".cpp")
        rep.check(name in cpp_called_bridges or name in native_bridges,
                  f"{label} : passerelle {name} n'est jamais appelée",
                  f"{impl_name} ne la cite pas : elle est du code mort")

    # Toute passerelle citée par la couche iOS doit exister, et réciproquement.
    # `@_silgen_name` déclare le symbole côté Swift sans passer par l'en-tête C,
    # ce qui est un choix légitime : c'est alors la déclaration Swift qui fait
    # foi, et il faut quand même que le C++ la définisse.
    for name in sorted(cpp_called_bridges - bridges - native_bridges):
        rep.check(False, f"{label} : la couche iOS appelle une passerelle absente",
                  f"{name} n'est ni déclarée dans l'en-tête C, ni en @_silgen_name")
    for name in sorted(set(defined_in_cpp) - bridges - native_bridges):
        rep.check(False, f"{label} : passerelle C++ {name} jamais utilisée",
                  "ni déclarée dans l'en-tête, ni citée par la couche iOS")


def _compare_signature(
    rep: Report, label: str, name: str, declared_raw: str, defined_raw: str, where: str
) -> None:
    """Compare deux signatures, en nommant le paramètre fautif.

    Comparer seulement le nombre de paramètres laisse passer le pire cas : un
    `int` devenu `long` entre l'en-tête et la définition est invisible au
    compte, et c'est un bug d'ABI qui corrompt la pile au premier appel.
    """
    want = params_of(declared_raw)
    got = params_of(defined_raw)

    rep.check(len(want) == len(got),
              f"{label} : {name} a un nombre de paramètres différent",
              f"{len(want)} déclaré ({sig_of(declared_raw)}), "
              f"{len(got)} défini dans {where} ({sig_of(defined_raw)})")
    for i in range(min(len(want), len(got))):
        want_type, want_name = want[i]
        got_type, got_name = got[i]
        rep.check(want_type == got_type,
                  f"{label} : {name} paramètre {i + 1} ({want_name}) a un type différent",
                  f"« {want_type} » déclaré, « {got_type} » dans {where}")


def _check_dmethods(rep: Report, cpp: str, cls_h: str, label: str) -> None:
    """Chaque D_METHOD doit correspondre à une méthode déclarée dans la classe.

    godot-cpp prend l'adresse de la méthode : un nom erroné ne compile pas, mais
    le message d'erreur ne cite que le nom fautif, sans dire que la méthode
    existe sous un autre nom dans le header.
    """
    declared = set(CPP_METHOD_DECL.findall(cls_h))
    for match in re.finditer(r'D_METHOD\("(\w+)"[^)]*\)[^;]*&(\w+)::(\w+)', cpp):
        method, cls, target = match.group(1), match.group(2), match.group(3)
        rep.check(target in declared,
                  f"{label} : D_METHOD(\"{method}\") pointe vers une méthode absente",
                  f"{cls}::{target} non déclaré dans le header")
        rep.check(target == method,
                  f"{label} : D_METHOD(\"{method}\") et la méthode {target} diffèrent",
                  "le nom exposé à GDScript ne correspond pas au nom C++")

# --- Le manifeste .gdextension ---------------------------------------------
#
# L'entrée [libraries] est le SEUL endroit où Godot apprend où trouver la
# bibliothèque. Rien ne la vérifie : une entrée fausse produit une extension
# qui compile, un manifeste qui s'active, et un dlopen qui échoue au lancement
# — sans que le build ne soit en cause. C'est arrivé ici trois fois de suite
# (macOS en .framework au lieu de .dylib, le simulateur en « arm64-simulator »
# au lieu du nom réel, et le dossier de sortie native/bin/ au lieu de
# native/<ext>/bin/).
#
# Plutôt que de comparer le manifeste à ce qui se trouve sur le disque — ce
# qui ne peut rien dire tant que rien n'a été compilé — on le compare à la RÈGLE
# qui produit les noms, recopiée depuis godot-cpp/tools/godotcpp.py :
#
#     suffixe = ".<plateforme>.<cible>[.dev][.double].<arch>[.simulator][.nothreads]"
#
# Vérifier la règle, et non le résultat, attrape l'erreur même sur une machine
# où l'extension n'a jamais été compilée.

# Étiquettes de plateforme -> (plateforme scons, architecture, simulateur)
# Le « .simulator » et le suffixe d'arch ne sont PAS les mêmes notions : scons
# ne connaît ni « arm64-simulator » ni « universal.simulator » comme arch, et
# l'étiquette du manifeste, elle, emploie bien « arm64-simulator ».
MANIFEST_TAGS = {
    "macos.debug": ("macos", "template_debug", "universal", False),
    "macos.release": ("macos", "template_release", "universal", False),
    "ios.debug.arm64": ("ios", "template_debug", "arm64", False),
    "ios.release.arm64": ("ios", "template_release", "arm64", False),
    "ios.debug.arm64-simulator": ("ios", "template_debug", "universal", True),
    "ios.release.arm64-simulator": ("ios", "template_release", "universal", True),
    "ios.debug.x86_64-simulator": ("ios", "template_debug", "universal", True),
    "ios.release.x86_64-simulator": ("ios", "template_release", "universal", True),
}

# La valeur est capturée BRUTE, préfixe res:// compris ou non : exiger le
# préfixe dans la regex reviendrait à ignorer silencieusement l'entrée fautive
# au lieu de la signaler.
LIBS_ENTRY = re.compile(r'^(\S+)\s*=\s*"([^"]+)"\s*$', re.MULTILINE)


def check_manifest(rep: Report, name: str, lib: str) -> None:
    manifest_names = {
        "ads": "IdleAds.gdextension.dist",
        "store": "IdleStore.gdextension.dist",
        "notifications": "IdleNotifications.gdextension.dist",
    }
    dist = ROOT / "native" / name / manifest_names.get(name, "")
    if not dist.exists():
        rep.check(False, f"{name} : manifeste .dist présent",
                  f"{dist} introuvable")
        return
    text = dist.read_text(encoding="utf-8")

    # Le préfixe res:// est conservé : c'est lui que Godot résout, et le
    # perdre ferait comparer des chemins différents sans qu'on le voie.
    entries = {m.group(1): m.group(2) for m in LIBS_ENTRY.finditer(text)}
    label = f"{name} : manifeste"

    # 1. Les étiquettes couvertes par build.sh, et elles seules.
    built = set(entries) & set(MANIFEST_TAGS)
    for tag in sorted(set(MANIFEST_TAGS) - set(entries)):
        rep.check(False, f"{label} : l'étiquette {tag} est déclarée",
                  "absente de [libraries] alors que build.sh la produit")

    # 2. Chaque chemin suit la règle de suffixe de godot-cpp.
    for tag, (platform, target, arch, simulator) in MANIFEST_TAGS.items():
        path = entries.get(tag)
        if path is None:
            continue
        suffix = f".{platform}.{target}.{arch}" + (".simulator" if simulator else "")
        expected = f"res://native/{name}/bin/lib{lib}{suffix}.dylib"
        rep.check(path == expected, f"{label} : {tag} suit la règle de suffixe",
                  f"attendu {expected}, trouvé {path}")
        rep.check(path.startswith("res://"),
                  f"{label} : {tag} est bien une res://",
                  f"« {path} » ne commence pas par res:// — Godot ne la résout pas")

    # 3. Le manifeste actif, s'il existe, doit être identique au .dist : c'est
    #    une copie faite par build.sh, et une copie périmée échoue au
    #    chargement sans que le dépôt ne montre rien.
    active = dist.with_suffix("")  # enlève .dist
    if active.exists():
        rep.check(active.read_text(encoding="utf-8") == text,
                  f"{label} : le manifeste actif est à jour",
                  f"{active.name} diffère du .dist — relancez build.sh")

    # 4. Si des binaires existent, ils doivent être exactement ceux annoncés.
    bin_dir = ROOT / "native" / name / "bin"
    if bin_dir.is_dir() and any(bin_dir.iterdir()):
        for tag, path in entries.items():
            if not path.startswith("res://"):
                continue
            on_disk = ROOT / path[len("res://"):]
            rep.check(on_disk.exists(), f"{label} : {tag} pointe un fichier réel",
                      f"{path} absent (extension compilée ?)")



# --- La liste d'interface du test de chargement ----------------------------
#
# tests/test_native_load.gd annonce, pour chaque classe, les méthodes et les
# signaux qu'il vérifiera dans ClassDB au chargement réel de la bibliothèque.
# Cette liste est une COPIE : elle dérive un jour, et le jour où elle dérive le
# test échoue pour une raison qui n'a rien à voir avec le code — ou pire, il
# passe en vérifiant des noms que personne n'appelle.
#
# La confronter aux D_METHOD et ADD_SIGNAL du .cpp rend la dérive impossible :
# c'est le seul endroit où les deux versions de l'interface se rencontrent, le
# C++ n'étant pas introspectable depuis Python. Elle a déjà dérivé une fois : la
# première version annonçait IdleStore.is_available(), configure() et le signal
# purchases_restored, trois noms qui n'ont jamais existé.
LOAD_TEST = ROOT / "tests" / "test_native_load.gd"
TEST_CLASS_BLOCK = re.compile(r'const CLASSES := \{(.*?)\n\}', re.DOTALL)
TEST_METHODS = re.compile(r'"methods":\s*\[(.*?)\]', re.DOTALL)
TEST_SIGNALS = re.compile(r'"signals":\s*\[(.*?)\]', re.DOTALL)
TEST_NAMES = re.compile(r'"([a-z_]+)"')


def _cpp_exposed(cpp: str) -> tuple:
    """(méthodes, signaux) effectivement exposés à GDScript par un .cpp."""
    methods = set(re.findall(r'D_METHOD\("(\w+)"', cpp))
    signals = set(re.findall(r'ADD_SIGNAL\(MethodInfo\("(\w+)"', cpp))
    return methods, signals


def _declared_interface() -> dict:
    block = TEST_CLASS_BLOCK.search(LOAD_TEST.read_text(encoding="utf-8"))
    if block is None:
        return {}
    body = block.group(1)
    declared = {}
    for entry in re.finditer(r'"(\w+)":\s*\{', body):
        chunk = body[entry.end():]
        methods = TEST_METHODS.search(chunk)
        signals = TEST_SIGNALS.search(chunk)
        declared[entry.group(1)] = (
            set(TEST_NAMES.findall(methods.group(1))) if methods else set(),
            set(TEST_NAMES.findall(signals.group(1))) if signals else set(),
        )
    return declared


def check_load_test_list(rep: Report) -> None:
    if not LOAD_TEST.exists():
        rep.check(False, "test de chargement : le fichier existe", f"{LOAD_TEST} introuvable")
        return
    declared = _declared_interface()
    rep.check(bool(declared), "test de chargement : const CLASSES est déclaré",
              "constante introuvable — plus aucune classe ne serait testée")

    for cpp_rel, klass in (("native/ads/src/idle_ads.cpp", "IdleAds"),
                           ("native/store/src/idle_store.cpp", "IdleStore"),
                           ("native/notifications/src/idle_notifications.cpp", "IdleNotifications")):
        methods, signals = _cpp_exposed(read(cpp_rel))
        rep.check(klass in declared, f"test de chargement : {klass} est déclaré",
                  "absent de const CLASSES — cette classe ne sera jamais testée")
        if klass not in declared:
            continue
        want_m, want_s = declared[klass]
        rep.check(want_m == methods,
                  f"test de chargement : les méthodes de {klass} sont exactes",
                  f"en trop {sorted(want_m - methods)} / en manque {sorted(methods - want_m)}")
        rep.check(want_s == signals,
                  f"test de chargement : les signaux de {klass} sont exacts",
                  f"en trop {sorted(want_s - signals)} / en manque {sorted(signals - want_s)}")


def _without_comments(source: str) -> str:
    """Retire les commentaires pour qu'un commentaire explicatif ne passe pas."""
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", source)


def check_native_runtime_safety(rep: Report) -> None:
    """Contrats runtime que l'édition de liens ne peut pas vérifier.

    Le build local utilise `NO_SDK=1` : il compile volontairement les stubs et
    n'analyse jamais la branche GMA/StoreKit réelle. Ces contrôles verrouillent
    donc les invariants critiques du code iOS, sans prétendre remplacer un build
    contre les SDK propriétaires.
    """
    ads = _without_comments(read("native/ads/ios/idle_ads_ios.mm"))
    store_cpp = _without_comments(read("native/store/src/idle_store.cpp"))
    store_h = _without_comments(read("native/store/src/idle_store.h"))
    store_swift = _without_comments(read("native/store/ios/idle_store_ios.swift"))
    store_service = _without_comments(read("core_engine/StoreService.gd"))
    project = _without_comments(read("project.godot"))
    store_start = store_swift.split("public func idle_store_ios_start", 1)[1].split(
        '@_cdecl("idle_store_ios_purchase")', 1)[0]
    store_restore = store_swift.split("public func idle_store_ios_restore", 1)[1].split(
        '@_cdecl("idle_store_ios_is_purchased")', 1)[0]
    ads_service = _without_comments(read("core_engine/AdService.gd"))
    notifications_swift = _without_comments(
        read("native/notifications/ios/idle_notifications_ios.swift"))
    notifications_service = _without_comments(read("core_engine/NotificationService.gd"))

    rep.check('kAdMobSampleRewardedUnit = @"ca-app-pub-3940256099942544/1712485313"' in ads,
              "AdMob iOS : l'unité de test est le format Rewarded iOS",
              "5224354917 est l'unité de test Android")
    rep.check('application/admob_rewarded_unit_id="ca-app-pub-3940256099942544/1712485313"' in project,
              "project.godot : l'identifiant Rewarded de test est bien celui d'iOS",
              "le projet déclarait encore l'identifiant Android 5224354917")
    rep.check(bool(re.search(
        r"s_rewarded_unit\s*=\s*\(p_debug\s*\|\|\s*unit\.length\s*==\s*0\)\s*\?\s*kAdMobSampleRewardedUnit\s*:\s*unit",
        ads)),
        "AdMob : debug force l'unité de test, même avec un identifiant configuré",
        "le seul device de test déclaré est Simulator; un iPhone physique recevrait des pubs réelles")
    rep.check("status.adapterStatusesByClassName" in ads
              and "GADAdapterInitializationStateReady" in ads
              and "status.adErrors" not in ads,
              "AdMob : l'initialisation lit l'API GADInitializationStatus réelle",
              "GADInitializationStatus n'expose pas adErrors")
    rep.check('if (!s_ads_ready) {' in ads
              and 'idle_ads_bridge_failed([reward UTF8String], "SDK AdMob pas prêt");' in ads,
              "AdMob : SDK non prêt renvoie un échec au jeu",
              "un simple return laisserait Ads._busy vrai pour toujours")
    rep.check('if (s_loading || s_pending_reward_id != nil) {' in ads
              and 'idle_ads_bridge_failed([reward UTF8String], "une publicité est déjà en cours");' in ads,
              "AdMob : demande concurrente refusée explicitement",
              "un retour silencieux bloque le bouton de pub dans AdService")
    rep.check("userDidEarnRewardHandler:" in ads and "s_reward_earned = YES" in ads,
              "AdMob : la preuve de récompense vient du callback dédié",
              "la fermeture de la vidéo seule ne prouve pas que la récompense est due")
    rep.check(bool(re.search(r"if\s*\(earned\s*\)\s*\{\s*idle_ads_bridge_completed",
                             ads, re.DOTALL)),
              "AdMob : rewarded_completed est conditionné à la récompense réellement acquise",
              "adDidDismissFullScreenContent seul ne doit jamais créditer")
    rep.check("dispatch_after" in ads and "request_generation != s_load_generation" in ads
              and "request.timeout" not in ads,
              "AdMob : le chargement a un timeout valable et ignore les callbacks tardifs",
              "GADRequest n'expose pas de propriété timeout")
    rep.check("canPresentFromRootViewController" in ads and "presenter == nil" in ads,
              "AdMob : l'absence de contrôleur présentable est traitée avant present()",
              "présenter depuis nil peut laisser la récompense bloquée")
    rep.check("[reward UTF8String]" in ads and ".utf8().get_data()" not in ads,
              "Objective-C++ : les NSString traversent la frontière avec UTF8String",
              "NSString n'a pas la méthode Godot String utf8().get_data()")

    rep.check("UnsafeMutablePointer<CChar>.allocate(capacity: 512)" in store_swift
              and "return UnsafePointer(s_price_buffer)" in store_swift
              and "withUnsafeBufferPointer" not in store_swift,
              "StoreKit : le pointeur du prix reste valide après le retour Swift",
              "un pointeur obtenu dans withUnsafeBufferPointer expire à la fin de la closure")
    rep.check("~IdleStore();" in store_h
              and "IdleStore::~IdleStore()" in store_cpp
              and "s_store = nullptr" in store_cpp,
              "IdleStore : le pont statique est invalidé à la destruction",
              "une tâche StoreKit tardive ne doit pas déréférencer un Object libéré")
    rep.check("configured = idle_store_ios_start" in store_cpp,
              "IdleStore : is_configured reflète le démarrage effectif du pont",
              "configured restait toujours false")
    for label, source in (("IdleAds", ads_service), ("IdleStore", store_service)):
        rep.check("func _exit_tree()" in source and "plugin.free()" in source
                  and "_plugin = null" in source,
                  f"{label} : l'Object natif est libéré quand son service quitte l'arbre",
                  "ClassDB.instantiate() produit un Object non-RefCounted; perdre la référence ne le détruit pas")
    rep.check("Task { @MainActor in" in store_start
              and "Transaction.currentEntitlements" in store_start
              and "s_entitlements.insert(transaction.productID)" in store_start
              and store_start.index("Transaction.currentEntitlements")
                  < store_start.index("bridge_products_loaded(products.count)"),
              "StoreKit : les droits existants sont chargés avant l'état catalogue prêt",
              "Transaction.updates ne recharge pas à lui seul les droits existants au démarrage")
    rep.check("active_entitlements += 1" in store_restore
              and "bridge_restored(active_entitlements)" in store_restore
              and "if !s_entitlements.contains" not in store_restore,
              "StoreKit : restauration compte tous les droits actifs, pas seulement les nouveaux",
              "après le chargement au démarrage, compter seulement les droits nouveaux disait « aucun »")
    rep.check('reason.begins_with("paiement en attente")' in store_service
              and 'GameManager.notify(reason, "info")' in store_service,
              "StoreKit : un achat pending est informatif, pas un toast d'échec",
              "StoreKit peut confirmer ce paiement plus tard via Transaction.updates")
    rep.check("UNTimeIntervalNotificationTrigger" in notifications_swift
              and "UNNotificationRequest" in notifications_swift
              and "UserNotifications" in notifications_swift,
              "IdleNotifications : utilise un déclencheur local système",
              "le rappel de 2 h doit survivre à la suspension sans serveur/APNs")
    rep.check('"idle_reminder"' in notifications_service
              and '"notify_after_hours": 2.0' in read("data/game_config.json"),
              "rappel hors-ligne : identifiant stable et délai par défaut de 2 h",
              "reprogrammer ne doit pas empiler des rappels")
    rep.check("requestAuthorization" in notifications_swift
              and "permission_changed" in notifications_swift
              and '_permission != "granted"' in notifications_service,
              "IdleNotifications : demande l'autorisation et attend le vrai résultat",
              "un plugin présent n'implique pas que l'utilisateur a autorisé les notifications")
    rep.check("schedule_completed" in notifications_swift
              and "schedule_completed" in notifications_service
              and "reminder_scheduled.emit" in notifications_service
              and "raw_schedule_completed(raw_id, success ? 1 : 0, raw_reason)"
                  in notifications_swift,
              "IdleNotifications : confirme le succès asynchrone de UNUserNotificationCenter",
              "ne pas annoncer un rappel programmé avant le callback système")
    rep.check(notifications_swift.count("s_generation[identifier] == generation") >= 1
              and "s_generation[identifier] = (s_generation[identifier] ?? 0) + 1" in notifications_swift,
              "IdleNotifications : ignore un callback de programmation après annulation",
              "un retour rapide au jeu ne doit pas laisser un rappel ancien se recréer")
    rep.check("openSettingsURLString" in notifications_swift
              and 'Notifications.open_settings()' in read("scenes/MainUI.gd"),
              "IdleNotifications : un refus système ouvre Réglages iOS",
              "iOS ne réaffiche pas le dialogue d'autorisation après un refus")
    rep.check('notifications.cancel_all()' in _without_comments(
                  read("core_engine/GameManager.gd"))
              and "removeAllPendingNotificationRequests" in notifications_swift,
              "rappel local : annule l'échéance si le joueur revient avant 2 h",
              "sinon la notification arrive alors que le jeu est déjà ouvert")


def main() -> int:
    rep = Report()
    check_ads(rep)
    check_store(rep)
    check_notifications(rep)
    check_manifest(rep, "ads", "idle_ads")
    check_manifest(rep, "store", "idle_store")
    check_manifest(rep, "notifications", "idle_notifications")
    check_load_test_list(rep)
    check_native_runtime_safety(rep)

    print(f"== Contrat natif : {rep.checks} vérifications, {len(rep.errors)} échecs ==")
    for error in rep.errors:
        print(f"  ECHEC  {error}")
    return 1 if rep.errors else 0


if __name__ == "__main__":
    sys.exit(main())
