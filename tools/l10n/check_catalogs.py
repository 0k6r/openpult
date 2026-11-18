#!/usr/bin/env python3
"""Checks the app's String Catalogs (*.xcstrings) and that Swift sources contain no untranslated Russian text.

Usage: python3 tools/l10n/check_catalogs.py [--root DIR] [--stringsdata DERIVED_DATA]

English is the source language, Russian a full translation. The check fails when:
- a key that should be translated has no Russian value in state "translated";
- format specifiers (%@, %lld, %1$@ ...) differ between the English source and the Russian text;
- a Russian plural lacks one of one/few/many/other, or an English plural lacks one/other;
- Swift code under app/Pult or app/BraviaKit/Sources has Cyrillic outside comments (files in ALLOW_CYRILLIC aside);
- an INFOPLIST_KEY_* build setting differs from the English value in InfoPlist.xcstrings.
With --stringsdata it also fails when a string the compiler extracted (*.stringsdata in a DerivedData folder,
built with SWIFT_EMIT_LOC_STRINGS=YES) is missing from the catalog next to its source file.
"""
import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
SOURCE_LANGUAGE = "en"
TRANSLATIONS = ("ru",)
SOURCE_DIRS = ("app/Pult", "app/BraviaKit/Sources")
CATALOG_DIR = "app"
REQUIRED_CATALOGS = (
    "app/Pult/Localizable.xcstrings",
    "app/Pult/InfoPlist.xcstrings",
    "app/BraviaKit/Sources/BraviaKit/Resources/Localizable.xcstrings",
)
INFOPLIST_CATALOG = "app/Pult/InfoPlist.xcstrings"
XCODE_PROJECT = "app/Pult.xcodeproj/project.pbxproj"
SKIP_DIRS = {"build", ".build", "DerivedData"}

# Files that may still contain Russian text. The check prints a note when an entry is no longer needed.
ALLOW_CYRILLIC: set[str] = set()

# CLDR plural categories that a translation must provide.
PLURAL_FORMS = {"en": {"one", "other"}, "ru": {"one", "few", "many", "other"}}
KNOWN_PLURAL_FORMS = {"zero", "one", "two", "few", "many", "other"}

CYRILLIC = re.compile("[Ѐ-ԯᲀ-᲏ⷠ-ⷿꙀ-ꚟ]")
SPECIFIER = re.compile(
    r"%(?:%|(?P<pos>[1-9][0-9]*)\$)?(?P<flags>[-+ 0#']*)(?P<width>[0-9]+|\*)?(?:\.(?P<prec>[0-9]+|\*))?"
    r"(?P<length>hh|h|ll|l|q|L|z|t|j)?(?P<conv>[@dDiuUxXoOfFeEgGaAcCsSp])"
)


# MARK: - String Catalogs

def specifiers(text):
    """Returns {argument position: conversion} for the printf-style specifiers in text."""
    result = {}
    position = 0
    for match in re.finditer(r"%%|" + SPECIFIER.pattern, text):
        if match.group(0) == "%%":
            continue
        if match.group("pos"):
            index = int(match.group("pos"))
        else:
            position += 1
            index = position
        result[index] = (match.group("length") or "") + match.group("conv")
    return result


def describe(specs):
    return ", ".join(f"%{i}${c}" for i, c in sorted(specs.items())) or "none"


def unit_value(unit, where, errors, require_translated):
    string_unit = unit.get("stringUnit") if isinstance(unit, dict) else None
    if not isinstance(string_unit, dict) or not isinstance(string_unit.get("value"), str):
        errors.append(f"{where}: no stringUnit value")
        return None
    if require_translated and string_unit.get("state") != "translated":
        errors.append(f"{where}: state is {string_unit.get('state')!r}, expected 'translated'")
    if not string_unit["value"].strip():
        errors.append(f"{where}: empty value")
    return string_unit["value"]


def texts(localization, language, where, errors, require_translated):
    """Returns ("plain", {"": text}) or ("plural", {form: text}) for one localization."""
    if not isinstance(localization, dict):
        errors.append(f"{where}: not an object")
        return None
    unsupported = set(localization) - {"stringUnit", "variations"}
    if unsupported:
        errors.append(f"{where}: unsupported structure {sorted(unsupported)}")
        return None
    if "variations" in localization:
        variations = localization["variations"]
        if not isinstance(variations, dict) or set(variations) != {"plural"}:
            errors.append(f"{where}: only plural variations are supported, found {sorted(variations)}")
            return None
        forms = variations["plural"]
        unknown = set(forms) - KNOWN_PLURAL_FORMS
        if unknown:
            errors.append(f"{where}: unknown plural forms {sorted(unknown)}")
        missing = PLURAL_FORMS.get(language, {"other"}) - set(forms)
        if missing:
            errors.append(f"{where}: plural lacks {', '.join(sorted(missing))}")
        values = {}
        for form in sorted(forms):
            value = unit_value(forms[form], f"{where} [{form}]", errors, require_translated)
            if value is not None:
                values[form] = value
        return "plural", values
    value = unit_value(localization, where, errors, require_translated)
    return ("plain", {"": value}) if value is not None else None


def check_catalog(path, rel, errors):
    """Checks one catalog; returns (number of keys, {key: English value} for keys with an explicit English value)."""
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        errors.append(f"{rel}: cannot read: {error}")
        return 0, {}
    if doc.get("sourceLanguage") != SOURCE_LANGUAGE:
        errors.append(f"{rel}: sourceLanguage is {doc.get('sourceLanguage')!r}, expected {SOURCE_LANGUAGE!r}")
    strings = doc.get("strings")
    if not isinstance(strings, dict):
        errors.append(f"{rel}: no strings")
        return 0, {}
    english = {}
    for key, entry in strings.items():
        where = f"{rel}: {key!r}"
        if not isinstance(entry, dict):
            errors.append(f"{where}: not an object")
            continue
        localizations = entry.get("localizations", {})
        source = ("plain", {"": key})
        if SOURCE_LANGUAGE in localizations:
            source = texts(localizations[SOURCE_LANGUAGE], SOURCE_LANGUAGE, f"{where} [{SOURCE_LANGUAGE}]", errors, False)
            if source is None:
                continue
            english[key] = source[1].get("other", source[1].get(""))
        if entry.get("shouldTranslate") is False:
            continue
        reference = specifiers(source[1].get("other", source[1].get("")) or "")
        for language in TRANSLATIONS:
            lwhere = f"{where} [{language}]"
            if language not in localizations:
                errors.append(f"{lwhere}: not translated")
                continue
            target = texts(localizations[language], language, lwhere, errors, True)
            if target is None:
                continue
            if source[0] == "plural" and target[0] != "plural":
                errors.append(f"{lwhere}: the English text has plural forms, the translation has none")
            for form, text in target[1].items():
                found = specifiers(text)
                if found != reference:
                    label = f" [{form}]" if form else ""
                    errors.append(f"{lwhere}{label}: format specifiers {describe(found)} differ from {describe(reference)}")
    return len(strings), english


def find_catalogs(root):
    base = root / CATALOG_DIR
    return sorted(
        p for p in base.rglob("*.xcstrings")
        if not SKIP_DIRS.intersection(p.relative_to(root).parts)
    )


# MARK: - Swift sources

def strip_comments(text):
    """Replaces Swift comments with spaces (newlines kept, so line numbers stay valid).

    Understands string literals ("...", multi-line, raw #"..."#) and interpolations inside them, so "//" in a
    URL is not a comment. Raises ValueError on an unterminated string or block comment.
    """
    out = []
    i, n = 0, len(text)
    # Each frame: ["code", paren depth] or ["string", hashes, multiline].
    stack = [["code", 0]]
    opener = re.compile(r'(#*)("""|")')
    while i < n:
        frame = stack[-1]
        if frame[0] == "code":
            if text.startswith("//", i):
                end = text.find("\n", i)
                end = n if end < 0 else end
                out.append(" " * (end - i))
                i = end
                continue
            if text.startswith("/*", i):
                depth, j = 0, i
                while j < n:
                    if text.startswith("/*", j):
                        depth, j = depth + 1, j + 2
                    elif text.startswith("*/", j):
                        depth, j = depth - 1, j + 2
                        if depth == 0:
                            break
                    else:
                        j += 1
                if depth:
                    raise ValueError("unterminated block comment")
                out.append(re.sub(r"[^\n]", " ", text[i:j]))
                i = j
                continue
            match = opener.match(text, i)
            if match and (match.group(1) or text[i] == '"'):
                stack.append(["string", len(match.group(1)), match.group(2) == '"""'])
                out.append(match.group(0))
                i = match.end()
                continue
            char = text[i]
            if len(stack) > 1:
                if char == "(":
                    frame[1] += 1
                elif char == ")":
                    if frame[1] == 0:
                        stack.pop()
                    else:
                        frame[1] -= 1
            out.append(char)
            i += 1
            continue
        _, hashes, multiline = frame
        closer = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        if text.startswith(closer, i):
            stack.pop()
            out.append(closer)
            i += len(closer)
            continue
        if text.startswith(escape, i):
            j = i + len(escape)
            if j < n and text[j] == "(":
                stack.append(["code", 0])
                out.append(text[i:j + 1])
                i = j + 1
            else:
                out.append(text[i:j + 1])
                i = j + 1
            continue
        if text[i] == "\n" and not multiline:
            raise ValueError("unterminated string literal")
        out.append(text[i])
        i += 1
    if len(stack) != 1:
        raise ValueError("unterminated string literal or interpolation")
    return "".join(out)


def swift_files(root):
    for directory in SOURCE_DIRS:
        base = root / directory
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*.swift")):
            if not SKIP_DIRS.intersection(path.relative_to(root).parts):
                yield path


def check_sources(root, errors, notes):
    allowed_with_cyrillic = set()
    for path in swift_files(root):
        rel = path.relative_to(root).as_posix()
        try:
            code = strip_comments(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, ValueError) as error:
            errors.append(f"{rel}: cannot scan: {error}")
            continue
        hits = [(number, line.strip()) for number, line in enumerate(code.split("\n"), 1) if CYRILLIC.search(line)]
        if not hits:
            continue
        if rel in ALLOW_CYRILLIC:
            allowed_with_cyrillic.add(rel)
            continue
        for number, line in hits:
            errors.append(f"{rel}:{number}: Cyrillic outside comments: {line[:100]}")
    for rel in sorted(ALLOW_CYRILLIC - allowed_with_cyrillic):
        notes.append(f"{rel} has no Russian text: remove it from ALLOW_CYRILLIC")
    for rel in sorted(allowed_with_cyrillic):
        notes.append(f"{rel}: Russian text allowed for now (ALLOW_CYRILLIC)")


# MARK: - Info.plist build settings

def pbxproj_settings(text):
    """Returns [(name, value)] for every INFOPLIST_KEY_* assignment in a project.pbxproj."""
    result = []
    for match in re.finditer(r'INFOPLIST_KEY_(\w+) = ("(?:[^"\\]|\\.)*"|[^;\s]+);', text):
        value = match.group(2)
        if value.startswith('"'):
            value = re.sub(r"\\(.)", r"\1", value[1:-1])
        result.append((match.group(1), value))
    return result


def check_infoplist(root, english, errors):
    project = root / XCODE_PROJECT
    if not project.is_file():
        errors.append(f"{XCODE_PROJECT}: missing")
        return
    for name, value in pbxproj_settings(project.read_text(encoding="utf-8")):
        if CYRILLIC.search(value):
            errors.append(f"{XCODE_PROJECT}: INFOPLIST_KEY_{name} must be English (the source language): {value!r}")
        elif name in english and english[name] != value:
            errors.append(
                f"{XCODE_PROJECT}: INFOPLIST_KEY_{name} = {value!r} differs from the English value in "
                f"{INFOPLIST_CATALOG}: {english[name]!r}"
            )


# MARK: - Strings extracted by the compiler

def catalog_for(source, root):
    """The Localizable.xcstrings that serves a Swift file: the nearest one in a parent folder or its Resources."""
    for directory in source.parents:
        for candidate in (directory / "Localizable.xcstrings", directory / "Resources" / "Localizable.xcstrings"):
            if candidate.is_file():
                return candidate
        if directory == root:
            break
    return None


def check_extracted(root, derived_data, errors, notes):
    catalogs = {}
    used = {}
    files = sorted(derived_data.rglob("*.stringsdata"))
    if not files:
        errors.append(f"{derived_data}: no *.stringsdata files (build with SWIFT_EMIT_LOC_STRINGS=YES)")
    for path in files:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            errors.append(f"{path}: cannot read: {error}")
            continue
        source = pathlib.Path(data.get("source", ""))
        try:
            rel = source.resolve().relative_to(root).as_posix()
        except ValueError:
            continue  # generated code or another checkout
        if rel in ALLOW_CYRILLIC:
            continue
        catalog = catalog_for(root / rel, root)
        for table, entries in data.get("tables", {}).items():
            if not entries:
                continue
            if table != "Localizable":
                errors.append(f"{rel}: strings in table {table!r}; only Localizable is checked")
                continue
            if catalog is None:
                errors.append(f"{rel}: localizable strings but no Localizable.xcstrings next to it")
                continue
            if catalog not in catalogs:
                catalogs[catalog] = set(json.loads(catalog.read_text(encoding="utf-8")).get("strings", {}))
                used[catalog] = set()
            for entry in entries:
                key = entry.get("key", "")
                used[catalog].add(key)
                if key and key not in catalogs[catalog]:
                    line = entry.get("location", {}).get("startingLine", "?")
                    errors.append(f"{rel}:{line}: {key!r} is missing from {catalog.relative_to(root).as_posix()}")
    for catalog, keys in catalogs.items():
        for key in sorted(keys - used[catalog]):
            notes.append(f"{catalog.relative_to(root).as_posix()}: {key!r} is not used by the scanned code")


# MARK: - Main

def run(root, stringsdata=None):
    """Returns (errors, notes, summary)."""
    errors, notes = [], []
    root = root.resolve()
    catalogs = find_catalogs(root)
    rels = {p.relative_to(root).as_posix() for p in catalogs}
    for required in REQUIRED_CATALOGS:
        if required not in rels:
            errors.append(f"{required}: missing")
    total = 0
    infoplist = {}
    for path in catalogs:
        rel = path.relative_to(root).as_posix()
        count, english = check_catalog(path, rel, errors)
        total += count
        if rel == INFOPLIST_CATALOG:
            infoplist = english
    check_sources(root, errors, notes)
    check_infoplist(root, infoplist, errors)
    if stringsdata is not None:
        check_extracted(root, pathlib.Path(stringsdata).resolve(), errors, notes)
    summary = f"{len(catalogs)} catalogs, {total} keys, languages: {SOURCE_LANGUAGE} + {', '.join(TRANSLATIONS)}"
    return errors, notes, summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=pathlib.Path, default=ROOT, help="repository root")
    parser.add_argument("--stringsdata", metavar="DERIVED_DATA", help="also compare with strings the compiler extracted")
    parser.add_argument("--quiet", action="store_true", help="do not print notes")
    args = parser.parse_args(argv)
    errors, notes, summary = run(args.root, args.stringsdata)
    if not args.quiet:
        for note in notes:
            print(f"note: {note}")
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if errors:
        print(f"FAILED: {len(errors)} problem(s); {summary}", file=sys.stderr)
        return 1
    print(f"OK: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
