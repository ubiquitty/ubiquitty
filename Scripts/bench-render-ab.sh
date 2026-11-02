#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
#
# Scripts/bench-render-ab.sh — paired A/B of two built Ubiquitty.app bundles on
# one --profile-render lane.
#
#   bench-render-ab.sh <before.app> <after.app> [lane]
#
# Runs the two arms interleaved with an alternating lead. Pairing cancels steady
# load because both arms meet it in the same round; alternating stops a warm-up
# or a thermal ramp from landing on the same arm every time. What pairing cannot
# cancel is load CHANGING mid-round, which is why best-of-N is reported beside
# the mean: on a contended machine the mean tracks the machine and the best
# tracks the code.
#
# Read the two together. When they disagree by more than a point or so the
# machine is too busy for the effect size, and the answer is more rounds or a
# quieter box — not the more flattering number.
set -uo pipefail

BEFORE="${1:?usage: bench-render-ab.sh <before.app> <after.app> [lane]}"
AFTER="${2:?usage: bench-render-ab.sh <before.app> <after.app> [lane]}"
# The builder path's cost by default: capture + build, the whole of what a
# shipping frame spends above the encoder. The lane has no paired arm to cancel
# noise against, so interleaved rounds with an alternating lead and best-of-N
# are the whole defence. `_corebuildonly` isolates the build half;
# `_corecapture` the capture half.
LANE="${3:-render_text_corebuild}"
# Everything after the lane goes to both arms. Without it the only reachable
# configuration is the default one, and the default SUPPRESSES the retained
# grid — so a change to the damaged-frame path, which is the path a shipping
# frame takes, could not be A/B'd at all.
shift 3 2>/dev/null || shift $# 
EXTRA=("$@")

# A bundle linked against an unmapped QUIC prefix records the directory it was
# built in: aws-lc carries __FILE__ through, so its absolute source paths are
# embedded in the binary. Two builds of the same source at different paths
# therefore differ in every adrp/add pair that reaches a string past the first
# embedded path, and hash differently.
#
# That breaks the guard below rather than the timing directly: two bundles built
# from identical source in sibling worktrees hash differently, so "nothing to
# compare" never fires and the run reports noise as an effect. The check is
# whether they were built at the same PATH, which is not implied by being built
# at the same commit.
#
# The tree's optimized compiles map the checkout, its build directory and the
# QUIC prefix to relative names (CMakeLists.txt), and Scripts/fetch-quic-deps.sh
# builds AWS-LC and ngtcp2 with the same map, so those __FILE__ strings do not
# name the directory. The app is RelWithDebInfo, and its debug information keeps
# absolute paths for Instruments and lldb, so an unstripped bundle still names
# its sources in the debug map dsymutil reads. Until both arms are known to
# carry no path that moves an address, building them in one directory is what
# makes them comparable — `git checkout` in place, not a second worktree.
#
# Two markers rather than one, because the obvious single marker is absent from
# the configuration that most needs the check: aws-lc disappears under
# UBIQUITTY_QUIC=OFF, which is what the external bench harness builds, while
# re2 under Source/ThirdParty carries its paths through either way. A marker
# list that misses the interesting configuration is a check that passes by
# finding nothing. The aws-lc paths, in a bundle that has them, name the
# checkout's build root, where the QUIC prefix lives, and re2's name the
# checkout, through __FILE__ in an unmapped build and through the debug map in
# any unstripped one; either one differs between two checkouts.
buildRootOf() {
    strings -a "$1/Contents/MacOS/Ubiquitty" 2>/dev/null \
        | grep -oE "^/.*/(quic-deps|Source/ThirdParty)/" \
        | sed -E 's#(quic-deps|Source/ThirdParty)/$##' \
        | sort -u | head -1
}
BEFORE_ROOT="$(buildRootOf "$BEFORE")"
AFTER_ROOT="$(buildRootOf "$AFTER")"
if [ -z "$BEFORE_ROOT" ] || [ -z "$AFTER_ROOT" ]; then
    # Saying nothing here would be the same output as a clean comparison, and
    # the reason the roots went missing is likelier to be a marker that moved
    # than a binary that stopped recording them.
    echo "bench-render-ab.sh: cannot tell which directories these were built in;" >&2
    echo "  no embedded third-party paths found. The arms may or may not be" >&2
    echo "  comparable and this run does not know which. Check the markers in" >&2
    echo "  buildRootOf against the tree before trusting the numbers." >&2
elif [ "$BEFORE_ROOT" != "$AFTER_ROOT" ]; then
    echo "bench-render-ab.sh: the two bundles were built in different directories:" >&2
    echo "    $BEFORE_ROOT" >&2
    echo "    $AFTER_ROOT" >&2
    echo "  Embedded source paths shift every literal address, so the binaries differ" >&2
    echo "  whether or not the code does. Rebuild both arms in one directory." >&2
    exit 2
fi

# Two identical binaries always answer "no effect", which looks exactly like a
# change that did not work. Refuse rather than report it.
if [ "$(/usr/bin/shasum -a 256 "$BEFORE/Contents/MacOS/Ubiquitty" 2>/dev/null | cut -d" " -f1)" \
   = "$(/usr/bin/shasum -a 256 "$AFTER/Contents/MacOS/Ubiquitty" 2>/dev/null | cut -d" " -f1)" ]; then
    echo "bench-render-ab.sh: the two bundles carry the same binary — nothing to compare" >&2
    exit 2
fi
FRAMES="${FRAMES:-250}"
ROUNDS="${ROUNDS:-12}"
RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT

for side in "$BEFORE" "$AFTER"; do
    [ -x "$side/Contents/MacOS/Ubiquitty" ] || { echo "not a built bundle: $side" >&2; exit 1; }
done

sample() {
    "$1/Contents/MacOS/Ubiquitty" --profile-render --frames "$FRAMES" ${EXTRA[@]+"${EXTRA[@]}"} 2>/dev/null \
        | sed -n "s/.*\"$LANE\".*\"p50\": \([0-9.]*\).*/\1/p"
}

for round in $(seq 1 "$ROUNDS"); do
    if [ $((round % 2)) -eq 0 ]; then order="before after"; else order="after before"; fi
    for arm in $order; do
        [ "$arm" = before ] && path="$BEFORE" || path="$AFTER"
        value="$(sample "$path")"
        [ -n "$value" ] && printf '%s %s\n' "$arm" "$value" >> "$RESULTS"
    done
done

awk -v lane="$LANE" -v rounds="$ROUNDS" '
    NF == 2 { total[$1] += $2; ++count[$1]
              if (best[$1] == 0 || $2 + 0 < best[$1]) best[$1] = $2 + 0 }
    END {
        if (count["before"] == 0 || count["after"] == 0) {
            print "no samples parsed — is the lane name right?"; exit 1
        }
        printf "lane %s, %d frames, %d/%d rounds kept\n", lane, ENVIRON["FRAMES"], count["before"], rounds
        for (arm in total)
            printf "  %-7s mean %8.3f us   best %8.3f us\n", arm, total[arm]/count[arm], best[arm]
        meanDelta = (total["after"]/count["after"] - total["before"]/count["before"]) / (total["before"]/count["before"]) * 100
        bestDelta = (best["after"] - best["before"]) / best["before"] * 100
        printf "  delta   mean %+7.2f%%   best %+7.2f%%\n", meanDelta, bestDelta
        gap = meanDelta - bestDelta; if (gap < 0) gap = -gap
        if (gap > 1.5)
            printf "  the two disagree by %.1f points: the machine moved during the run\n", gap
    }' "$RESULTS"
