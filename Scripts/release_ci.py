#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Validate a release cut, its immutable toolchains, and the complete asset set."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request


TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
CORE_PATH = Path("Libraries/ubiquitty-kit/Libraries/ubiquitty-core")
KIT_PATH = Path("Libraries/ubiquitty-kit")
SECRETS = (
    "RELEASE_TOOLS_TOKEN", "SPARKLE_ED_PRIVATE_KEY", "MACOS_CERT_P12_BASE64",
    "MACOS_CERT_PASSWORD", "MACOS_DEVELOPER_ID", "MACOS_PROVISIONING_PROFILE_BASE64",
    "CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID",
    "PGO_LINUX_X86_64_IMAGE", "PGO_LINUX_ARM64_IMAGE",
)
NOTARY_CREDENTIALS = (
    ("NOTARY_KEY_P8", "NOTARY_KEY_ID", "NOTARY_ISSUER_ID"),
    ("NOTARY_APPLE_ID", "NOTARY_TEAM_ID", "NOTARY_APP_PASSWORD"),
)


def missing_credentials(environment):
    missing = [name for name in SECRETS if not environment.get(name)]
    if not any(all(environment.get(name) for name in group) for group in NOTARY_CREDENTIALS):
        missing.append("one complete notarization credential set: "
                       + " or ".join("/".join(group) for group in NOTARY_CREDENTIALS))
    return missing


def git(root, *arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments], text=True).strip()


def version(tag):
    if not TAG.fullmatch(tag):
        raise ValueError("release tag must be vMAJOR.MINOR.PATCH")
    return tag[1:]


def required_checks(payload):
    """An older successful check cannot hide a newer failure or pending check."""
    latest = {}
    for check in payload["check_runs"]:
        if check["name"] not in latest or check["id"] > latest[check["name"]]["id"]:
            latest[check["name"]] = check
    for name in ("CI", "gitleaks"):
        check = latest.get(name)
        if not check or check.get("status") != "completed" or check.get("conclusion") != "success":
            raise ValueError(f"required check {name} has not succeeded on this exact revision")


def validate(root, tag):
    named_version = version(tag)
    composition = {}
    for repository, directory in (("ubiquitty", root), ("kit", root / KIT_PATH), ("core", root / CORE_PATH)):
        sha = git(directory, "rev-parse", "HEAD")
        if git(directory, "cat-file", "-t", f"refs/tags/{tag}") != "tag":
            raise ValueError(f"{repository}: {tag} must be annotated")
        if git(directory, "rev-parse", f"refs/tags/{tag}^{{commit}}") != sha:
            raise ValueError(f"{repository}: {tag} does not name the checked out pin")
        if (directory / "VERSION").read_text().strip() != named_version:
            raise ValueError(f"{repository}: VERSION disagrees with {tag}")
        if git(directory, "status", "--porcelain"):
            raise ValueError(f"{repository}: release source is dirty")
        subprocess.run(["git", "-C", str(directory), "merge-base", "--is-ancestor", sha, "origin/main"], check=True)
        url = f"https://api.github.com/repos/ubiquitty/{repository}/commits/{sha}/check-runs?filter=latest&per_page=100"
        headers = {"Accept": "application/vnd.github+json"}
        token = os.environ.get("GH_TOKEN")
        if token:
            headers["Authorization"] = f"Bearer {token}"
        request = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(request, timeout=30) as response:
            required_checks(json.load(response))
        composition[repository] = sha
    if git(root, "rev-parse", f"HEAD:{KIT_PATH}") != composition["kit"]:
        raise ValueError("App does not pin the tagged Kit")
    if git(root / KIT_PATH, "rev-parse", "HEAD:Libraries/ubiquitty-core") != composition["core"]:
        raise ValueError("Kit does not pin the tagged Core")
    print(json.dumps({"version": named_version, "tag": tag, "repositories": composition}, indent=2))


def load_image(root, architecture, reference):
    if not re.fullmatch(r"[a-z0-9./_-]+@sha256:[0-9a-f]{64}", reference):
        raise ValueError("PGO image must be an immutable registry reference ending in @sha256:<digest>")
    stem = "linux-x86_64-core" if architecture == "x86_64" else "linux-aarch64-core"
    stamp = json.loads((root / CORE_PATH / "Support/pgo" / f"{stem}.trained-toolchain").read_text())
    subprocess.run(["docker", "pull", reference], check=True)
    actual = subprocess.check_output(["docker", "image", "inspect", "--format", "{{.Id}}", reference], text=True).strip()
    if actual != stamp["image"]:
        raise ValueError(f"PGO image configuration is {actual}; the profile requires {stamp['image']}")
    recipe = subprocess.check_output([str(root / CORE_PATH / "Scripts/ci-linux-image.sh"), "--source-root", str(root), "--recipe-digest"], text=True).strip()
    if recipe != stamp["recipe"]:
        raise ValueError("release recipe differs from the profile's immutable training recipe")
    subprocess.run(["docker", "tag", reference, f"ubq-ci-linux:{recipe}"], check=True)


def expected_assets(named_version):
    names = {f"Ubiquitty-{named_version}.zip", "SHA256SUMS-appimage", "SHA256SUMS-host",
             "SHA256SUMS-ubq", "ubq-NOTICE", "composition.json"}
    for architecture in ("x86_64", "aarch64"):
        names.update((f"Ubiquitty-{named_version}-{architecture}.AppImage",
                      f"Ubiquitty-{named_version}-{architecture}.AppImage.zsync",
                      f"Ubiquitty-{named_version}-{architecture}-support-sources.tar.xz"))
    names.update(f"ubiquitty-host-{platform}" for platform in ("linux-x86_64", "linux-arm64", "macos-arm64"))
    names.update(f"ubq-linux-{architecture}" for architecture in ("x86_64", "arm64"))
    names.update(f"Ubiquitty-{named_version}-{package}.tar.xz"
                 for package in ("source", "web", "emacs", "neovim", "ios-iphoneos-development", "ios-iphonesimulator-development"))
    return names


def verify_assets(directory, named_version):
    missing = [name for name in sorted(expected_assets(named_version))
               if not (directory / name).is_file() or (directory / name).is_symlink()
               or (directory / name).stat().st_size == 0]
    if missing:
        raise ValueError("missing or empty release assets: " + ", ".join(missing))
    lines = []
    for path in sorted(directory.iterdir()):
        if path.is_file() and path.name != "SHA256SUMS":
            lines.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n")
    (directory / "SHA256SUMS").write_text("".join(lines))
    print(f"Verified {len(expected_assets(named_version))} required assets")


def assemble(directory, named_version):
    temporary = Path(os.environ["RUNNER_TEMP"])
    directory.mkdir(parents=True, exist_ok=True)
    wanted = expected_assets(named_version)
    for group in ("macos-release", "linux-release", "ubq-release", "client-release"):
        for path in (temporary / group).rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            name = path.name
            if group == "macos-release" and name == "SHA256SUMS":
                name = "SHA256SUMS-host"
            elif group == "ubq-release" and name == "NOTICE":
                name = "ubq-NOTICE"
            elif name == "SHA256SUMS":
                name = "SHA256SUMS-appimage" if group == "linux-release" else "SHA256SUMS-ubq"
            if name not in wanted:
                continue
            target = directory / name
            if target.exists() and target.read_bytes() != path.read_bytes():
                raise ValueError(f"conflicting release artifacts named {name}")
            shutil.copy2(path, target)


def source_packages(root, output, named_version):
    output.mkdir(parents=True, exist_ok=True)
    prefix = f"Ubiquitty-{named_version}/"
    with tarfile.open(output / f"Ubiquitty-{named_version}-source.tar.xz", "w:xz") as archive:
        for relative in (Path("."), KIT_PATH, CORE_PATH):
            data = subprocess.check_output(["git", "-C", str(root / relative), "archive", "HEAD"])
            with tarfile.open(fileobj=io.BytesIO(data)) as tree:
                for member in tree:
                    member.name = prefix + (relative.as_posix() + "/" if relative != Path(".") else "") + member.name
                    stream = tree.extractfile(member) if member.isfile() else None
                    archive.addfile(member, stream)
    for package, platform in (("emacs", "Emacs"), ("neovim", "Neovim")):
        with tarfile.open(output / f"Ubiquitty-{named_version}-{package}.tar.xz", "w:xz") as archive:
            for source in (root / "Source/Platform" / platform, root / "LICENSE", root / "NOTICE"):
                archive.add(source, arcname=source.relative_to(root).as_posix())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("validate", "credentials", "image", "assemble", "verify", "sources", "web", "ios"))
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--tag", default=os.environ.get("PRODUCT_TAG", ""))
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--architecture", choices=("x86_64", "aarch64"))
    parser.add_argument("--reference", default="")
    parser.add_argument("--sdk", choices=("iphoneos", "iphonesimulator"))
    args = parser.parse_args()
    try:
        if args.command == "credentials":
            missing = missing_credentials(os.environ)
            if missing:
                raise ValueError("configure release secrets/variables: " + ", ".join(missing))
        elif args.command == "validate":
            validate(args.root, args.tag)
        elif args.command == "image":
            if not args.architecture:
                raise ValueError("image requires --architecture")
            load_image(args.root, args.architecture, args.reference)
        else:
            named_version = version(args.tag)
            if args.directory is None:
                raise ValueError("packaging requires --directory")
            if args.command == "verify":
                verify_assets(args.directory, named_version)
            elif args.command == "assemble":
                assemble(args.directory, named_version)
            elif args.command == "sources":
                source_packages(args.root, args.directory, named_version)
            else:
                build = Path(os.environ["UBQ_BUILD_ROOT"])
                stage = build / ("web-dist" if args.command == "web" else f"ios-{args.sdk}")
                if args.command == "web":
                    required = [stage / name for name in ("ubiquitty.wasm", "ubiquitty.js", "index.html")]
                else:
                    required = [stage / "Ubiquitty.app" / name for name in ("Info.plist", "Ubiquitty")]
                    # Ship only the app, rather than the CMake tree, object
                    # files and downloaded dependencies beside it.
                    stage = stage / "Ubiquitty.app"
                if any(not path.is_file() or path.stat().st_size == 0 for path in required):
                    raise ValueError(f"build did not produce the complete {args.command} package")
                args.directory.mkdir(parents=True, exist_ok=True)
                package = "web" if args.command == "web" else f"ios-{args.sdk}-development"
                with tarfile.open(args.directory / f"Ubiquitty-{named_version}-{package}.tar.xz", "w:xz") as archive:
                    archive.add(stage, arcname="Ubiquitty.app" if args.command == "ios"
                                else f"Ubiquitty-{named_version}-{package}")
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"release: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
