#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Checks that Swift snapshot font flags override the supplied configuration."""

import argparse
from pathlib import Path
import subprocess
import tempfile

from run import read_png_rgb


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="ubiquitty-font-overrides-") as directory:
        root = Path(directory)
        original = root / "original.toml"
        effective = root / "effective.toml"
        typography = '\nline_spacing = 3\ncharacter_spacing = 1\nweight = 500\n'
        original.write_text('[font]\nfamily = "Menlo"\nsize = 12' + typography)
        effective.write_text('[font]\nfamily = "JetBrains Mono"\nsize = 20' + typography)
        for scale in (1, 2):
            renders = {}
            for name, configuration, overrides in (
                ("original", original, []),
                ("flags", original, ["--font", "JetBrains Mono", "--size", "20"]),
                ("configuration", effective, []),
            ):
                output = root / f"{name}-{scale}.png"
                result = subprocess.run(
                    [arguments.binary, "--snapshot", str(output), "--snapshot-backend", "swift",
                     "--config", str(configuration), "--columns", "20", "--rows", "4",
                     "--scale", str(scale), "--feed", r"\e[?25lFont override test"] + overrides,
                    capture_output=True, text=True, timeout=40,
                )
                if result.returncode:
                    raise RuntimeError(result.stdout + result.stderr)
                renders[name] = read_png_rgb(output)
            assert renders["flags"] == renders["configuration"], f"scale {scale}: flags and effective configuration render differently"
            assert renders["flags"][0] > renders["original"][0], f"scale {scale}: the larger font did not widen the image"
            assert renders["flags"][1] > renders["original"][1], f"scale {scale}: the larger font did not increase image height"
    print("snapshot font overrides: PASS (family, size, spacing, weight, scales 1 and 2)")


if __name__ == "__main__":
    main()
