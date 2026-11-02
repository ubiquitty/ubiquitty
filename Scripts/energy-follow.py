#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# energy-follow.py — a live comparison of an energy run still in progress.
#
#   tail -f -n +1 <results.ndjson> | Scripts/energy-follow.py
#
# The harnesses emit NDJSON because that is what survives being appended to by a
# long run and re-read afterwards. Watching it go past as JSON tells you a run is
# alive and nothing else — the question while a matrix runs is which arm is
# winning and by how much, and that is a shape, not a line. So this redraws a
# ranked bar per group on every sample.
#
# Bars are scaled within their own group, because the two scenarios differ
# widely in cost and one shared scale would flatten the idle group to nothing.
# The multiplier is against the cheapest arm in the group, which is the
# comparison worth reading; the absolute number is beside it for the one
# against a previous run.
#
# Medians, not means: these runs are three reps and a single scheduling outlier
# moves a mean of three by more than the effects being measured.
#
# A sample that lost focus, or whose launch resolved the wrong process, is
# counted as dropped and never enters a median. An unfocused terminal freezes
# its caret and stops drawing, so it reports a near-zero that would otherwise
# read as the arm winning.

import json
import statistics
import sys

BAR_WIDTH = 34
BLOCKS = " ▏▎▍▌▋▊▉█"

RESET, BOLD, DIM = "\033[0m", "\033[1m", "\033[2m"
CYAN, GREEN, YELLOW, RED = "\033[36m", "\033[32m", "\033[33m", "\033[31m"

# The subject of the investigation is highlighted, so a matrix of five arms can
# be read at a glance for the one question being asked of it.
SUBJECT = "ubiquitty"


def bar(value, largest):
    """A bar in eighth-of-a-cell steps, so small values stay visible."""
    if largest <= 0:
        return ""
    eighths = int(round((value / largest) * BAR_WIDTH * 8))
    full, remainder = divmod(max(eighths, 1), 8)
    return "█" * full + (BLOCKS[remainder] if remainder else "")


def colour_for(multiplier):
    if multiplier is None or multiplier < 1.5:
        return GREEN
    if multiplier < 3.0:
        return YELLOW
    return RED


def render(groups, dropped, meta, sizes):
    out = ["\033[H\033[J"]  # home, then clear to end — no flicker from a full wipe
    total = sum(len(values) for group in groups.values() for values in group.values())
    out.append(f"{BOLD}ENERGY{RESET}  {meta}")
    out.append(f"{DIM}macOS energy impact, median of n · lower is better · "
               f"{total} samples{', ' + str(dropped) + ' dropped' if dropped else ''}{RESET}")
    out.append("")

    for group_name, rows in groups.items():
        ranked = sorted(((name, statistics.median(v), len(v)) for name, v in rows.items()),
                        key=lambda row: row[1])
        largest = max((median for _, median, _ in ranked), default=0.0)
        best = next((median for _, median, _ in ranked if median > 0), None)

        out.append(f"{BOLD}{group_name}{RESET}")
        for name, median, count in ranked:
            multiplier = (median / best) if best and median > 0 else None
            tint = colour_for(multiplier)
            label = f"{CYAN}{BOLD}{name:<22}{RESET}" if name == SUBJECT else f"{name:<22}"
            times = f"{multiplier:>5.1f}×" if multiplier and multiplier > 1.05 else "      "
            size = sizes.get(name)
            size_text = f"{size[0]}x{size[1]}pt" if size else ""
            out.append(f"  {label}{tint}{bar(median, largest):<{BAR_WIDTH + 1}}{RESET}"
                       f"{median:>6.1f}  {times}  {DIM}n={count}  {size_text}{RESET}")
        out.append("")

    sys.stdout.write("\n".join(out))
    sys.stdout.flush()


def main():
    groups, dropped, meta, sizes = {}, 0, "", {}
    for line in sys.stdin:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue

        if row.get("error") or row.get("focused") is False:
            dropped += 1
            render(groups, dropped, meta, sizes)
            continue

        # The cross-terminal harness compares terminals within a scenario; the
        # single-app harness compares scenarios and has no terminal field.
        if "terminal" in row:
            group_name, series = row["scenario"], row["terminal"]
        else:
            group_name, series = "scenario", row["scenario"]

        if not meta:
            parts = [row.get("font"), row.get("grid")]
            if "blink" in row:
                parts.append("caret blinking" if row["blink"] else "caret still")
            meta = f"{DIM}" + " · ".join(p for p in parts if p) + RESET
        # Window size is read back per arm rather than assumed from the geometry
        # each terminal was asked for, so a terminal that ignored the request is
        # visible here instead of being compared at a different area.
        if row.get("window_points"):
            sizes.setdefault(series, row["window_points"])

        groups.setdefault(group_name, {}).setdefault(series, []).append(row["power_impact"])
        render(groups, dropped, meta, sizes)

    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
