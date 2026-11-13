#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Prepare the pinned runtime build and archive its matching library sources."""

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request

RUNTIME = "fedfad51acc2860b2916a1eef32ba4a500ff31ef"
APORTS = "d3332621d44c2c4cf52e52217b16674db190212c"
BASE = "alpine:3.21@sha256:ee16d92f96db08d9d2d07da48555a27f3a69d8f0759021dbc601195ed0d2b5bd"
PACKAGES = ("musl-1.2.5-r12", "zlib-1.4-r0", "zstd-libs-1.5.6-r2", "mimalloc2-2.1.7-r0")


def checkout(path, repository, revision):
    if not (path / ".git").exists():
        subprocess.run(["git", "init", str(path)], check=True)
        subprocess.run(["git", "-C", str(path), "remote", "add", "origin", repository], check=True)
        subprocess.run(["git", "-C", str(path), "fetch", "--depth=1", "origin", revision], check=True)
        subprocess.run(["git", "-C", str(path), "checkout", "--detach", "FETCH_HEAD"], check=True)
    actual = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
    if actual != revision:
        raise ValueError(f"unexpected source revision in {path}")


def prepare(root):
    source = root / "source"
    checkout(source, "https://github.com/AppImage/type2-runtime.git", RUNTIME)
    patch = Path(__file__).with_name("runtime-mount-source.patch").resolve()
    check = subprocess.run(["git", "-C", str(source), "apply", "--unidiff-zero", "--check", str(patch)], capture_output=True)
    if check.returncode == 0:
        subprocess.run(["git", "-C", str(source), "apply", "--unidiff-zero", str(patch)], check=True)
    else:
        subprocess.run(["git", "-C", str(source), "apply", "--unidiff-zero", "--reverse", "--check", str(patch)], check=True)
    shutil.copy2(patch, root / "runtime-mount-source.patch")
    for relative in ("scripts/common/install-dependencies.sh", "scripts/build-runtime.sh"):
        path = source / relative
        data = path.read_text().replace("ninja -v install", "ninja -j4 -v install")
        data = data.replace('make -j"$(nproc)"', "make -j4").replace("make -j$(nproc)", "make -j4")
        path.write_text(data)
    dockerfile = source / "scripts/docker/Dockerfile"
    lines = dockerfile.read_text().splitlines()
    lines[0] = f"FROM {BASE}"
    dockerfile.write_text("\n".join(lines) + "\n")
    (source / "src/runtime/version").write_text(f"https://github.com/AppImage/type2-runtime/commit/{RUNTIME}\n")
    pins = json.loads(Path(__file__).with_name("runtime-sources.json").read_text())
    (root / "sources").mkdir(exist_ok=True)
    for pin in pins:
        destination = root / "sources" / pin["file"]
        if not destination.exists():
            with urllib.request.urlopen(pin["url"]) as response, destination.open("wb") as output:
                shutil.copyfileobj(response, output)
        if hashlib.sha256(destination.read_bytes()).hexdigest() != pin["sha256"]:
            raise ValueError(f"source checksum mismatch: {destination}")
        with tarfile.open(destination) as archive:
            for member in archive:
                if not member.isfile() or not Path(member.name).name.lower().startswith(("license", "copying", "copyright")):
                    continue
                target = root / "notices" / pin["file"] / member.name
                if not target.resolve().is_relative_to((root / "notices").resolve()):
                    raise ValueError("source notice escapes archive")
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as content, target.open("wb") as output:
                    shutil.copyfileobj(content, output)
    shutil.copy2(Path(__file__).with_name("runtime-sources.json"), root / "source-archives.json")
    checkout(root / "aports-checkout", "https://github.com/alpinelinux/aports.git", APORTS)
    for relative in ("main/musl", "main/zlib", "main/zstd", "community/mimalloc2"):
        shutil.copytree(root / "aports-checkout" / relative, root / "aports" / relative, dirs_exist_ok=True)
    (root / "aports-revision.txt").write_text(APORTS + "\n")
    (root / "notices/runtime").mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / "LICENSE", root / "notices/runtime/LICENSE")
    (root / "README.txt").write_text(
        f"AppImage type-2 runtime source at {RUNTIME}.\n"
        "Modified files: Dockerfile pins its base; build scripts cap jobs at four; src/runtime/version records the revision.\n"
        "src/runtime/runtime.c records the canonical image path as the FUSE mount source; runtime-mount-source.patch carries the change.\n"
        "Library archives are pinned in source-archives.json. Alpine recipes and patches are in aports/.\n"
        "The libfuse mount.c patch is in source/patches/libfuse. Notices are in notices/.\n"
        "To rebuild with a modified library, unpack its sources and apply the supplied recipe/patches.\n"
        "Build the Docker image from source/scripts/docker/Dockerfile, then run source/scripts/build-runtime.sh inside it.\n"
        "Use appimagetool --runtime-file out/runtime-<architecture> to repack an extracted AppImage with that runtime.\n")


def archive(root):
    installed = (root / "installed-packages.txt").read_text().splitlines()
    for package in PACKAGES:
        if not any(line.startswith(package + " ") for line in installed):
            raise ValueError(f"runtime package changed; update its matching sources before release: {package}; "
                             f"installed packages: {', '.join(installed)}")
    def include(member):
        parts = Path(member.name).parts
        return None if ".git" in parts or parts[:2] == ("source", "out") else member
    with tarfile.open(root / "runtime-sources.tar.xz", "w:xz", preset=0) as output:
        for name in ("source", "sources", "source-archives.json", "aports", "aports-revision.txt", "notices", "README.txt", "installed-packages.txt", "runtime-mount-source.patch"):
            output.add(root / name, arcname=name, filter=include)


if __name__ == "__main__":
    operation, directory = sys.argv[1:]
    {"prepare": prepare, "archive": archive}[operation](Path(directory).resolve())
