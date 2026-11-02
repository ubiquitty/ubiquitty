#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Require adopted Swift surfaces to seed cursor preferences before presenting.

All surface construction funnels through init(drive:rows:columns:). The guard
pins both the adopting route and the cursor seed in that initializer; runtime
cursor and tmux scenarios exercise the result.
"""

import re
import sys
from pathlib import Path

SOURCE = Path(__file__).resolve().parent.parent / "Source/UbiquittyKit/Swift/TerminalSurface.swift"


def body(source, declaration):
    source = re.sub(r"//[^\n]*", "", source)
    start = source.find(declaration)
    if start < 0:
        return ""
    start = source.find("{", start)
    depth = 1
    end = start + 1
    while end < len(source) and depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start + 1:end - 1] if depth == 0 else ""


def findings(source):
    failures = []
    adopted = body(source, "package static func makeAdopting(terminal: Ubiquitty.Terminal")
    if not re.search(r"return TerminalSurface\(drive: drive, rows: rows, columns: columns\)", adopted):
        failures.append("the adopting route must use the shared surface initializer")
    initializer = body(source, "package init(drive: RuntimeDrive, rows: Int, columns: Int)")
    if not re.search(r"drive\.withTerminal\s*\{[^}]*applyCursorPreferences\(terminal, Ubiquitty\.Preferences\.values\(\)\.pointee\)", initializer):
        failures.append("the shared initializer must seed cursor policy under the model lock")
    return failures


def main():
    source = SOURCE.read_text()
    if "--self-test" in sys.argv:
        assert not findings(source), findings(source)
        assert findings(source.replace("applyCursorPreferences(terminal,", "applySomethingElse(terminal,"))
        assert findings(source.replace("return TerminalSurface(drive: drive, rows: rows, columns: columns)", "return nil"))
        assert findings("")
        print("check-adopted-term-cursor: self-test ok")
        return 0
    failures = findings(source)
    for failure in failures:
        print(failure, file=sys.stderr)
    print(f"check-adopted-term-cursor: {len(failures)} failures")
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
