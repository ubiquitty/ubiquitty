#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Check the updater's kernel path contract against a real AppImage mount.

Run on Linux with FUSE available: test_appimage_mount.py PACKAGE.AppImage
"""

import os
from pathlib import Path
import re
import select
import shutil
import subprocess
import sys
import tempfile


def check(package):
    helper = shutil.which("fusermount3") or shutil.which("fusermount")
    if not helper:
        raise RuntimeError("install FUSE's fusermount helper before this check")
    with tempfile.TemporaryDirectory(prefix="ubq-appimage-") as directory:
        image = Path(directory) / "Ubiquitty space,comma\\slash.AppImage"
        shutil.copy2(package, image)
        environment = dict(os.environ)
        for name in ("APPIMAGE_EXTRACT_AND_RUN", "TARGET_APPIMAGE"):
            environment.pop(name, None)
        process = subprocess.Popen([str(image), "--appimage-mount"], stdout=subprocess.PIPE, env=environment)
        mountpoint = None
        try:
            if not select.select([process.stdout], [], [], 15)[0]:
                raise RuntimeError("AppImage mount did not report readiness")
            mountpoint = process.stdout.readline().decode().strip()
            if not mountpoint.startswith("/tmp/") or not Path(mountpoint).is_mount():
                raise RuntimeError(f"AppImage did not mount: {mountpoint}")
            decode = lambda value: re.sub(r"\\([0-7]{3})", lambda match: chr(int(match[1], 8)), value)
            records = [line.split() for line in Path("/proc/self/mountinfo").read_text().splitlines()]
            records = [fields for fields in records if decode(fields[4]) == mountpoint]
            if len(records) != 1:
                raise RuntimeError("the kernel did not name exactly one AppImage mount")
            fields = records[0]
            source = decode(fields[fields.index("-") + 2])
            if source != str(image.resolve()):
                raise RuntimeError(f"mount source {source!r} does not identify {str(image)!r}")
            print("AppImage mount source: canonical path, spaces, comma and backslash PASS")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            if mountpoint and Path(mountpoint).is_mount():
                detached = subprocess.run([helper, "-u", "-z", mountpoint], capture_output=True)
                if detached.returncode and Path(mountpoint).is_mount():
                    raise RuntimeError(f"test mount remains attached: {mountpoint}")


if __name__ == "__main__":
    check(Path(sys.argv[1]).resolve())
