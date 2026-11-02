#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# import-phosphor.py — refresh Resources/phosphor/ from Phosphor's npm packages.
#
#   Scripts/import-phosphor.py --web <@phosphor-icons/web package dir> \
#                              --core <@phosphor-icons/core package dir>
#
# Each directory is an unpacked package (the `package/` folder of its tarball).
# The web package supplies the two font weights a tag can draw in; the core
# package supplies the catalog a picker searches, its names, tags and
# categories. Nothing from either package is executed: the core catalog is a
# JavaScript module, read here as text.
#
# A catalog entry is kept only when both fonts carry its codepoint under its
# name, so a tag can never name an icon that draws in one weight and not the
# other.

import argparse
import json
import pathlib
import re
import shutil
import sys

FONTS = {"regular": "Phosphor.ttf", "fill": "Phosphor-Fill.ttf"}
OUT = pathlib.Path(__file__).resolve().parent.parent / "Resources" / "phosphor"


def selection_codepoints(path, suffix):
    """Name -> codepoint from an IcoMoon selection.json; a key may list aliases."""
    codepoints = {}
    for icon in json.loads(path.read_text(encoding="utf-8"))["icons"]:
        properties = icon["properties"]
        for name in properties["name"].split(","):
            name = name.strip()
            if suffix and name.endswith(suffix):
                name = name[: -len(suffix)]
            codepoints[name] = properties["code"]
    return codepoints


def catalog_entries(module_text):
    """The icon records of the core package's JavaScript catalog module."""
    enum_values = {}
    for enum in re.finditer(r"\(\(i\) => \((.*?), i\)\)\((\w) \|\| \{\}\)", module_text):
        for key, value in re.findall(r'i\.(\w+) = "([^"]*)"', enum.group(1)):
            enum_values[f"{enum.group(2)}.{key}"] = value
    start = module_text.index("const n = [")
    entries = []
    for block in re.finditer(r"\{\s*name: \"([^\"]+)\",(.*?)codepoint: (\d+)", module_text[start:], re.S):
        name, body, codepoint = block.group(1), block.group(2), int(block.group(3))
        categories = re.search(r"categories: \[([^\]]*)\]", body)
        tags = re.search(r"tags: \[([^\]]*)\]", body, re.S)
        entries.append(
            {
                "name": name,
                "codePoint": codepoint,
                "categories": [enum_values.get(token.strip(), token.strip()) for token in categories.group(1).split(",") if token.strip()]
                if categories
                else [],
                "tags": [tag for tag in re.findall(r'"([^"]*)"', tags.group(1)) if not tag.startswith("*")] if tags else [],
            }
        )
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--web", required=True, type=pathlib.Path)
    parser.add_argument("--core", required=True, type=pathlib.Path)
    arguments = parser.parse_args()

    web_version = json.loads((arguments.web / "package.json").read_text(encoding="utf-8"))["version"]
    core_version = json.loads((arguments.core / "package.json").read_text(encoding="utf-8"))["version"]
    regular = selection_codepoints(arguments.web / "src" / "regular" / "selection.json", "")
    fill = selection_codepoints(arguments.web / "src" / "fill" / "selection.json", "-fill")
    entries = catalog_entries((arguments.core / "dist" / "index.mjs").read_text(encoding="utf-8"))

    kept = [entry for entry in entries if regular.get(entry["name"]) == entry["codePoint"] == fill.get(entry["name"])]
    dropped = sorted(entry["name"] for entry in entries if entry not in kept)
    if not kept:
        sys.exit("import-phosphor: no catalog entry matched both fonts")

    OUT.mkdir(parents=True, exist_ok=True)
    for weight, font in FONTS.items():
        shutil.copyfile(arguments.web / "src" / weight / font, OUT / font)
    license_text = (arguments.web / "LICENSE").read_text(encoding="utf-8")
    core_license = (arguments.core / "LICENSE").read_text(encoding="utf-8")
    core_copyright = next(line for line in core_license.splitlines() if line.startswith("Copyright"))
    if core_copyright not in license_text:
        license_text = license_text.replace("Copyright", core_copyright + "\nCopyright", 1)
    (OUT / "LICENSE").write_text(license_text, encoding="utf-8")
    # One icon to a line, so a refresh reads as a diff of the icons it changed.
    source = json.dumps({"@phosphor-icons/web": web_version, "@phosphor-icons/core": core_version})
    lines = [json.dumps(entry, ensure_ascii=False, separators=(",", ":")) for entry in sorted(kept, key=lambda entry: entry["name"])]
    (OUT / "catalog.json").write_text(
        '{"source":' + source + ',"icons":[\n' + ",\n".join(lines) + "\n]}\n", encoding="utf-8"
    )
    print(f"import-phosphor: {len(kept)} icons into {OUT.relative_to(OUT.parent.parent)}", end="")
    print(f"; left out, not in both fonts under one codepoint: {', '.join(dropped)}" if dropped else "")


if __name__ == "__main__":
    main()
