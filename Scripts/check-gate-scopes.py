#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""check-gate-scopes.py — a scoped gate declares every input it reaches.

`run_scoped` in Scripts/pre-push-gates.sh keys a gate's cached verdict on the
content of its declared paths and nothing else. That key is sound exactly as far
as the declaration is true: a gate that reads a file outside its scope keeps a
passing verdict after that file changes, and the gate reports `cached` while
covering nothing. The failure is silent by construction, which is why it gets a
gate of its own rather than a review convention.

So this walks each scoped gate's command, follows the scripts it invokes, and
reports every repository path they name that the declaration does not cover.

The bound it reports is a lower one. It reads the gate's command and the scripts
that command names, one hop, plus literal driver lists. It sees a spelled path
and misses a computed one — `"$ROOT/$module/x.h"` is invisible here, as is anything a
file it does not open goes on to include. A gate can still go stale through a
path this cannot see; what it removes is the class that is merely unnoticed,
which is the one that has actually happened here. The stronger check is to
deny the reads outright: `sandbox-exec` can run a gate with every repository read
outside its scope refused, and an undeclared input then fails the run instead of
being cached. That costs a full build per gate to exercise, so it belongs in a
periodic audit rather than in the push path, and it is not wired here.
"""

import contextlib
import io
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                      capture_output=True, text=True).stdout.strip()

GATES = os.path.join(ROOT, "Scripts", "pre-push-gates.sh")

# `run_scoped <name> <scope> <command...>`, the name and scope quoted, the scope
# possibly continued across lines with a trailing backslash.
INVOCATION = re.compile(
    r'run_scoped\s+"(?P<name>[^"]+)"\s*\\?\s*\n?\s*"(?P<scope>[^"]+)"\s*\\?\s*\n?\s*(?P<command>[^\n]+)')

# A repository path spelled in a script. The leading directories are the ones
# this tree keeps its inputs in; anything else is not a path a gate can read.
#
# The dot is absent from the guard on purpose. A gate command is written
# `./Scripts/build-host.sh`, and excluding a preceding `.` rejected every one of
# them — the checker then reached no script, found nothing, and reported that
# every scope was complete. A gate that cannot fail is the thing this file exists
# to prevent, so the guard admits the leading `./` and the match starts at the
# directory name.
REPOSITORY_PATH = re.compile(
    r'(?<![\w-])(?:\./)?(?:Scripts|Source|Tests|Tools|Docs|Support|Samples|Resources)/[A-Za-z0-9_./+-]+')


# A comment names a path the script does not read. Every gate script here opens
# with a prose header citing the design notes it implements, so counting those
# put twenty Docs/ entries under the Linux gate — none of which the compile can
# reach. A rule that fires on correct prose is one people learn to ignore.
COMMENT = re.compile(r'(^|\s)#.*$', re.M)


def spelled_paths(text):
    """The repository paths named in a blob of script text, comments excluded.

    - Parameter text: the script's contents.
    - Returns: the set of paths, each relative to the repository root.
    """
    return {match[2:] if match.startswith("./") else match
            for match in REPOSITORY_PATH.findall(COMMENT.sub("", text))}

# A script the gate's command runs, so its own references are the gate's too.
SCRIPT_SUFFIXES = (".sh", ".py", ".cmake")


def referenced_paths(path):
    """The repository paths this file names directly.

    One hop, not a transitive walk. Scripts/run-linux.sh is a container wrapper
    that runs whatever it is handed, so following it reaches every build script
    in the tree and, through their prose headers, most of Docs/ — forty findings
    for a gate that compiles one frontend. Unbounded reach through a wrapper says
    nothing about what the gate read, and a gate whose output has to be filtered
    by hand is one nobody runs.

    A literal script list dispatched through `$ROOT/Scripts/$variable` is also
    followed: the list names the inputs even though the invocation computes
    their paths. Other computed paths remain outside this check.

    - Parameter path: a repository-relative file to read.
    - Returns: the set of repository-relative paths it names.
    """
    absolute = os.path.join(ROOT, path)
    if not os.path.isfile(absolute):
        return set()
    try:
        with open(absolute, "r", errors="replace") as handle:
            source = COMMENT.sub("", handle.read())
            paths = spelled_paths(source)
            # A literal script list executed through $ROOT/Scripts/$variable.
            if re.search(r'\$ROOT/Scripts/\$(?:\{)?[A-Za-z_]', source):
                for body in re.findall(r'\b[A-Za-z_][A-Za-z0-9_]*=\((.*?)\)', source, re.S):
                    for driver in re.findall(r'(?<![\w/.-])([\w-]+\.sh)\b', body):
                        relative = "Scripts/" + driver
                        paths.add(relative)
                        absolute_driver = os.path.join(ROOT, relative)
                        if os.path.isfile(absolute_driver):
                            paths |= spelled_paths(Path(absolute_driver).read_text())
            return paths
    except OSError:
        return set()


def covers(scope, path):
    """Whether a declared scope contains a path.

    - Parameters:
      - scope: the declared pathspecs, already split.
      - path: a repository-relative path.
    - Returns: True when some pathspec is the path or a directory above it.
    """
    for spec in scope:
        if path == spec or path.startswith(spec.rstrip("/") + "/"):
            return True
    return False


def main():
    with open(GATES, "r", errors="replace") as handle:
        source = handle.read()

    invocations = list(INVOCATION.finditer(source))
    if not invocations:
        print("check-gate-scopes: REFUSED — no run_scoped invocation parsed from "
              "Scripts/pre-push-gates.sh. A driver that stopped using scopes and one "
              "this parser stopped reading print the same verdict, so this is not a "
              "pass.", file=sys.stderr)
        return 2

    findings = []
    for match in invocations:
        name = match.group("name")
        scope = match.group("scope").split()
        command = match.group("command")

        entries = [p for p in spelled_paths(command)
                   if p.endswith(SCRIPT_SUFFIXES)]
        invalid = [p for p in scope if not os.path.exists(os.path.join(ROOT, p))]
        if invalid:
            findings.append((name + " (scope paths do not exist)", invalid))
        reached = set()
        for entry in entries:
            reached |= {entry}
            reached |= referenced_paths(entry)

        # Only paths that exist: a spelled string that names nothing is not an input.
        # A FILE, not a directory: a bare `Source/Platform` match is the head of
        # a path the script builds at runtime, and the file it finally opens is
        # the thing this cannot see either way.
        missing = sorted(p for p in reached
                         if os.path.isfile(os.path.join(ROOT, p)) and not covers(scope, p))
        if missing:
            findings.append((name, missing))

    if findings:
        print("check-gate-scopes: a scoped gate reaches inputs its declaration "
              "does not cover:", file=sys.stderr)
        for name, missing in findings:
            print("  %s" % name, file=sys.stderr)
            for path in missing:
                print("      %s" % path, file=sys.stderr)
        print("\n  Add each to that gate's scope in Scripts/pre-push-gates.sh, or the "
              "gate\n  reports `cached` after the file changes and covers nothing.",
              file=sys.stderr)
        return 1

    print("check-gate-scopes: ok (%d scoped gate(s), every reachable input declared; "
          "spelled paths only — a computed path is not visible here)" % len(invocations))
    return 0


def self_test():
    global ROOT, GATES
    old_root, old_gates = ROOT, GATES
    with tempfile.TemporaryDirectory() as directory:
        ROOT = directory
        GATES = os.path.join(directory, "Scripts/pre-push-gates.sh")
        scripts = Path(directory) / "Scripts"
        scripts.mkdir()
        (scripts / "runner.sh").write_text('CHECKS=(check-driver.sh)\n"$ROOT/Scripts/$check"\n')
        (scripts / "check-driver.sh").write_text('cat "$ROOT/Source/Renderer.swift"\n')
        (Path(directory) / "Source").mkdir()
        (Path(directory) / "Source/Renderer.swift").touch()
        try:
            for scope, expected in (("Scripts/runner.sh", 1),
                                    ("Scripts Source Missing", 1),
                                    ("Scripts Source", 0)):
                Path(GATES).write_text(f'run_scoped "fixture" "{scope}" ./Scripts/runner.sh\n')
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    actual = main()
                if actual != expected:
                    print(f"check-gate-scopes: self-test failed for {scope}", file=sys.stderr)
                    return 1
        finally:
            ROOT, GATES = old_root, old_gates
    print("check-gate-scopes: self-test ok (driver lists and nonexistent scope paths)")
    return 0


if __name__ == "__main__":
    sys.exit(self_test() if "--self-test" in sys.argv else main())
