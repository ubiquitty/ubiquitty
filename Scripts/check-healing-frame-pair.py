#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Check that a row painted incrementally renders as one painted whole.

A snapshot golden records what the renderer drew, and one golden alone cannot
say whether that was right. This pair can, because the two cases end with
identical cells and differ only in the path that painted them: one writes each
word in a single frame, the other writes every word one letter short and
completes it in a later frame, which is the frame that reuses the retained
target. Reuse changes the work, never the result — so the two images are the
same image, and a difference names the retained path drawing something the
full path does not.

The pairing is what makes the goldens an oracle. Without it a re-mint records
whatever the renderer did that day, on both sides, and the two agree by
construction while agreeing about nothing.

Why this class of defect needs it: a healing face substitutes letterforms on
context, so a row rebuilt without re-shaping keeps the forms its shorter self
had. No cell changed, so no damage reaches it; the row is not blank, so a
non-blank check passes; and a single-frame tier never enters the path at all.
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import library_scripts  # noqa: E402 — the snapshot tier is Core's and is found through its root

# The snapshot tier's runner is Core's, and its goldens are spread over the
# repositories by file, so each golden is found in the checkout that holds it.
sys.path.insert(0, str(pathlib.Path(library_scripts.locate("Tests/Snapshots/run.py")).parent))
from run import read_png_rgb  # noqa: E402 — the tier's own decoder, one spelling

# The macOS native tier is the one that renders every frame of a frames case;
# the unifont tier holds a frames case's first frame only, so its directory
# has no typed half to pair with and is not checked here.
GOLDEN_ROOT = pathlib.Path("Tests/Snapshots/golden")
GOLDENS = [GOLDEN_ROOT / "native/coretext"]

# Each pair is two goldens that must be byte-identical because they hold
# identical cells: a whole-paint against an incremental final frame, or two
# frames of one case whose feeds returned the screen to the same state.
PAIRS = [
    ("monaspace_healed_row_whole.png", "monaspace_healed_row_typed_typed.png"),
    # A letter overwritten mid-word re-heals its neighbours.
    ("monaspace_healed_edit_done.png", "monaspace_healed_edit_edit.png"),
    # A word shortened from its tail re-shapes like a fresh paint of it.
    ("monaspace_healed_backspace_done.png", "monaspace_healed_backspace_erase.png"),
    # The live flip's shape: a spinner inside the shaping-context window of
    # static words cycles back to its first character, and the two frames
    # with identical cells must be one picture.
    ("monaspace_healed_neighbor.png", "monaspace_healed_neighbor_s4.png"),
    # The completion pair under each font setting that moves the pitch, the
    # letterforms, or the weight.
    ("monaspace_healed_tracked_done.png", "monaspace_healed_tracked_typed.png"),
    ("monaspace_healed_wide_done.png", "monaspace_healed_wide_typed.png"),
    ("monaspace_healed_weighted_done.png", "monaspace_healed_weighted_typed.png"),
]

# Pairs whose images may differ at the cursor's two sites and nowhere else. The
# comparison diffs the pair, clusters the differing pixels by column gaps,
# and demands at most two clusters, each no larger than a cursor block with
# its antialiased fringe. The cursor must not affect texture healing at all:
# a cursor that re-shapes the word it sits on moves ink outside its own
# block, which either widens a cluster past a cell or opens a third one.
# (columns, rows) is the case's grid, for the cluster size bound.
CURSOR_PAIRS = [
    ("monaspace_healed_cursor.png", "monaspace_healed_cursor_moved.png", (30, 5)),
]


def cursor_pair_mismatch(first, second, grid):
    width, height, first_pixels = read_png_rgb(first)
    second_width, second_height, second_pixels = read_png_rgb(second)
    if (width, height) != (second_width, second_height):
        return "the two goldens are different sizes"
    differing = []
    for y in range(height):
        row_start = y * width * 3
        for x in range(width):
            i = row_start + x * 3
            if first_pixels[i:i + 3] != second_pixels[i:i + 3]:
                differing.append((x, y))
    if not differing:
        # The cursor is visible and moved, so identical images mean it was
        # never drawn — a pair that compares two cursorless frames asserts
        # nothing about the cursor.
        return "the pair is identical, so no cursor was drawn and nothing was tested"
    columns, rows = grid
    cell_w, cell_h = width / columns, height / rows
    differing.sort()
    clusters = []
    for x, y in differing:
        if clusters and x - clusters[-1][1] <= int(cell_w):
            box = clusters[-1]
            clusters[-1] = [min(box[0], x), max(box[1], x), min(box[2], y), max(box[3], y)]
        else:
            clusters.append([x, x, y, y])
    if len(clusters) > 2:
        return "%d difference clusters where the two cursor sites allow two" % len(clusters)
    for box in clusters:
        if box[1] - box[0] > cell_w * 2 or box[3] - box[2] > cell_h * 1.5:
            return ("a difference cluster spans (%d,%d)-(%d,%d), larger than a cursor block"
                    % (box[0], box[2], box[1], box[3]))
    return None


def main():
    failures = []
    for golden in GOLDENS:
        failures.extend(check_tier(golden))
    if failures:
        for line in failures:
            print(f"check-healing-frame-pair: {line}", file=sys.stderr)
        print(
            "\nThe two cases end with identical cells. Render them and look at both:\n"
            "  python3 Tests/Snapshots/run.py --backend macos "
            + " ".join(name.removesuffix(".png") for pair in PAIRS for name in pair),
            file=sys.stderr,
        )
        return 1
    return 0


def check_tier(GOLDEN):
    failures = []
    for whole_name, typed_name in PAIRS:
        whole, typed = (pathlib.Path(library_scripts.locate(str(GOLDEN / name))) for name in (whole_name, typed_name))
        missing = [p.name for p in (whole, typed) if not p.is_file()]
        if missing:
            # A missing half is not an absent check, it is an unnoticed one:
            # comparing nothing reports the same silence as comparing equals.
            failures.append(f"{', '.join(missing)}: golden missing, so the pair compared nothing")
            continue
        if whole.read_bytes() != typed.read_bytes():
            failures.append(
                f"{whole_name} != {typed_name}: the retained path drew a frame the full path did not"
            )

    for first_name, second_name, grid in CURSOR_PAIRS:
        first, second = (pathlib.Path(library_scripts.locate(str(GOLDEN / name))) for name in (first_name, second_name))
        missing = [p.name for p in (first, second) if not p.is_file()]
        if missing:
            failures.append(f"{', '.join(missing)}: golden missing, so the cursor pair compared nothing")
            continue
        mismatch = cursor_pair_mismatch(first, second, grid)
        if mismatch:
            failures.append(f"{first_name} vs {second_name}: {mismatch} — the cursor changed the text around it")

    return failures



if __name__ == "__main__":
    sys.exit(main())
