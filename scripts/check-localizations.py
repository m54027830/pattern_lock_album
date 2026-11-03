#!/usr/bin/env python3
"""Check catalog completeness, format arguments, and optional compiler-extracted keys.

Run from any directory. Pass --stringsdata /path/to/DerivedData after building
for an additional check that every compiler-extracted app key has a catalog entry.
"""
import argparse
import collections
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = {"en", "ko", "ja", "fr", "de", "it", "zh-Hans"}
FORMAT = re.compile(r"%(?:(\d+)\$)?(lld|ld|d|@|f)")


def arguments(value):
    result = collections.Counter()
    next_position = 1
    for match in FORMAT.finditer(value):
        position, kind = match.groups()
        result[(int(position) if position else next_position, kind)] += 1
        next_position += 1
    return result


def units(node):
    if "stringUnit" in node:
        yield node["stringUnit"]
    for variation in node.get("variations", {}).values():
        for child in variation.values():
            yield from units(child)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stringsdata", type=Path, help="DerivedData directory from an app build")
    args = parser.parse_args()
    errors = []
    catalogs = {}
    count = 0
    for path in sorted((ROOT / "patternlock").glob("*.xcstrings")):
        data = json.loads(path.read_text())
        catalogs[path.stem] = data["strings"]
        for key, entry in data["strings"].items():
            if entry.get("shouldTranslate") is False:
                continue
            count += 1
            localizations = entry.get("localizations", {})
            missing = LANGUAGES - localizations.keys()
            if missing:
                errors.append(f"{path.name}: {key!r}: missing {sorted(missing)}")
            english = list(units(localizations.get("en", {})))
            expected = arguments(english[0]["value"]) if english else arguments(key)
            for language, localization in localizations.items():
                values = list(units(localization))
                if not values:
                    errors.append(f"{key!r} [{language}]: no translated values")
                for unit in values:
                    if unit.get("state") != "translated" or not unit.get("value"):
                        errors.append(f"{key!r} [{language}]: unfinished translation")
                    elif arguments(unit["value"]) != expected:
                        errors.append(f"{key!r} [{language}]: format arguments differ: {unit['value']!r}")
    if args.stringsdata:
        files = list(args.stringsdata.rglob("*.stringsdata"))
        if not files:
            errors.append(f"No compiler extraction files in {args.stringsdata}")
        for path in files:
            data = json.loads(path.read_text())
            source = Path(data.get("source", ""))
            if ROOT / "patternlock" not in source.parents:
                continue
            for table, entries in data.get("tables", {}).items():
                for entry in entries:
                    if entry["key"] not in catalogs.get(table, {}):
                        errors.append(f"{source.name}: missing {table} key {entry['key']!r}")
    if errors:
        print("\n".join(sorted(set(errors))), file=sys.stderr)
        return 1
    print(f"Validated {count} messages in {len(LANGUAGES)} languages; all translations and format arguments are complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
