#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""library_scripts — how a script of the app reaches the scripts of the libraries it builds on.

The app carries ubiquitty-kit as a submodule under Libraries/, and ubiquitty-core
as the Kit's own submodule, so the Core the app builds is the one its Kit pins.
The machinery its gates share (gate_report, gate_corpus, gate_framework,
ubq_roots, wire_tables) lives in ubiquitty-core's Scripts/. Python puts only a
script's own directory on the import path, so a gate of the app imports this
module first and everything the libraries provide after it:

    import library_scripts  # noqa: F401, E402 — makes the libraries' modules importable
    import gate_report  # noqa: E402

The roots are ubq_roots's: UBQ_CORE_ROOT and UBQ_KIT_ROOT when set, otherwise
Libraries/ubiquitty-kit and Libraries/ubiquitty-kit/Libraries/ubiquitty-core
under the checkout holding this file when Libraries/ubiquitty-kit exists,
otherwise the checkout itself, so that in a checkout holding every repository
the modules are found beside this one. The rule is written out here once,
because ubq_roots is the module this makes importable; Scripts/library-scripts.sh
states the same rule for shell callers.
"""

import os
import sys

APP_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KIT_SUBMODULE = os.path.join("Libraries", "ubiquitty-kit")
CORE_THROUGH_KIT = os.path.join(KIT_SUBMODULE, "Libraries", "ubiquitty-core")


def _root(variable, mounted):
    """A library's root as ubq_roots.py derives it from this file's checkout.

    The Kit submodule is chosen by existing, not by being populated, so a
    checkout that has not initialised it fails on the missing files rather than
    judging its own tree as the library's.
    """
    configured = os.environ.get(variable)
    if configured:
        return os.path.abspath(os.path.expanduser(configured))
    if os.path.lexists(os.path.join(APP_ROOT, KIT_SUBMODULE)):
        return os.path.join(APP_ROOT, mounted)
    return APP_ROOT


CORE_ROOT = _root("UBQ_CORE_ROOT", CORE_THROUGH_KIT)
KIT_ROOT = _root("UBQ_KIT_ROOT", KIT_SUBMODULE)

# The app's own Scripts directory stays first, so a module the app carries is
# never shadowed by a library's of the same name.
for _library in (KIT_ROOT, CORE_ROOT):
    _scripts = os.path.join(_library, "Scripts")
    if _scripts not in sys.path:
        sys.path.insert(1, _scripts)


def _git(root, *arguments):
    """Runs `git -C root`, in the environment of a repository other than the one a hook is committing."""
    import subprocess
    import ubq_roots
    environment = ubq_roots.foreign_git_environment() if root != APP_ROOT else None
    return subprocess.run(["git", "-C", root, *arguments], capture_output=True, text=True,
                          check=False, env=environment).stdout


def checkouts():
    """The distinct checkouts a repository-relative path may live in, the app's first."""
    found = []
    for root in (APP_ROOT, KIT_ROOT, CORE_ROOT):
        if root not in found:
            found.append(root)
    return tuple(found)


def locate(relative):
    """The file a repository-relative path names, in the checkout that holds it.

    - Parameter relative: a path as the monorepo spells it, such as `Source/Core/Pen.h`.
    - Returns: the path in the app's checkout when it is there, else in a library's,
      else the app's (so a missing file is reported where the app expects it).
    """
    for root in checkouts():
        candidate = os.path.join(root, relative)
        if os.path.exists(candidate):
            return candidate
    return os.path.join(APP_ROOT, relative)


def directories(relative):
    """Every checkout's directory for a repository-relative one, those that exist."""
    return tuple(path for path in (os.path.join(root, relative) for root in checkouts())
                 if os.path.isdir(path))


def relative(path):
    """A file's path relative to the checkout that holds it, spelled as the monorepo does."""
    absolute = os.path.abspath(path)
    for root in checkouts():
        if absolute == root or absolute.startswith(root + os.sep):
            return os.path.relpath(absolute, root)
    return os.path.relpath(absolute, APP_ROOT)


def tracked(*prefixes):
    """Every tracked path under the prefixes in any checkout, spelled as the monorepo does.

    - Parameter prefixes: repository-relative paths; every file when none is given.
    - Returns: a sorted list without duplicates.
    """
    found = set()
    for root in checkouts():
        found.update(path for path in _git(root, "ls-files", "-z", "--", *prefixes).split("\0") if path)
    return sorted(found)


def grepFiles(pattern):
    """Every tracked file in any checkout containing a fixed string, spelled as the monorepo does."""
    found = set()
    for root in checkouts():
        found.update(line for line in _git(root, "grep", "-l", "-F", "-e", pattern).splitlines() if line)
    return sorted(found)


def gitGrep(*arguments):
    """`git grep` run in every checkout, the outputs joined; paths are each checkout's own.

    - Parameter arguments: what follows `git grep`, including the pathspec after `--`.
    - Returns: the combined standard output (a checkout with no match adds nothing).
    """
    return "".join(_git(root, "grep", *arguments) for root in checkouts())
