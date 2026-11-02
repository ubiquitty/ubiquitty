#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Every path a core subset list names must exist.

`ubiquitty_core_subset(<out> EXCLUDE|KEEP_ONLY <files...>)` resolves through
CMake's `list(REMOVE_ITEM)`, which is a no-op for a name the list does not
hold. Rename a trimmed file and the trim stops trimming, in silence: the target
links a translation unit it was written to drop.

Only the trims that exist to avoid an external dependency fail loudly, because
the missing object is what reports them — the daemon's `Codec/JSON.cpp` trim
keeps vendored yyjson out of a link that does not compile it. Every other trim
just grows the binary, and nothing says so.

The SSOT already stops the compiled list from drifting. These per-target lists
are the other one, and they name paths rather than deriving them.
"""

import contextlib
import io
import pathlib
import re
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gate_report  # noqa: E402 — the path above is what makes it importable

GATE = "check-core-subset-trims"
SUBSET = re.compile(r'ubiquitty_core_subset\(\s*(\w+)\s+(EXCLUDE|KEEP_ONLY)\b')
SOURCE_SUFFIXES = (".cpp", ".c", ".mm")


def subset_blocks(text):
    """Each subset call's target, mode and source paths, comments dropped.

    The call ends at its first `)` outside a comment. The last path may close
    it on its own line, and the comments between paths hold parentheses, so
    neither a line holding only `)` nor the first `)` in the text marks the end.
    """
    for opening in SUBSET.finditer(text):
        paths = []
        for line in text[opening.end():].split("\n"):
            arguments = line.split("#", 1)[0]
            closing = arguments.find(")")
            paths += [word for word in arguments[:closing if closing >= 0 else None].split()
                      if word.endswith(SOURCE_SUFFIXES)]
            if closing >= 0:
                break
        yield opening.group(1), opening.group(2), paths


def check(root):
    """The gate's verdict on the tree at `root`: 0 when every named path exists."""
    text = (root / "CMakeLists.txt").read_text()

    missing = []
    checked = 0
    for target, mode, paths in subset_blocks(text):
        for named in paths:
            checked += 1
            if not (root / named).exists():
                missing.append((target, mode, named))

    if not checked:
        return gate_report.failed(GATE, "subset list(s) found in CMakeLists.txt; the pattern "
                                        "stopped matching rather than the lists stopping existing",
                                  ["0 lists matched"])

    if missing:
        for target, mode, named in missing:
            gate_report.finding(named, GATE,
                                f"named by {target} ({mode}) but absent, so the trim does nothing")
        print("  Repoint it in the commit that moved the file. CMake's "
              "REMOVE_ITEM cannot report this.", file=sys.stderr)
        return gate_report.failed(GATE, "subset-list entry(s) naming a file that does not exist",
                                  [f"{named} (in {target})" for target, mode, named in missing])

    print("check-core-subset-trims: ok (%d path(s), every one exists)" % checked)
    return 0


def self_test():
    """Runs the rule on trees it must pass, fail and refuse, and reports.

    A clean verdict on the real tree reads the same as a rule that matches
    nothing, and the finding path is the one a clean tree never runs, so it
    is run here: a subset naming a missing file must fail with that file's
    finding, not raise.
    """
    def subset(named, closing="\n)"):
        return (f"ubiquitty_core_subset(UBIQUITTY_TEST_CORE EXCLUDE\n"
                f"    # a comment naming Source/commented.cpp (or a call) is not a path\n"
                f"    Source/{named}{closing}\n")

    cases = (
        ("a named file that exists", subset("present.cpp"), 0, None),
        ("a named file that is absent", subset("absent.cpp"), 1, "Source/absent.cpp"),
        ("a list closed on its last path's line ends there",
         subset("present.cpp", closing=")") + "add_library(other STATIC Source/absent.cpp\n)\n",
         0, None),
        ("an absent path on the closing line is still named",
         subset("absent.cpp", closing=")"), 1, "Source/absent.cpp"),
        ("no subset list at all", "project(empty)\n", 1, "0 lists matched"),
    )
    failures = []
    for name, cmake, expected, mentioned in cases:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "Source").mkdir()
            (root / "Source/present.cpp").write_text("")
            (root / "CMakeLists.txt").write_text(cmake)
            output = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                verdict = check(root)
            if verdict != expected:
                failures.append(f"{name}: verdict {verdict}, want {expected}")
            elif mentioned and mentioned not in output.getvalue():
                failures.append(f"{name}: the report does not name {mentioned}")
    if failures:
        for failure in failures:
            print(f"{GATE} --self-test: {failure}", file=sys.stderr)
        return 1
    print(f"{GATE} --self-test: ok ({len(cases)} cases: a present path passes, an absent one "
          "fails naming it, a list ends at its own closing parenthesis, and no list at all "
          "is refused)")
    return 0


def main(argv):
    if len(argv) > 1 and argv[1] == "--self-test":
        return self_test()
    # Anchored to the script's own location when no root is given: the ctest
    # shell wrapper runs stanzas from its build tree, and a cwd default made
    # this gate's verdict depend on the invoker's directory — a class of
    # defect already removed from four other gates.
    root = pathlib.Path(argv[1]) if len(argv) > 1 else pathlib.Path(__file__).resolve().parent.parent
    return check(root)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
