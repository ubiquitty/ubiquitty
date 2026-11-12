#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Package unsigned CI artifacts and verify them before local publication."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import subprocess
import sys
import zipfile

import release_ci

SCHEMA = "ubiquitty.release-preparation.v1"
LOCAL_ASSETS = {"SHA256SUMS-appimage", "SHA256SUMS-host", "SHA256SUMS-ubq", "ubq-NOTICE",
                "ubiquitty-host-macos-arm64"}


def unsigned_archive(named_version):
    return f"Ubiquitty-{named_version}-macos-unsigned.zip"


def expected_assets(named_version):
    return (release_ci.expected_assets(named_version) - LOCAL_ASSETS
            - {f"Ubiquitty-{named_version}.zip"}) | {unsigned_archive(named_version)}


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def check_files(directory, named_version):
    missing = [name for name in sorted(expected_assets(named_version))
               if not (directory / name).is_file() or (directory / name).is_symlink()
               or (directory / name).stat().st_size == 0]
    if missing:
        raise ValueError("missing or empty prepared assets: " + ", ".join(missing))


def collect(inputs, directory, tag):
    named_version = release_ci.version(tag)
    directory.mkdir(parents=True, exist_ok=True)
    wanted = expected_assets(named_version)
    for source in sorted(inputs.rglob("*")):
        if source.name not in wanted or not source.is_file() or source.is_symlink():
            continue
        target = directory / source.name
        if target.exists() and digest(target) != digest(source):
            raise ValueError("conflicting prepared artifacts named " + source.name)
        shutil.copy2(source, target)
    check_files(directory, named_version)
    composition = json.loads((directory / "composition.json").read_text())
    if composition.get("tag") != tag or composition.get("version") != named_version:
        raise ValueError("source composition disagrees with the prepared release")
    manifest = {"schema": SCHEMA, "tag": tag, "version": named_version,
                "repositories": composition["repositories"],
                "run": {"repository": os.environ.get("GITHUB_REPOSITORY", "ubiquitty/ubiquitty"),
                        "id": os.environ.get("GITHUB_RUN_ID", ""),
                        "head": os.environ.get("GITHUB_SHA", "")},
                "assets": {name: digest(directory / name) for name in sorted(wanted)}}
    (directory / "preparation.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def verify(directory, tag, repositories=None):
    named_version = release_ci.version(tag)
    manifest = json.loads((directory / "preparation.json").read_text())
    if manifest.get("schema") != SCHEMA or manifest.get("tag") != tag or manifest.get("version") != named_version:
        raise ValueError("preparation manifest does not name this release")
    if manifest.get("run", {}).get("repository") != "ubiquitty/ubiquitty":
        raise ValueError("preparation came from another repository")
    if repositories is not None and manifest.get("repositories") != repositories:
        raise ValueError("prepared artifacts do not match the tagged Core, Kit and app")
    if set(manifest.get("assets", {})) != expected_assets(named_version):
        raise ValueError("preparation manifest does not cover the complete asset set")
    check_files(directory, named_version)
    for name, expected in manifest["assets"].items():
        if digest(directory / name) != expected:
            raise ValueError("prepared artifact checksum differs: " + name)
    composition = json.loads((directory / "composition.json").read_text())
    if composition != {"tag": tag, "version": named_version, "repositories": manifest["repositories"]}:
        raise ValueError("prepared source composition differs from its manifest")
    return manifest


def package_macos(app, output, tag):
    named_version = release_ci.version(tag)
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != "org.ubiquitty.Ubiquitty" or info.get("CFBundleShortVersionString") != named_version:
        raise ValueError("prepared Mac app has the wrong release identity or version")
    for relative in ["Contents/MacOS/Ubiquitty", "Contents/Helpers/ubiquitty-host", "Contents/Helpers/ubq",
                     "Contents/Resources/ubiquitty-host-linux-x86_64", "Contents/Resources/ubiquitty-host-linux-arm64"]:
        path = app / relative
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError("prepared Mac app is incomplete: " + relative)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    signature = subprocess.run(["codesign", "-dvv", str(app)], capture_output=True, text=True, check=True)
    if "Signature=adhoc" not in signature.stderr:
        raise ValueError("CI must prepare an ad-hoc Mac bundle without a signing identity")
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(output / unsigned_archive(named_version))], check=True)


def inspect_macos_archive(archive):
    with zipfile.ZipFile(archive) as bundle:
        members = bundle.infolist()
        links = {PurePosixPath(member.filename) for member in members
                 if (member.external_attr >> 16) & 0o170000 == 0o120000}
        seen = set()
        for member in members:
            path = PurePosixPath(member.filename)
            if path in seen or any(parent in links for parent in path.parents):
                raise ValueError("Mac archive has duplicate members or writes through a symbolic link")
            seen.add(path)
            if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] not in {"Ubiquitty.app", "__MACOSX"}:
                raise ValueError("Mac archive has an unsafe member")
            if (member.external_attr >> 16) & 0o170000 == 0o120000:
                target = PurePosixPath(bundle.read(member).decode())
                if target.is_absolute():
                    raise ValueError("Mac archive has an absolute symbolic link")
                resolved = list(path.parent.parts)
                for part in target.parts:
                    if part == "..":
                        if len(resolved) <= 1:
                            raise ValueError("Mac archive has an escaping symbolic link")
                        resolved.pop()
                    elif part != ".":
                        resolved.append(part)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("collect", "verify", "macos"))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--inputs", type=Path)
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "collect":
            if args.inputs is None:
                raise ValueError("collect requires --inputs")
            collect(args.inputs, args.directory, args.tag)
        elif args.command == "verify":
            verify(args.directory, args.tag)
        else:
            if args.app is None:
                raise ValueError("macos requires --app")
            package_macos(args.app, args.directory, args.tag)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"release preparation: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
