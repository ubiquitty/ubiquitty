#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Holds a busy screen to one rendering of the text that did not change.

One snapshot process renders a run of frames on the same terminal, the way a
live window does. A band of STATIC rows — operators a healing face ligates,
letters it substitutes — is painted once and never touched again, while other
regions churn: unique words minting fresh strips every frame, a spinner, a
tmux-style region rewritten verbatim with per-line SGR resets. Any pixel
change in the static band between two consecutive frames is the defect this
gate exists for: same cells, same style, different picture.

The refusal counter is asserted alongside, because the pixel oracle alone has
a blind spot: a refusal that happens to hit only churn rows repaints text that
was changing anyway, and the band stays green while newly arriving lines draw
unhealed. Zero refusals is the invariant the epoch-scoped pins are meant to
hold; a regression in the retention policy shows here first.

Live shape this pins (2026-08-20): ligatures (==, <=) and healed letterforms
(w, i, m in Monaspace) flipping several times a second while tmux or a spinner
ran, settling at whichever state the last grant left. Mechanism: strip-slot
pins accumulated across partial frames until the sheet refused, and a refused
run draws per-cell — unhealed, unligated — so each refusal window repainted
fresh runs one way and the correction repainted them the other.
"""

import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Tests/Snapshots"))
from run import read_png_rgb  # noqa: E402 — the tier's own decoder, one spelling

sys.path.insert(0, str(ROOT / "Scripts"))
import build_root as _build_root  # noqa: E402 — the path above is what makes it importable

# The app is built under the build root, which left the checkout.
APP = pathlib.Path(_build_root.build_root(str(ROOT))) / "macos/Source/Platform/macOS/Ubiquitty.app/Contents/MacOS/Ubiquitty"
CONFIG = ROOT / "Tests/Snapshots/configs/macos_monaspace_healing.toml"
COLS, ROWS = 120, 40

STATIC = {
    2: "a == b <= c != d >= e === f <=> g |> h ?? i :: j",
    3: "window tmux minimum illmw swimming mummification",
    4: "if (wi == tm) window <= tmux && illmw != minimum",
    5: "-> => <- <-> !== >>= =<< ++ -- ** // :: := =~ <<< >>>",
    6: "wit twin time term swim wind timid mist wilt tint",
    8: "static row == <= != wi tm window tmux illmw",
}
WORDS = ["window", "tmux", "minimum", "illmw", "swimming", "command", "million",
         "willow", "mammal", "filling", "running", "stemming", "climbing", "mimic",
         "twin", "time", "term", "wind", "wit", "swim"]


def esc(row, col, text):
    return "\\x1b[%d;%dH%s" % (row, col, text)


def churn(k):
    feed = ""
    for r in range(20, 39):
        words = " ".join(WORDS[(k * 7 + r * 3 + i) % len(WORDS)] + str((k * r + i) % 97)
                         for i in range(12))
        feed += esc(r, 1, words[: COLS - 2])
    return feed


def frame_feed(kind, k):
    feed = esc(1, 1, "%s frame %02d " % ("|/-\\\\"[k % 4], k))
    if kind == "pressure":
        feed += churn(k)
    if kind == "tmuxsim":
        for r in range(2, 19):
            feed += esc(r, 62, ("\\x1b[0m\\x1b[38;5;114m| " + " ".join(
                WORDS[(k * 5 + r * 7 + i) % len(WORDS)] for i in range(5)))[:56] + "\\x1b[0m")
        for r, text in STATIC.items():
            feed += esc(r, 1, "\\x1b[0m" + text)
    if kind == "scroll":
        # The region set in the base feed confines the scroll below the probe
        # band; the band itself must ride out every scroll untouched.
        feed += esc(ROWS, 1, "\\x1b[Kline %03d == <= wi tm window" % k) + "\\n"
    return feed


def run_scenario(kind, frames, out_dir):
    base = "\\x1b[?25l" + "".join(esc(r, 1, t) for r, t in STATIC.items())
    if kind == "scroll":
        base += "\\x1b[20;%dr" % ROWS
    if kind == "tmuxsim":
        base = "\\x1b[?1049h" + base + frame_feed(kind, 0)
    args = [str(APP), "--snapshot", str(out_dir / f"{kind}-00.png"),
            "--snapshot-backend", "macos", "--columns", str(COLS), "--rows", str(ROWS),
            "--config", str(CONFIG), "--feed", base]
    for k in range(1, frames):
        args += ["--also-feed", frame_feed(kind, k),
                 "--also-snapshot", str(out_dir / f"{kind}-{k:02d}.png")]
    env = dict(os.environ, UBQ_SHEETLOG="1")
    proc = subprocess.run(args, capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        return ["%s: the snapshot run failed: %s" % (kind, proc.stderr.strip()[-200:])]

    failures = []
    refused = [line for line in proc.stderr.splitlines()
               if "refused=" in line and "refused=0" not in line]
    if refused:
        failures.append("%s: the sheet refused strips: %s" % (kind, refused[-1].strip()))

    previous = None
    for k in range(frames):
        width, height, pixels = read_png_rgb(out_dir / f"{kind}-{k:02d}.png")
        row_height = height / ROWS
        y0, y1 = int(row_height * 1.1), int(row_height * 8.9)
        # The tmuxsim scenario churns a right-hand pane on the same rows, so
        # its probe is the left pane alone; the others own the full width.
        x1 = int(width / COLS * 58) * 3 if kind == "tmuxsim" else width * 3
        band = b"".join(pixels[y * width * 3: y * width * 3 + x1] for y in range(y0, y1))
        if previous is not None and band != previous:
            failures.append("%s: frame %02d repainted the static band differently" % (kind, k))
        previous = band
    return failures


def main():
    if not APP.is_file():
        print("check-ligature-determinism: REFUSED — no app at %s (build macOS first)" % APP,
              file=sys.stderr)
        return 2
    frames = 20
    kinds = ["pressure", "tmuxsim", "scroll"]
    if "--full" in sys.argv:
        frames = 48
    import tempfile
    failures = []
    with tempfile.TemporaryDirectory(prefix="ligature-determinism-") as scratch:
        for kind in kinds:
            failures += run_scenario(kind, frames, pathlib.Path(scratch))
    if failures:
        for line in failures:
            print("check-ligature-determinism: %s" % line, file=sys.stderr)
        return 1
    print("check-ligature-determinism: ok (%d scenario(s) x %d frames, static band stable, 0 refusals)"
          % (len(kinds), frames))
    return 0


if __name__ == "__main__":
    sys.exit(main())
