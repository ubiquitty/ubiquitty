#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""check-glyph-slot-arms.py — each frontend declares which glyph path it drives.

`TerminalFrameInputs::capture` copies eleven fields out of `m_glyphSlot`, and
`setGlyphSlotGeometry` is that member's only writer. A caller that never calls it
captures a geometry of zeros, which the header says selects the cell-baked path —
true, and it is not the only thing zeros select. `isWideOnOwnSheet` in
`buildCellInstances` also requires `glyphWideSlotWidthInPixels` and `glyphBoxWidthInPixels` above
zero, so an arm on the cell-baked path is off the wide sheet as well, and no
frontend states which of those it meant.

The four arms spell the obligation three ways, which is the reason this is a
declared pairing rather than a rule:

    argument   the geometry is handed to capture, which fills all eleven fields
    direct     BuildInputs is written after inputs(), some subset of the eleven

`direct` is the class that must stay empty, and the one an inferred rule cannot
see. An arm that writes four of the
eleven onto `BuildInputs` satisfies "sets the geometry" and "sets four of eleven"
in the same sentence, and the seven it skipped are the ones a reader would have
to know to ask about.

So each arm is named with the class it is in and why. What fails: an arm whose
class changed, a declared arm that is gone, an arm this finds and nothing
declares, and a `direct` arm whose field list moved. The last needs the list, so
the eleven are read from the capture body rather than restated here — an arm can
only be measured against the fields that exist.

What this cannot see, stated rather than implied: whether an `argument` arm passes a
geometry that describes its atlas. It pairs the call with the arm; a caller
handing over a zeroed struct is `argument` here and carries no geometry in fact.
`Source/Core/Rendering/TerminalSnapshot` is that arm today, and it says so.

Stdlib only, no build.

    python3 Scripts/check-glyph-slot-arms.py
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, HERE)
import library_scripts  # noqa: E402 — the arms are in every repository the app builds on

CAPTURE = "Source/Core/Rendering/TerminalFrameInputs.cpp"
OWNER = "Source/Core/Rendering/TerminalFrameInputs"
GEOMETRY = "Source/Core/Rendering/GlyphSlotCache.h"

# Members of `GlyphSlotGeometry` the capture is not expected to forward, each
# with why. The capture's field list is bounded against the rest, because a
# rename on either side shrinks that list in silence: renaming the BuildInputs
# fields took it from eleven to one, every arm kept its class, and the verdict
# printed the new number and passed.
NOT_FORWARDED = {
    "columns":
        "an atlas layout figure the UV helpers take as an argument; the builder "
        "never addresses a slot by row",
    "ligatureSlotWidthInPixels":
        "a shaped run's strip geometry reaches the backend through this struct "
        "directly — FontGeometry fills it, LigatureSheet.swift reads it — so the "
        "builder needs no copy. It had one, written by the capture and read by "
        "nothing, while every sibling slot field is read by "
        "buildCellInstances in CellInstanceBuilder.cpp",
    "ligatureSlotHeightInPixels":
        "the height twin of the above, and dead for the same reason",
}

# Every arm that builds a capture, the class it is in, and why. An arm moving
# between classes is a render behaviour change and fails here rather than showing
# up as a parity number nobody can attribute.
ARMS = {
    "Source/Platform/Web/WebTerminal": (
        "argument",
        "same, over the WebGL atlas"),
    "Source/Platform/Linux/Raster": (
        "argument",
        "derives the subpixel overflow slot from its rasterizer and hands it "
        "over; the wide and double slot widths stay zero, so the wide sheet is "
        "unreachable, which is also true of its instance streams"),
    "Source/Core/Rendering/TerminalSnapshot": (
        "argument",
        "hands over an empty geometry by name, so every glyph takes the "
        "cell-baked path; the emptiness is the arm's choice and not an omission"),
    "Source/Platform/Linux/main": (
        "argument",
        "the pane's rich-text frame capture hands over an empty geometry by "
        "name; that frame feeds the rich-text pass, whose glyphs are not drawn "
        "from the slot atlas, so the emptiness is the arm's choice and not an "
        "omission"),
}

CLASSES = ("argument", "direct")

HOLDS = re.compile(r"\bTerminalFrameInputs\s+\w+\s*;|\bTerminalFrameInputs\s+m_\w+\s*;"
                   r"|Rendering::TerminalFrameInputs\s+\w+")
FIELD = re.compile(r"m_inputs\.(glyph\w+|subpixelGlyphs)\b")


def tracked():
    return library_scripts.tracked()


def capture_fields(text):
    """The BuildInputs fields the capture fills from the slot geometry.

    Taken over the whole file rather than one function body: `capture` is
    overloaded, only one overload fills these, and keying on the first
    definition measured the wrong one and reported the field list empty.
    """
    return sorted({name for line in text.split("\n") if "=" in line
                   for name in FIELD.findall(line)})


def geometry_members(text):
    """Member names declared by `struct GlyphSlotGeometry`."""
    start = text.find("struct GlyphSlotGeometry")
    if start < 0:
        return None
    end = text.find("\n};", start)
    if end < 0:
        return None
    member = re.compile(r"^\s*(?:int|float|IntSize)\s+(\w+)\s*(?:=|;)")
    return [match.group(1) for match in
            (member.match(line) for line in text[start:end].split("\n")) if match]


def classify(text, fields):
    """`argument` or `direct`, plus the fields a direct arm writes.

    A field is written when its name is assigned through some object — the
    member is a size for two of them, so `x.glyphMarginInPixels.width = …`
    counts and a match anchored on `= ` after the field name does not.

    `direct` is tested first because it is the defect: an arm that both hands a
    geometry to capture and then writes fields over it is direct, and reading
    the argument first would call it clean.

    Keyed on the OBJECT rather than on the field name. Both types carry these
    names — an arm assembling a `GlyphSlotGeometry` writes exactly the fields a
    direct arm writes onto `BuildInputs`, so a field-name match calls every arm
    that builds a geometry direct. The names of the `BuildInputs` locals come
    from their declarations, so an arm that renames its copy is still read.
    """
    holders = set(re.findall(r"\bBuildInputs\s+(\w+)\s*[=;]", text))
    holders.add("m_inputs")
    written = sorted({name for name in fields
                      for line in text.split("\n")
                      if "=" in line and any(
                          re.search(r"\b%s\.%s\b" % (re.escape(holder), re.escape(name)), line)
                          for holder in holders)})
    return ("direct", written) if written else ("argument", [])


def main():
    paths = tracked()
    try:
        with open(library_scripts.locate(CAPTURE), encoding="utf-8") as handle:
            captureText = handle.read()
        fields = capture_fields(captureText)
        with open(library_scripts.locate(GEOMETRY), encoding="utf-8") as handle:
            members = geometry_members(handle.read())
    except OSError:
        fields, members = None, None
    if not members:
        print("check-glyph-slot-arms: no GlyphSlotGeometry in %s — it moved or "
              "changed shape," % GEOMETRY, file=sys.stderr)
        print("  and the capture's field list was bounded against nothing.",
              file=sys.stderr)
        return 2
    if not fields:
        print("check-glyph-slot-arms: no capture body in %s — it moved or "
              "changed shape," % CAPTURE, file=sys.stderr)
        print("  and no arm was measured.", file=sys.stderr)
        return 2

    # An arm is a module, not a file: the browser declares the capture in its
    # header and calls the setter in its implementation, and that implementation
    # names `TerminalFrameInputs` nowhere — it reaches the member through the
    # header. A per-file walk reported the header undeclared and the
    # implementation absent, two diagnostics for one arm that is neither, and
    # then read the arm as `unset` because the call was in the file it dropped.
    texts = {}
    for path in paths:
        if not path.endswith((".cpp", ".mm", ".h")) or path.startswith(OWNER):
            continue
        if path.startswith("Tests/"):
            continue
        try:
            with open(library_scripts.locate(path), encoding="utf-8",
                      errors="replace") as handle:
                texts[path] = handle.read()
        except OSError:
            continue

    stems = {os.path.splitext(path)[0] for path, text in texts.items()
             if HOLDS.search(text)}
    found = {}
    for stem in stems:
        joined = "\n".join(text for path, text in texts.items()
                            if os.path.splitext(path)[0] == stem)
        found[stem] = classify(joined, fields)

    failures = []

    # The field list is the population every arm is measured against, so it is
    # bounded rather than counted. A member the capture stops forwarding is a
    # field no arm can be found writing, and the arms keep their classes while
    # the set they were classified over shrinks under them.
    forwarded = [name for name in members if name not in NOT_FORWARDED]
    for name in forwarded:
        if ("m_glyphSlot.%s" % name) not in captureText:
            failures.append(
                "  GlyphSlotGeometry::%s is declared and the capture forwards "
                "nothing from it.\n    An arm is classified by which of these "
                "fields it writes; one that leaves the\n    capture leaves the "
                "population, and every arm still reports the class it had.\n"
                "    Forward it in %s, or name it in NOT_FORWARDED with why."
                % (name, CAPTURE))
    if len(fields) < len(forwarded):
        failures.append(
            "  the capture forwards %d BuildInputs field(s) for %d geometry "
            "member(s).\n    Fewer fields than members means a name on one side "
            "moved, and this walks the\n    fields — so the shortfall is "
            "invisible in every arm's verdict."
            % (len(fields), len(forwarded)))
    for name in sorted(NOT_FORWARDED):
        if name not in members:
            failures.append(
                "  NOT_FORWARDED excuses GlyphSlotGeometry::%s and no such "
                "member exists.\n    Delete the entry with the member." % name)

    for path, (observed, written) in sorted(found.items()):
        if path not in ARMS:
            failures.append(
                "  %s builds a capture and no entry names it.\n"
                "    It is %r. An arm nobody declared is one whose glyph path "
                "nothing states,\n    and zeros read the same as a choice."
                % (path, observed))
            continue
        declared, _ = ARMS[path]
        if declared != observed:
            failures.append(
                "  %s is declared %r and reads as %r.\n"
                "    Which glyph path an arm drives decides the wide sheet and "
                "the cell-baked\n    fallback together, so a change of class is "
                "a render change. Update the entry\n    with what moved."
                % (path, declared, observed))
        elif observed == "direct" and not written:
            failures.append(
                "  %s is declared 'direct' and writes none of the capture's "
                "slot fields.\n    The fields it wrote were renamed or moved; "
                "it is now 'unset' in fact." % path)

    for path, (declared, _) in sorted(ARMS.items()):
        if path not in found:
            failures.append(
                "  %s is declared %r and builds no capture.\n"
                "    Delete the entry with the arm, so the list stays a census "
                "rather than a record." % (path, declared))
        if declared not in CLASSES:
            failures.append("  %s is declared %r, which is not one of %s"
                            % (path, declared, ", ".join(CLASSES)))

    if failures:
        print("check-glyph-slot-arms: an arm's glyph path is not what it says",
              file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1

    tally = {name: 0 for name in CLASSES}
    for _, (observed, _) in found.items():
        tally[observed] += 1
    print("check-glyph-slot-arms: ok (%d arms = %s; %d BuildInputs field(s) "
          "carry %d of %d geometry member(s), %d forwarded by nothing with a "
          "stated reason)"
          % (len(found),
             " + ".join("%d %s" % (tally[name], name) for name in CLASSES),
             len(fields), len(forwarded), len(members), len(NOT_FORWARDED)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
