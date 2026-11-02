#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""gen-wire-tables.py — write the editors' wire numbers from the C++ headers.

The Emacs and Neovim clients cannot include a header, so the numbers they share
with the host are written out for them: one Emacs Lisp file and one Lua file,
both checked in. `Scripts/wire_tables.py` says what they hold and reads it from
the headers; this script writes the files, and `Scripts/check-wire-tables.py`
fails when a checked-in file is not what the headers produce now.

Run it after changing a kind, a tag, a capability bit, a reason, a virtual key,
a modifier bit or any constant `wire_tables.SCALARS` lists.

    python3 Scripts/gen-wire-tables.py            # write both files
    python3 Scripts/gen-wire-tables.py --print    # print them instead
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wire_tables  # noqa: E402 — the path above is what makes it importable


def main():
    arguments = sys.argv[1:]
    if any(argument not in ("--print",) for argument in arguments):
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        print("usage: gen-wire-tables.py [--print]", file=sys.stderr)
        return 2
    texts = wire_tables.sources()
    try:
        outputs = [(path, writer(texts)) for path, writer in wire_tables.OUTPUTS]
    except wire_tables.Unreadable as unread:
        print("gen-wire-tables: FAILED — could not read %s; nothing was written" % unread, file=sys.stderr)
        return 1
    for path, text in outputs:
        if "--print" in arguments:
            sys.stdout.write(text)
            continue
        target = os.path.join(wire_tables.REPO, path)
        current = wire_tables.read(path)
        if current == text:
            print("gen-wire-tables: %s is current" % path)
            continue
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(text)
        print("gen-wire-tables: wrote %s" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
