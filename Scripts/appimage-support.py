#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Assemble and verify the runtime, updater, notices and matching source archives.

    appimage-support.py assemble OUTPUT ARCH UPDATER RUNTIME RUNTIME_SOURCES RUNTIME_NOTICES
    appimage-support.py verify SUPPORT ARCH
    appimage-support.py stage SUPPORT ARCH APPDIR VERSION DIST
"""

import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import sys
import tarfile


MACHINES = {"x86_64": 62, "aarch64": 183}
ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify(root, architecture):
    if architecture not in MACHINES:
        raise ValueError("unsupported AppImage architecture")
    manifest = json.loads((root / "manifest.json").read_text())
    if manifest.get("architecture") != architecture:
        raise ValueError("the support bundle belongs to another architecture")
    files = manifest.get("files")
    if not isinstance(files, dict) or not {"runtime", "updater/bin/appimageupdatetool", "support-sources.tar.xz"} <= files.keys():
        raise ValueError("the support bundle is missing its runtime, updater or sources")
    for name, expected in files.items():
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts or str(relative) != name:
            raise ValueError("a support path escapes its bundle")
        path = root / name
        if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()) or digest(path) != expected:
            raise ValueError(f"support file differs: {name}")
    actual_files = {str(path.relative_to(root)) for path in root.rglob("*") if path.is_file() and path != root / "manifest.json"}
    if actual_files != files.keys():
        raise ValueError("unrecorded files in support bundle")
    for name in ("runtime", "updater/bin/appimageupdatetool"):
        with (root / name).open("rb") as stream:
            header = stream.read(20)
        if header[:6] != b"\x7fELF\x02\x01" or int.from_bytes(header[18:20], "little") != MACHINES[architecture]:
            raise ValueError(f"wrong ELF architecture: {name}")
    return manifest


def assemble(output, architecture, updater, runtime, runtime_sources, runtime_notices):
    updater_sources = updater.parent / f"updater-sources-{architecture}.tar.xz"
    for source in (runtime_sources, updater_sources):
        with tarfile.open(source) as archive:
            if not archive.getmembers():
                raise ValueError(f"empty source archive: {source}")
    output.mkdir(parents=True, exist_ok=True)
    shutil.copy2(runtime, output / "runtime")
    shutil.copytree(updater, output / "updater", dirs_exist_ok=True)
    shutil.copytree(runtime_notices, output / "runtime-notices", dirs_exist_ok=True)
    with tarfile.open(output / "support-sources.tar.xz", "w:xz", preset=0) as archive:
        archive.add(updater_sources, arcname=updater_sources.name)
        archive.add(runtime_sources, arcname="runtime-sources.tar.xz")
        archive.add(ROOT / "LICENSE", arcname="tooling-LICENSE")
        archive.add(ROOT / "NOTICE", arcname="tooling-NOTICE")
    files = {str(path.relative_to(output)): digest(path) for path in sorted(output.rglob("*"))
             if path.is_file() and path != output / "manifest.json"}
    (output / "manifest.json").write_text(json.dumps({"architecture": architecture, "files": files}, indent=2) + "\n")
    verify(output, architecture)


def stage(root, architecture, appdir, version, dist):
    verify(root, architecture)
    shutil.copy2(root / "updater/bin/appimageupdatetool", appdir / "usr/bin/appimageupdatetool")
    shutil.copytree(root / "updater/lib", appdir / "usr/lib/ubiquitty-updater", dirs_exist_ok=True)
    documents = appdir / "usr/share/doc/ubiquitty/appimage-support"
    shutil.copytree(root / "updater/notices", documents / "updater", dirs_exist_ok=True)
    shutil.copytree(root / "runtime-notices", documents / "runtime", dirs_exist_ok=True)
    shutil.copy2(root / "updater/provenance.json", documents / "updater-provenance.json")
    name = f"Ubiquitty-{version}-{architecture}-support-sources.tar.xz"
    shutil.copy2(root / "support-sources.tar.xz", dist / name)
    (documents / "README.txt").write_text(
        "AppImage runtime and updater notices are preserved in this directory.\n"
        "Matching sources, patches and build recipes are available alongside the release:\n"
        f"https://ubiquitty.org/download/linux/{version}/{name}\n"
        "The updater libraries are replaceable: extract the AppImage, replace the library\n"
        "in usr/lib/ubiquitty-updater, then run AppRun or repack with appimagetool.\n")


def main(arguments):
    try:
        if len(arguments) == 7 and arguments[0] == "assemble":
            assemble(Path(arguments[1]), arguments[2], *map(Path, arguments[3:]))
        elif len(arguments) == 3 and arguments[0] == "verify":
            verify(Path(arguments[1]), arguments[2])
        elif len(arguments) == 6 and arguments[0] == "stage":
            stage(Path(arguments[1]), arguments[2], Path(arguments[3]), arguments[4], Path(arguments[5]))
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except (OSError, ValueError) as error:
        print(f"appimage-support: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
