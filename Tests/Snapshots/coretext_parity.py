#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Hold the renderer's proportional text to CoreText, pixel for pixel.

A page of prose is set one proportional run per line (Docs/proportional-text.md)
and rendered by the snapshot tool on the macOS or Swift arm; the same page is
drawn by CoreText itself (coretext_reference.swift, one CTLineDraw per line in
the same face at the same pens) into a bitmap of the same size. The two are
compared pixel for pixel: the count of differing pixels, the largest channel
difference, and the rows that differ. The target is zero — the renderer draws
the glyphs CoreText shapes at the positions CoreText places them, on the grid
CoreText quantises to — and a difference names a glyph, a phase or a blend the
renderer got wrong.

    python3 Tests/Snapshots/coretext_parity.py                 # macos arm, bundled prose
    python3 Tests/Snapshots/coretext_parity.py --backend swift
    python3 Tests/Snapshots/coretext_parity.py --text my.txt --keep out/

Exit 0 when the pages match within --tolerance (default 0 pixels), 1 otherwise,
2 when a render could not be made. Stdlib only; the reference is compiled with
swiftc on first use into the build root.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "Scripts"))
import build_root  # noqa: E402
import run  # noqa: E402

BUILD_ROOT = Path(build_root.build_root(str(ROOT)))
CONFIG = HERE / "configs" / "macos_specimen.toml"
PROSE = HERE / "fixtures" / "coretext_parity_prose.txt"
REFERENCE_SOURCE = HERE / "coretext_reference.swift"
# The proportional face's size for the config's 13pt grid: Core's
# automaticProportionalPointSize, 13 * 1.08 to a quarter point.
POINT_SIZE = 14.0
ESC = "\x1b"
BEL = "\x07"


def theme_colors(config_path):
    """The foreground and background hex of the theme the config names."""
    theme = re.search(r'^theme\s*=\s*"([^"]+)"', config_path.read_text(), re.M).group(1)
    themes = (ROOT / "Source" / "Core" / "Themes" / "builtin-themes.toml").read_text()
    block = re.search(r'name = "%s"\n(.*?)(?=\n\[\[themes\]\]|\Z)' % re.escape(theme), themes, re.S).group(1)
    fg = re.search(r'^fg\s*=\s*"(#[0-9a-fA-F]{6})"', block, re.M).group(1)
    bg = re.search(r'^bg\s*=\s*"(#[0-9a-fA-F]{6})"', block, re.M).group(1)
    return fg, bg


def reference_binary():
    """The compiled reference, rebuilt when its source is newer."""
    out = BUILD_ROOT / "coretext_reference"
    if not out.exists() or out.stat().st_mtime < REFERENCE_SOURCE.stat().st_mtime:
        out.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", "-o", str(out), str(REFERENCE_SOURCE)], check=True)
    return out


def render_page(binary, backend, lines, columns, rows, snapshot_path, extra_args):
    """Renders the page through the snapshot tool; returns its metrics line."""
    feed = ESC + "[?25l"
    for line in lines:
        # One run per line, its claim the protocol's widest (32 cells) or the
        # width less the margin cell, left-set: the layout's alignment is
        # measured by the goldens, this measures the glyphs. A line wider than
        # its claim is clipped by the run, so the prose keeps to about forty
        # characters of the system face at POINT_SIZE.
        if line:
            feed += ESC + "]66;p=1:c=%d;%s" % (min(columns - 2, 32), line) + BEL
        feed += "\r\n"
    arguments = [
        str(binary), "--snapshot", str(snapshot_path), "--snapshot-backend", backend,
        "--columns", str(columns), "--rows", str(rows), "--config", str(CONFIG),
        "--feed", feed, "--draws-sized-text", "--print-metrics",
    ] + extra_args
    result = subprocess.run(arguments, capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError("app exited %d: %s" % (result.returncode, result.stderr.decode("utf-8", "replace").strip()))
    metrics = {}
    for line in result.stdout.decode("utf-8", "replace").splitlines():
        if line.startswith("metrics "):
            metrics = dict(pair.split("=") for pair in line.split()[1:])
    if not metrics:
        raise RuntimeError("the snapshot tool printed no metrics line; is --print-metrics known to this build?")
    return metrics


def compare(actual, reference):
    """Differing pixel count, largest channel delta, and the rows that differ."""
    width, height, a = actual
    rwidth, rheight, r = reference
    if (width, height) != (rwidth, rheight):
        raise RuntimeError("sizes differ: render %dx%d, reference %dx%d" % (width, height, rwidth, rheight))
    differing = 0
    worst = 0
    rows = set()
    for y in range(height):
        row = y * width * 3
        for x in range(width):
            i = row + x * 3
            d = max(abs(a[i] - r[i]), abs(a[i + 1] - r[i + 1]), abs(a[i + 2] - r[i + 2]))
            if d:
                differing += 1
                rows.add(y)
                if d > worst:
                    worst = d
    return differing, worst, sorted(rows)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--backend", choices=("macos", "swift"), default="macos")
    parser.add_argument("--text", type=Path, default=PROSE, help="one line of prose per line")
    parser.add_argument("--columns", type=int, default=34)
    parser.add_argument("--tolerance", type=int, default=0, help="differing pixels allowed")
    parser.add_argument("--keep", type=Path, help="directory to keep the render, the reference and a diff in")
    parser.add_argument("--binary", help="the app binary; found in the build root by default")
    args = parser.parse_args(argv)

    lines = args.text.read_text(encoding="utf-8").rstrip("\n").split("\n")
    rows = len(lines) + 1
    binary = Path(args.binary) if args.binary else run.find_binary(None, args.backend)
    fg, bg = theme_colors(CONFIG)
    keep = args.keep or Path(tempfile.mkdtemp(prefix="coretext-parity-"))
    keep.mkdir(parents=True, exist_ok=True)
    render_path = keep / ("render-%s.png" % args.backend)
    reference_path = keep / "reference.png"
    lines_path = keep / "lines.txt"
    lines_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    try:
        metrics = render_page(binary, args.backend, lines, args.columns, rows, render_path, [])
    except RuntimeError as error:
        print("coretext-parity: REFUSED — %s" % error)
        return 2
    scale = float(metrics["scale"])
    cell_width = float(metrics["cellWidthPoints"]) * scale
    cell_height = float(metrics["cellHeightPoints"]) * scale
    origin_x = float(metrics["paddingLeftPoints"]) * scale
    origin_y = float(metrics["paddingTopPoints"]) * scale
    baseline = float(metrics["baselineFromTopPoints"]) * scale
    width, height, _ = run.read_png_rgb(render_path)
    subprocess.run([
        str(reference_binary()), str(reference_path), str(width), str(height), "%g" % scale, "%g" % POINT_SIZE,
        "%.6f" % cell_width, "%.6f" % cell_height, "%.6f" % origin_x, "%.6f" % origin_y, "%.6f" % baseline,
        fg, bg, str(lines_path),
    ], check=True)

    actual = run.read_png_rgb(render_path)
    reference = run.read_png_rgb(reference_path)
    differing, worst, diff_rows = compare(actual, reference)
    total = width * height
    print("coretext-parity: %s arm, %d line(s), %dx%d px: %d differing pixel(s) of %d (%.4f%%), largest channel delta %d"
          % (args.backend, len(lines), width, height, differing, total, 100.0 * differing / total, worst))
    if diff_rows:
        lines_hit = sorted({int(y // cell_height) for y in diff_rows if y >= origin_y})
        print("  rows with differences: %s" % ", ".join(str(r) for r in lines_hit[:20]) + (" …" if len(lines_hit) > 20 else ""))
    print("  render %s\n  reference %s" % (render_path, reference_path))
    if differing > args.tolerance:
        print("coretext-parity: FAILED — the renderer and CoreText disagree; open the two images side by side")
        return 1
    print("coretext-parity: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
