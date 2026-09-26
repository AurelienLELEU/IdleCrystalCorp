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


def main() -> int:
    rep = Report()
    check_ads(rep)
    check_store(rep)

    print(f"== Contrat natif : {rep.checks} vérifications, {len(rep.errors)} échecs ==")
    for error in rep.errors:
        print(f"  ECHEC  {error}")
    return 1 if rep.errors else 0


if __name__ == "__main__":
    sys.exit(main())
