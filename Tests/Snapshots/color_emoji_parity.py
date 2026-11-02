#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Measures native-size and OSC 66 emoji against independent CoreText rasters.

Requires macOS, Swift, and Pillow. Uses bundled JetBrains Mono at 12 points:
its 14.4-device-pixel advance at scale 2 exercises fractional cell geometry.
Opaque source pixels isolate colour and resampling from edge compositing.
"""

import argparse
import math
import subprocess
import tempfile
from pathlib import Path

from PIL import Image

import run


def measure(binary, backend, scale, directory, reference):
    config = directory / "emoji.toml"
    config.write_text('[font]\nfamily = "JetBrains Mono"\nsize = 12\n'
                      '[appearance]\ntheme = "Noir Clair"\n')
    output = directory / f"{backend}-{scale}.png"
    result = subprocess.run([
        str(binary), "--snapshot", str(output), "--snapshot-backend", backend,
        "--config", str(config), "--columns", "12", "--rows", "5",
        "--feed", "\x1b[?25l😀\r\n\x1b]66;s=3;😀\x07",
        "--draws-sized-text", "--scale", str(scale), "--print-metrics",
    ], capture_output=True, text=True, check=True, timeout=60)
    diagnostics = result.stdout + result.stderr
    if 'font "JetBrains Mono" resolved' not in diagnostics:
        raise RuntimeError("JetBrains Mono did not resolve; refusing fallback measurements")
    metrics = next(dict(pair.split("=") for pair in line.split()[1:])
                   for line in diagnostics.splitlines() if line.startswith("metrics "))
    width = float(metrics["cellWidthPoints"]) * scale
    height = float(metrics["cellHeightPoints"]) * scale
    origin_x = float(metrics["paddingLeftPoints"]) * scale
    origin_y = float(metrics["paddingTopPoints"]) * scale
    slot = math.floor(min(2 * width, height))
    actual = Image.open(output).convert("RGB")
    passed = True
    for factor, row in ((1, 0), (3, 1)):
        side = slot * factor
        expected_path = directory / f"reference-{side}.png"
        subprocess.run([str(reference), str(side), str(expected_path)], check=True)
        expected = Image.open(expected_path).convert("RGBA")
        left = math.floor(origin_x + (2 * width * factor - side) / 2 + 0.5)
        top = math.floor(origin_y + row * height + (height * factor - side) / 2 + 0.5)
        crop = actual.crop((left, top, left + side, top + side))
        differences = [abs(a - b)
                       for observed, wanted in zip(crop.getdata(), expected.getdata())
                       if wanted[3] == 255
                       for a, b in zip(observed, wanted[:3])]
        if not differences:
            raise RuntimeError("CoreText produced no opaque pixels")
        worst = max(differences)
        mean = sum(differences) / len(differences)
        print(f"{backend} scale={scale} cell={width:g}x{height:g} "
              f"emoji={factor}x square={side} opaque={len(differences) // 3} "
              f"max-channel={worst} mean-channel={mean:.4f}")
        passed &= worst <= 2
    return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--keep", type=Path)
    arguments = parser.parse_args()
    binary = arguments.binary.resolve()
    for backend in ("macos", "swift"):
        run._refuse_if_foreign(binary, backend)
        run._refuse_if_stale(binary, backend)
    with tempfile.TemporaryDirectory(prefix="ubq-emoji-") as temporary:
        directory = arguments.keep or Path(temporary)
        directory.mkdir(parents=True, exist_ok=True)
        reference = directory / "color_emoji_reference"
        subprocess.run(["xcrun", "swiftc", str(Path(__file__).with_name("color_emoji_reference.swift")),
                        "-o", str(reference)], check=True)
        results = [measure(binary, backend, scale, directory, reference)
                   for backend in ("macos", "swift") for scale in (1, 2)]
    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
