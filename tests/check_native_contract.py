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
    called_from_cpp = set(re.findall(r"\b(idle_(?:ads|store)_ios_\w+)\s*\(", cpp))

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
    dist = ROOT / "native" / name / ("IdleAds.gdextension.dist" if name == "ads"
                                     else "IdleStore.gdextension.dist")
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
                           ("native/store/src/idle_store.cpp", "IdleStore")):
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


def main() -> int:
    rep = Report()
    check_ads(rep)
    check_store(rep)
    check_manifest(rep, "ads", "idle_ads")
    check_manifest(rep, "store", "idle_store")
    check_load_test_list(rep)

    print(f"== Contrat natif : {rep.checks} vérifications, {len(rep.errors)} échecs ==")
    for error in rep.errors:
        print(f"  ECHEC  {error}")
    return 1 if rep.errors else 0


if __name__ == "__main__":
    sys.exit(main())
