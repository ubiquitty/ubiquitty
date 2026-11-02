#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Collects distribution notices from the dependency inventory, preserving relative links."""

import argparse
import json
from pathlib import Path
import shutil
import sys


def notice_paths(source):
    """Returns existing notice files without allowing paths outside the source tree."""
    source = Path(source).resolve()
    inventory = json.loads((source / "Docs/third-party-inventory.json").read_text(encoding="utf-8"))
    names = {
        "LICENSE", "LICENSES/Apache-2.0.txt", "NOTICE",
        "TRADEMARKS.md", "third-party-notices.md",
        "Docs/licensing.md", "Docs/third-party-inventory.json",
        "Source/Core/Themes/theme-credits.md",
    }
    for dependency in inventory:
        paths = dependency.get("noticePath", "")
        if dependency.get("noticeRequired") and not paths.strip():
            raise ValueError(f"{dependency['name']} has no noticePath")
        names.update(path.strip() for path in paths.split(";") if path.strip())
    for name in sorted(names):
        path = Path(name)
        if path.is_absolute() or ".." in path.parts or "\n" in name or ";" in name:
            raise ValueError(f"invalid notice path: {name}")
        if not (source / path).resolve().is_relative_to(source) or not (source / path).is_file():
            raise ValueError(f"missing or external notice: {name}")
    return sorted(names)


def copy_notices(source, destination):
    """Copies the complete validated set before a package is archived or installed."""
    source, destination = Path(source).resolve(), Path(destination).resolve()
    names = notice_paths(source)
    for name in names:
        target = destination / name
        if not target.resolve().is_relative_to(destination):
            raise ValueError(f"external notice destination: {name}")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / name, target)


def verify_notices(source, destination):
    """Returns the notices a staged bundle or package lacks or carries altered."""
    source, destination = Path(source).resolve(), Path(destination).resolve()
    problems = []
    for name in notice_paths(source):
        target = destination / name
        if not target.is_file():
            problems.append(f"missing {name}")
        elif target.read_bytes() != (source / name).read_bytes():
            problems.append(f"differs {name}")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--list", action="store_true")
    action.add_argument("--copy", type=Path, metavar="DESTINATION")
    action.add_argument("--verify", type=Path, metavar="DESTINATION")
    arguments = parser.parse_args()
    try:
        if arguments.list:
            print("\n".join(notice_paths(arguments.source)))
        elif arguments.verify:
            problems = verify_notices(arguments.source, arguments.verify)
            for problem in problems:
                print(f"license notices: {arguments.verify}: {problem}", file=sys.stderr)
            return 1 if problems else 0
        else:
            copy_notices(arguments.source, arguments.copy)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"license notices: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
