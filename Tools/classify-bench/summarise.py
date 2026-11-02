#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Reduces repeated classify_bench runs and says whether the arms are separated.

Its own file rather than a -c one-liner: the report needs quoted format keys and
those cannot survive a single-quoted shell argument, which silently produced a
header reading `{min:>8}` and a TypeError under it.
"""

import statistics
import sys
from collections import defaultdict

ARMS = ("cpp_inline", "swift_safe", "swift_annotated")


def main() -> int:
    samples = defaultdict(list)
    for line in sys.stdin:
        parts = line.split()
        if len(parts) == 2 and parts[0] in ARMS:
            samples[parts[0]].append(float(parts[1]))
    if not samples:
        print("classify-bench: no arm lines on stdin", file=sys.stderr)
        return 2

    runs = len(next(iter(samples.values())))
    print()
    print("classify_bench: fused row-flag predicate, %d runs, ns/codepoint" % runs)
    print("%-18s%8s%9s%8s%9s" % ("arm", "min", "median", "max", "spread"))
    for arm in ARMS:
        values = samples.get(arm)
        if not values:
            continue
        print("%-18s%8.3f%9.3f%8.3f%9.3f"
              % (arm, min(values), statistics.median(values), max(values), max(values) - min(values)))

    # The verdict, rather than a table someone has to squint at. A single run
    # routinely reports noise between close arms as a language difference.
    widest = max(max(v) - min(v) for v in samples.values())
    medians = [statistics.median(v) for v in samples.values()]
    apart = max(medians) - min(medians)
    print()
    print("medians span %.3f ns; widest per-arm spread %.3f ns" % (apart, widest))
    if apart > widest:
        print("the arms ARE separated by this run")
    else:
        print("WITHIN NOISE: this run does not separate the languages")
    return 0


if __name__ == "__main__":
    sys.exit(main())
