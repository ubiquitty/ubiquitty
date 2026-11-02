#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""check-settings-schema-live.py — a range belongs to a setting that exists.

`Source/Core/Preferences/Schema.h` holds min/max/step/unit for every numeric
setting, and its own header says what that is for: "The one place these numbers
live — the TOML parse clamp consults rangeFor(), and the Settings UI reads the
same table."

Two of its twenty-eight rows described settings that were not anywhere else in
the tree:

    appearance.fullscreen_center    "Enable fullscreen centering"
    appearance.fullscreen_inset     "Inset when centering enabled"

No Preferences field, no parse, no writer, no UI — the key appeared in this file and
nowhere else, in either spelling. A row like that is not wrong so much as inert:
`rangeFor` answers for a setting nothing asks about, and the table reads as
twenty-eight settings when it describes twenty-six.

It is the shape that is hard to see by reading. Every row is well-formed and the
numbers are plausible, so the file looks complete either way; only a search
outside it can tell a live row from a dead one.

Either spelling satisfies it, because the table is keyed on TOML and the code is
not. A row names `skip_ink_pad` and the field is `skipInkPad`, so looking for only
the snake form would report most of the table dead, and only the camel form would
miss a key read straight out of a TOML document. A row passes if either spelling
appears in any other tracked source, config or doc.

The bar is existence, not correct wiring: a mention in a comment counts, because
separating a real use from a mention needs a parser per language. That is enough
to catch a row whose setting is in no file at all, which is what these two were.

Stdlib only.

    python3 Scripts/check-settings-schema-live.py
    python3 Scripts/check-settings-schema-live.py --self-test
"""

import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_report  # noqa: E402 — the path above is what makes it importable

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))

SCHEMA = os.path.join("Source", "Core", "Preferences", "Schema.h")

# `{ "appearance", "padding_left", { 0.0, 64.0, 1.0, "pt" } },`
ROW = re.compile(r'\{\s*"([a-z_]+)"\s*,\s*"([a-z_0-9]+)"\s*,\s*\{')

# Where a setting may show itself. Sources, the TOML templates, and the docs —
# a setting named only in prose is still a setting someone can find.
SEARCHED = (".h", ".hpp", ".cpp", ".mm", ".m", ".swift", ".toml", ".py", ".md",
            ".js", ".mjs", ".el")


def camel(key):
    """`skip_ink_pad` -> `skipInkPad`, the spelling a C++ field would use."""
    return re.sub(r"_([a-z0-9])", lambda m: m.group(1).upper(), key)


def rows(text):
    return ROW.findall(text)


def read(path):
    try:
        with open(os.path.join(REPO, path), encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def sidebarTitles(catalog):
    """Reads category declarations; nested calls and quoted parentheses stay inside them."""
    titles = []
    for match in re.finditer(r"SettingsCategory\(", catalog):
        depth = 1
        quoted = escaped = False
        end = match.end()
        while end < len(catalog) and depth:
            character = catalog[end]
            if quoted:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == '"':
                    quoted = False
            elif character == '"':
                quoted = True
            elif character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
            end += 1
        block = catalog[match.end():end - 1]
        title = re.search(r'title:\s*"([^"\n]+)"', block)
        if depth == 0 and title and not re.search(r"\bparentID\s*:", block):
            titles.append(title.group(1))
    return titles


def guideSidebar(text):
    match = re.search(r"<!-- settings-sidebar:start -->(.*?)<!-- settings-sidebar:end -->", text, re.S)
    if not match:
        return []
    block = match.group(1)
    rows = re.findall(r"^\| \*\*([^*]+)\*\* \|", block, re.M)
    return rows or [entry.strip().rstrip(".") for entry in block.split(";") if entry.strip()]


def sidebarErrors(catalog, guides):
    titles = sidebarTitles(catalog)
    if not titles:
        return ["no Settings sidebar categories could be read"]
    return [path + ": documented sidebar differs from SettingsCatalog.swift"
            for path, text in guides.items() if guideSidebar(text) != titles]


def selfTest():
    ok = True

    sample = '{ "appearance", "padding_left", { 0.0, 64.0, 1.0, "pt" } },\n' \
             '{ "font", "size", { 6.0, 96.0, 1.0, "pt" } },'
    if rows(sample) != [("appearance", "padding_left"), ("font", "size")]:
        print("self-test: rows misread, got %s" % rows(sample), file=sys.stderr)
        ok = False

    for key, want in (("skip_ink_pad", "skipInkPad"), ("size", "size"),
                      ("padding_left", "paddingLeft")):
        if camel(key) != want:
            print("self-test: camel(%r) should be %r, got %r" % (key, want, camel(key)),
                  file=sys.stderr)
            ok = False

    # A comment-only mention counts as existing, which is the generosity this
    # gate is built with — asserting otherwise would need a parser per language.
    if "skipInkPad" not in "// the skipInkPad field is clamped here":
        print("self-test: a comment mention is not seen", file=sys.stderr)
        ok = False

    sampleCatalog = 'SettingsCategory(id: "a", title: "Appearance", content: pane("(x)")), SettingsCategory(id: "t", title: "Themes", parentID: "a")'
    sampleGuide = '<!-- settings-sidebar:start -->Appearance.<!-- settings-sidebar:end -->'
    if sidebarErrors(sampleCatalog, {"guide": sampleGuide}) or not sidebarErrors(sampleCatalog, {"guide": sampleGuide.replace("Appearance", "Advanced")}):
        print("self-test: sidebar drift or child-category handling failed", file=sys.stderr)
        ok = False

    print("check-settings-schema-live: self-test %s" % ("ok" if ok else "FAILED"))
    return 0 if ok else 1


def main():
    if "--self-test" in sys.argv[1:]:
        return selfTest()

    guidePaths = ("Docs/guides/getting-started.md", "Docs/guides/README.md")
    errors = sidebarErrors(read("Source/Platform/macOS/App/SettingsCatalog.swift"),
                           {path: read(path) for path in guidePaths})
    if errors:
        return gate_report.failed("check-settings-schema-live", "Settings guide navigation drift", errors)

    schema = read(SCHEMA)
    table = rows(schema)
    if not table:
        print("check-settings-schema-live: FAILED — no rows parsed from %s, so "
              "every setting was compared against nothing. The row shape "
              "changed, or the file moved." % SCHEMA, file=sys.stderr)
        return 1

    listing = subprocess.run(["git", "-C", REPO, "ls-files"],
                             capture_output=True, text=True)
    others = [p for p in listing.stdout.split("\n")
              if p.endswith(SEARCHED) and p != SCHEMA]
    haystack = "\n".join(read(p) for p in others)
    if not haystack:
        print("check-settings-schema-live: FAILED — no other source read, so "
              "every row would look dead", file=sys.stderr)
        return 1

    dead = []
    for section, key in table:
        if key in haystack or camel(key) in haystack:
            continue
        dead.append("%s.%s (also looked for %s)" % (section, key, camel(key)))

    if dead:
        status = gate_report.failed("check-settings-schema-live",
                                    "schema row(s) for settings that are not there", dead)
        print("\n  rangeFor() answers for these and nothing asks. Delete the row, or\n"
              "  land the setting it describes — a range is not a plan for one.",
              file=sys.stderr)
        return status

    print("check-settings-schema-live: ok (%d schema row(s), each naming a setting "
          "the tree has elsewhere)" % len(table))
    return 0


if __name__ == "__main__":
    sys.exit(main())
