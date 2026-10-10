#!/usr/bin/env python3
"""Keystivo localization helper for the String Catalog (Localizable.xcstrings).

The catalog is the single source of truth. This tool keeps it in sync with the code:

  l10n.py check                 Report keys used in Swift code but missing from the
                                catalog, unused catalog keys, and per-language coverage.
  l10n.py add-source FILE.json  Add/update English source strings ({"key": "English"}).
  l10n.py import LANG FILE.json Import translations for LANG ({"key": "translation"}).
  l10n.py missing LANG          Print untranslated keys for LANG as JSON (English values),
                                ready to hand to a translator.
  l10n.py languages             List languages and their completion percentage.
  l10n.py dump LANG             Print every existing translation for LANG (terminology reference).
  l10n.py validate LANG FILE [--partial]
                                Check a translation file: every key present, no unknown
                                keys, placeholders (%@, %d, %1$@, %%) identical to English.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Packages/KeystivoKit/Sources/KeystivoCore/Resources/Localizable.xcstrings")
SOURCES = [os.path.join(ROOT, "Packages/KeystivoKit/Sources"), os.path.join(ROOT, "App")]
LANGUAGES = ["en", "tr", "de", "fr", "es", "it", "pt-BR", "ru", "zh-Hans", "zh-Hant", "ja", "ko"]

# L("key") / L("key", args) / titleKey: "key" / "...Key" string literals in Swift.
KEY_PATTERNS = [
    re.compile(r'\bL\(\s*"([A-Za-z0-9_.\-]+)"'),
    re.compile(r'[tT]itleKey:\s*"([A-Za-z0-9_.\-]+)"'),
    re.compile(r'[sS]ubtitleKey:\s*"([A-Za-z0-9_.\-]+)"'),
    re.compile(r'ChoiceOption\(\s*"[^"]*",\s*"([A-Za-z0-9_.\-]+)"'),
    re.compile(r'ParameterSpec\(\s*"[^"]*",\s*"([A-Za-z0-9_.\-]+)"'),
    re.compile(r'\blk\(\s*"([A-Za-z0-9_.\-]+)"'),
]


def load():
    if not os.path.exists(CATALOG):
        return {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
    with open(CATALOG, encoding="utf-8") as handle:
        return json.load(handle)


def save(catalog):
    os.makedirs(os.path.dirname(CATALOG), exist_ok=True)
    with open(CATALOG, "w", encoding="utf-8") as handle:
        json.dump(catalog, handle, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
        handle.write("\n")


def set_value(catalog, key, lang, value):
    entry = catalog["strings"].setdefault(key, {"extractionState": "manual", "localizations": {}})
    entry.setdefault("extractionState", "manual")
    entry.setdefault("localizations", {})[lang] = {"stringUnit": {"state": "translated", "value": value}}


def value(catalog, key, lang):
    try:
        return catalog["strings"][key]["localizations"][lang]["stringUnit"]["value"]
    except KeyError:
        return None


def used_keys():
    keys = {}
    for base in SOURCES:
        for directory, _, files in os.walk(base):
            for name in files:
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(directory, name)
                with open(path, encoding="utf-8") as handle:
                    text = handle.read()
                for pattern in KEY_PATTERNS:
                    for match in pattern.finditer(text):
                        keys.setdefault(match.group(1), os.path.relpath(path, ROOT))
    return keys


def placeholders(text):
    return sorted(re.findall(r"%(?:\d+\$)?[-+0#]*\d*(?:\.\d+)?(?:l|ll)?[@dfsiuxX]|%%", text or ""))


def cmd_check():
    catalog = load()
    used = used_keys()
    known = set(catalog["strings"].keys())
    missing = sorted(k for k in used if k not in known)
    dynamic_prefixes = ("permission.", "category.", "snap.", "trigger.", "condition.", "gesture.", "settings.section.")
    unused = sorted(k for k in known if k not in used and not k.startswith(dynamic_prefixes))
    status = 0
    if missing:
        status = 1
        print(f"✗ {len(missing)} keys used in code but missing from the catalog:")
        for key in missing:
            print(f"   {key}   ({used[key]})")
    else:
        print("✓ every key used in code exists in the catalog")
    if unused:
        print(f"• {len(unused)} catalog keys not found by static scan (may be built dynamically):")
        for key in unused[:40]:
            print(f"   {key}")
    for lang in LANGUAGES:
        done = sum(1 for k in known if value(catalog, k, lang))
        bad = [k for k in known if value(catalog, k, lang) and placeholders(value(catalog, k, lang)) != placeholders(value(catalog, k, "en"))]
        pct = 100.0 * done / max(len(known), 1)
        print(f"  {lang:8} {done:5}/{len(known)}  {pct:5.1f}%" + (f"  ⚠ {len(bad)} placeholder mismatches: {bad[:5]}" if bad else ""))
        if bad:
            status = 1
    return status


def cmd_add_source(path):
    catalog = load()
    with open(path, encoding="utf-8") as handle:
        entries = json.load(handle)
    for key, text in entries.items():
        set_value(catalog, key, "en", text)
    save(catalog)
    print(f"added/updated {len(entries)} English strings")


def cmd_import(lang, path):
    catalog = load()
    with open(path, encoding="utf-8") as handle:
        entries = json.load(handle)
    skipped = []
    for key, text in entries.items():
        if key not in catalog["strings"]:
            skipped.append(key)
            continue
        set_value(catalog, key, lang, text)
    save(catalog)
    print(f"imported {len(entries) - len(skipped)} {lang} strings" + (f", skipped unknown keys: {skipped}" if skipped else ""))


def cmd_missing(lang):
    catalog = load()
    result = {k: value(catalog, k, "en") for k in sorted(catalog["strings"]) if not value(catalog, k, lang)}
    print(json.dumps(result, ensure_ascii=False, indent=2))


def cmd_languages():
    catalog = load()
    total = len(catalog["strings"])
    for lang in LANGUAGES:
        done = sum(1 for k in catalog["strings"] if value(catalog, k, lang))
        print(f"{lang:8} {done}/{total}")


def cmd_validate(lang, path, partial=False):
    catalog = load()
    with open(path, encoding="utf-8") as handle:
        entries = json.load(handle)
    keys = set(catalog["strings"].keys())
    if partial:
        keys = {k for k in keys if not value(catalog, k, lang)}
    missing = sorted(keys - set(entries))
    unknown = sorted(set(entries) - keys)
    bad = [k for k in entries if k in keys and placeholders(entries[k]) != placeholders(value(catalog, k, "en"))]
    empty = [k for k, v in entries.items() if not str(v).strip()]
    ok = not (missing or unknown or bad or empty)
    print(f"{lang}: {len(entries)} entries, {len(missing)} missing, {len(unknown)} unknown, {len(bad)} placeholder mismatches, {len(empty)} empty")
    for title, items in (("missing", missing), ("unknown", unknown), ("placeholder mismatch", bad), ("empty", empty)):
        for key in items[:30]:
            print(f"  {title}: {key}")
    return 0 if ok else 1


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    command = argv[1]
    if command == "check":
        return cmd_check()
    if command == "add-source" and len(argv) == 3:
        return cmd_add_source(argv[2]) or 0
    if command == "import" and len(argv) == 4:
        return cmd_import(argv[2], argv[3]) or 0
    if command == "missing" and len(argv) == 3:
        return cmd_missing(argv[2]) or 0
    if command == "validate" and len(argv) in (4, 5):
        return cmd_validate(argv[2], argv[3], partial=len(argv) == 5 and argv[4] == "--partial")
    if command == "dump" and len(argv) == 3:
        catalog = load()
        print(json.dumps({k: value(catalog, k, argv[2]) for k in sorted(catalog["strings"]) if value(catalog, k, argv[2])}, ensure_ascii=False, indent=1))
        return 0
    if command == "languages":
        return cmd_languages() or 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
