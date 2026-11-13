#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Run esctest with rectangular screen observations on an explicit page."""

import functools
import importlib
from pathlib import Path
import runpy
import sys


def install_single_page_observer(utility, commands):
    original_observer = utility.GetChecksumOfRect

    @functools.wraps(original_observer)
    def observe_rectangle(rectangle):
        original_command = commands.DECRQCRA

        def request_rectangle(identifier, page, area):
            return original_command(identifier, 1 if page == 0 else page, area)

        # DEC page zero ignores the rectangle and checks all page memory.
        # Change only the observer's request, retaining esctest's reply parser,
        # assertions and direct DECRQCRA test commands.
        # https://vt100.net/docs/vt510-rm/DECRQCRA.html
        commands.DECRQCRA = request_rectangle
        try:
            return original_observer(rectangle)
        finally:
            commands.DECRQCRA = original_command

    utility.GetChecksumOfRect = observe_rectangle


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: esctest-observer.py <esctest.py> [arguments...]")
    suite = Path(sys.argv[1]).resolve()
    sys.argv = [str(suite), *sys.argv[2:]]
    sys.path.insert(0, str(suite.parent))
    install_single_page_observer(importlib.import_module("escutil"), importlib.import_module("esccmd"))
    runpy.run_path(str(suite), run_name="__main__")


if __name__ == "__main__":
    main()
