#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Measure every skip-ink gap against the ink that crosses the rule.

For each snapshot case whose feed draws an underline, on each arm given a
binary, the case renders three ways through the snapshot harness's own
renderer: as it is; with `[underline] skip_ink = false`, which draws the whole
rule; and with the underline taken out of the feed, which draws the ink alone.
The rule is where the second render differs from the third. The cursor is
hidden in all three: it is solid like ink, and no rule taps it. The first
render says what the arm did.

The cut's halo is the setting's skip_ink_pad across and half of it upward,
each less a pixel for the soft edge of the disc. Two kinds of mismatch are
reported per case and arm:
  crossing  a rule pixel stands with solid ink inside its halo: ink at or
            above it, in its own line (ink below the band is the next
            line's, which the rule never taps);
  gap       a rule column is dropped with no ink, faint or solid, within the
            pad and a pixel of it.

A table of every case with an underline, per arm, is printed; the exit status
is the number of rows with a mismatch, capped at 1.

    python3 Scripts/measure-skip-ink.py --backend linux --linux-binary BIN [case ...]
    python3 Scripts/measure-skip-ink.py --self-test
"""

import argparse
import dataclasses
import math
import pathlib
import re
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Tests" / "Snapshots"))

ESCAPE = "\x1b"
SGR = re.compile(r"\x1b\[([0-9:;]*)m")


def decodeFeed(feed):
    """The case's feed as the bytes the binary receives (the escapes it decodes)."""
    out = []
    index = 0
    table = {"e": ESCAPE, "n": "\n", "r": "\r", "t": "\t", "a": "\a", "b": "\b", "\\": "\\"}
    while index < len(feed):
        character = feed[index]
        if character == "\\" and index + 1 < len(feed) and feed[index + 1] in table:
            out.append(table[feed[index + 1]])
            index += 2
            continue
        out.append(character)
        index += 1
    return "".join(out)


def encodeFeed(text):
    """Bytes back to the escaped spelling the binary decodes."""
    return text.replace("\\", "\\\\").replace(ESCAPE, "\\e").replace("\r", "\\r").replace("\n", "\\n")


def withoutUnderline(text):
    """The feed with every underline parameter taken out of its SGRs.

    Parameter 4 (with any `:` style) and 21 (double underline) go; every other
    parameter stays, with its own arguments: 38/48/58 carry two or four more.
    """
    def rewrite(match):
        parameters = match.group(1).split(";") if match.group(1) else ["0"]
        kept = []
        index = 0
        while index < len(parameters):
            parameter = parameters[index]
            head = parameter.split(":")[0]
            if head in ("38", "48", "58") and ":" not in parameter and index + 1 < len(parameters):
                width = 3 if parameters[index + 1] == "5" else 5
                group = parameters[index:index + width]
                if head != "58":
                    kept.extend(group)
                index += width
                continue
            if head in ("4", "21") or (head == "58"):
                index += 1
                continue
            kept.append(parameter)
            index += 1
        if not kept:
            return ""
        return ESCAPE + "[" + ";".join(kept) + "m"

    return SGR.sub(rewrite, text)


def hideCursor(feed):
    """The feed with the cursor hidden after it: a block cursor is solid like
    ink, but no rule taps it, so a rule meeting it is no crossing."""
    return feed + encodeFeed(ESCAPE + "[?25l")


def hasUnderline(text):
    for match in SGR.finditer(text):
        parameters = match.group(1).split(";")
        index = 0
        while index < len(parameters):
            head = parameters[index].split(":")[0]
            if head in ("38", "48", "58") and ":" not in parameters[index] and index + 1 < len(parameters):
                index += 3 if parameters[index + 1] == "5" else 5
                continue
            if head == "21" or (head == "4" and parameters[index] not in ("4:0",)):
                return True
            index += 1
    return False


def differs(a, b, threshold):
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2])) > threshold


def distance(a, b):
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2]))


def measure(asIs, whole, inkOnly, width, height, padInPixels, skipsInk=True):
    """Counts crossings and stray gaps along every rule, from three RGBA frames."""
    def pixel(frame, x, y):
        offset = (y * width + x) * 4
        return frame[offset:offset + 3]

    crossings = 0
    gaps = 0
    columns = 0
    # Rule pixels, per row: where the whole rule differs from the ink alone.
    rule = [[differs(pixel(whole, x, y), pixel(inkOnly, x, y), 24) for x in range(width)] for y in range(height)]
    # Bands: maximal runs of rows carrying rule pixels.
    y = 0
    while y < height:
        if not any(rule[y]):
            y += 1
            continue
        top = y
        while y < height and any(rule[y]):
            y += 1
        bottom = y
        # The rule pass draws after the glyphs, so the whole rule differs from
        # the ink alone at every column it covers, ink or not; a patterned
        # rule's own breaks are columns it never covers.
        ruleColumns = [x for x in range(width) if any(rule[row][x] for row in range(top, bottom))]
        if not ruleColumns:
            continue
        # The background under the band, in the ink-only frame: the colour of
        # the rule's columns most rows share.
        counts = {}
        for x in ruleColumns:
            for row in range(top, bottom):
                key = bytes(pixel(inkOnly, x, row))
                counts[key] = counts.get(key, 0) + 1
        ground = max(counts, key=counts.get)
        # The cut's halo, less a pixel for the edge of its disc: the pad
        # across, half of it upward. Ink below the band belongs to the next
        # line, whose glyphs the rule never taps. A rule pixel drawn with solid
        # ink inside that halo crosses it; faint ink (an antialiased fringe)
        # within the pad and a pixel excuses a gap.
        reachAcross = max(padInPixels - 1.0, 0.0)
        reachUp = max(math.ceil(padInPixels * 0.5) - 1, 0)
        solid = {(x, row) for row in range(max(top - reachUp, 0), bottom) for x in range(width)
                 if differs(pixel(inkOnly, x, row), ground, 128)}
        faintInk = set()
        for x in range(width):
            for row in range(max(top - max(reachUp, 1), 0), min(bottom + 1, height)):
                if differs(pixel(inkOnly, x, row), ground, 40):
                    faintInk.add(x)

        def crossesInk(x, row):
            for inkRow in range(max(row - reachUp, 0), row + 1):
                rise = (row - inkRow) / reachUp if reachUp else 0.0
                across = int(reachAcross * math.sqrt(max(1.0 - rise * rise, 0.0)))
                if any((inkX, inkRow) in solid for inkX in range(x - across, x + across + 1)):
                    return True
            return False

        for x in ruleColumns:
            columns += 1
            absent = not any(differs(pixel(asIs, x, row), pixel(inkOnly, x, row), 24) for row in range(top, bottom))
            # Drawn is nearer the whole rule than the ink alone: a pixel the
            # halo's soft edge half cut is not a rule standing on ink.
            crossed = any(rule[row][x] and distance(pixel(asIs, x, row), pixel(inkOnly, x, row))
                          > distance(pixel(asIs, x, row), pixel(whole, x, row)) and crossesInk(x, row)
                          for row in range(top, bottom))
            nearInk = any(abs(x - other) <= padInPixels + 1 for other in faintInk)
            if skipsInk and crossed:
                crossings += 1
            elif absent and not (skipsInk and nearInk):
                gaps += 1
    return columns, crossings, gaps


def selfTest():
    """A planted rule, ink and gap: a correct skip measures clean, a missing
    gap is a crossing, and a gap with no ink is a stray gap."""
    width, height = 20, 6
    def frame(rulePixels, inkPixels):
        data = bytearray(width * height * 4)
        for (x, y) in rulePixels | inkPixels:
            offset = (y * width + x) * 4
            # The rule pass draws after the glyphs, so a rule over ink wins.
            data[offset:offset + 3] = bytes((200, 0, 0)) if (x, y) in rulePixels else bytes((255, 255, 255))
        return bytes(data)

    ruleRow = {(x, 4) for x in range(2, 18)}
    ink = {(9, row) for row in range(0, 6)}
    whole = frame(ruleRow, ink)
    inkOnly = frame(set(), ink)
    skipped = frame({p for p in ruleRow if abs(p[0] - 9) > 2}, ink)
    stray = frame({p for p in ruleRow if abs(p[0] - 9) > 2 and p[0] != 15}, ink)
    failures = []
    if measure(skipped, whole, inkOnly, width, height, 1)[1:] != (0, 0):
        failures.append("a correct skip measured as a mismatch")
    if measure(whole, whole, inkOnly, width, height, 1)[1] == 0:
        failures.append("a rule drawn over the ink measured clean")
    if measure(stray, whole, inkOnly, width, height, 1)[2] == 0:
        failures.append("a gap with no ink near it measured clean")
    # A three-row rule cut on its top and bottom rows beside a stem of ink, its
    # middle row left standing against the stem: a crossing a column test
    # would excuse because the column is partly cut.
    thickRule = {(x, y) for x in range(2, 18) for y in (2, 3, 4)}
    thickWhole = frame(thickRule, ink)
    striped = frame({p for p in thickRule if abs(p[0] - 9) > 2 or p[1] == 3}, ink)
    if measure(striped, thickWhole, inkOnly, width, height, 4)[1] == 0:
        failures.append("a rule row left standing against ink inside a cut measured clean")
    if failures:
        print(f"measure-skip-ink: self-test FAILED — {len(failures)} finding(s): {'; '.join(failures)}")
        return 1
    print("measure-skip-ink: self-test ok (a correct skip is clean; a crossing, a stray gap and a row left standing are found)")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("filters", nargs="*")
    parser.add_argument("--backend", action="append", default=[])
    for arm in ("portable", "linux", "macos", "swift", "web", "ios"):
        parser.add_argument(f"--{arm}-binary")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--keep", help="a directory to keep the three frames of every render in")
    args = parser.parse_args()
    if args.self_test:
        return selfTest()

    import run

    binaries = {arm: getattr(args, f"{arm}_binary") for arm in ("portable", "linux", "macos", "swift", "web", "ios")}
    regressions = [r for r in run.load_case_regressions()
                   if r.kind == "snapshot" and r.case is not None and r.backend in args.backend
                   and binaries.get(r.backend) and not r.also_feeds
                   and (not args.filters or r.case["name"] in args.filters)]
    rows = []
    with tempfile.TemporaryDirectory(dir=run.HERE) as scratch:
        scratchPath = pathlib.Path(scratch)
        for regression in regressions:
            case = regression.case
            if "feed" not in case or not hasUnderline(decodeFeed(case["feed"])):
                continue
            tier = "unifont" if "unifont" in regression.identifier else "native"
            base = run.json.loads(run.json.dumps({k: v for k, v in case.items() if k not in ("config",)}))
            settings = base.get("settings") or {}
            pad = float((settings.get("underline") or {}).get("skip_ink_pad", 1.75))
            skipsInk = bool((settings.get("underline") or {}).get("skip_ink", True))
            fontText = (run.unifont_font_text() if tier == "unifont"
                        else run.native_profile_text(base["native"]))

            def variant(suffix, settingsOverride, feed):
                changed = dict(base)
                changed["name"] = f"{base['name']}__{suffix}"
                merged = {section: dict(keys) for section, keys in settings.items()}
                for section, keys in settingsOverride.items():
                    merged.setdefault(section, {}).update(keys)
                changed["settings"] = merged
                changed["feed"] = feed
                config = run.materialised_config(changed, tier, fontText)
                arm = run.arm_variant(changed, regression.backend, config)
                return dataclasses.replace(regression, case=arm, golden=None)

            frames = {}
            try:
                for suffix, override, feed in (
                        ("asis", {}, hideCursor(case["feed"])),
                        ("whole", {"underline": {"skip_ink": False}}, hideCursor(case["feed"])),
                        ("ink", {}, hideCursor(encodeFeed(withoutUnderline(decodeFeed(case["feed"])))))):
                    path = scratchPath / f"{regression.identifier.replace(':', '_')}_{suffix}.png"
                    run.render_snapshot(binaries[regression.backend], variant(suffix, override, feed), path)
                    frames[suffix] = run.read_png_rgba(path)
                    if args.keep:
                        pathlib.Path(args.keep).mkdir(parents=True, exist_ok=True)
                        run.shutil.copy(path, pathlib.Path(args.keep) / path.name)
            except Exception as error:  # noqa: BLE001 — a refused render is reported, not fatal
                rows.append((regression.identifier, "render refused", str(error)[:80]))
                continue
            width, height, asIs = frames["asis"]
            # Every arm renders a case at two pixels per point unless it names a scale.
            scale = float(base.get("scale", 2.0))
            columns, crossings, gaps = measure(asIs, frames["whole"][2], frames["ink"][2], width, height, pad * scale, skipsInk)
            rows.append((regression.identifier, f"{columns} rule px", f"crossing={crossings} gap={gaps}"))
    bad = 0
    for identifier, columns, verdict in rows:
        mark = "OK " if verdict.endswith("crossing=0 gap=0") else "BAD"
        bad += mark == "BAD"
        print(f"{mark} {identifier:70} {columns:>14} {verdict}")
    print(f"measure-skip-ink: {len(rows)} render(s), {bad} with a mismatch")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
