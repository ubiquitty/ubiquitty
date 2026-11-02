#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Name the build a change needs when no portable build compiles its consumer.

A Core type can have its layout pinned outside Core. A host build does not
compile that consumer, so it cannot validate the frontend's layout contract.
The owning frontend must be built too.

Three kinds of consumer pin a Core header, and each is read from the tree
rather than from a list of types:

    a C++ `static_assert` in a frontend naming a Core type
    a Swift `MemoryLayout<Ubiquitty.<Namespace>.<Type>>`, which strides a GPU
      buffer by the imported layout
    a Metal shader, which mirrors a Core struct under the same name and
      compiles every Core header it includes

Each pinned type is resolved to the header declaring it, and a change touching
a pinned header prints the build that compiles the consumer. The shader is the
case a size check cannot see: a field whose bytes keep their place but change
meaning still breaks the frame, and only the frontend build compiles the
shader that reads it. What it cannot do is run that build — a Metal toolchain is not
available everywhere and a gate that fails for the machine it is on is a gate
people switch off. It says which arm is missing and lets the person decide.

Advisory by design, and it says so in the same breath as the finding, because an
advisory that reads like a failure is one people learn to skip.

    python3 Scripts/check-build-arm.py --since origin/main
    python3 Scripts/check-build-arm.py --staged

Stdlib only.
"""

import collections
import glob
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))

# Which build compiles a frontend file. A directory is the right key because it
# is what CMake targets select on, and a file that moves between them changes
# which build owns it — which is the fact this check is about.
ARMS = (
    (os.path.join("Source", "Platform", "macOS"), "Scripts/build-macos.sh",
     os.path.join("build", "macos")),
    # The Swift renderer and the Metal shader are compiled by the macOS build
    # alone; iOS links the same kits through a project no script here builds.
    (os.path.join("Source", "UbiquittyRenderKit"), "Scripts/build-macos.sh",
     os.path.join("build", "macos")),
    (os.path.join("Source", "UbiquittyKit"), "Scripts/build-macos.sh",
     os.path.join("build", "macos")),
    (os.path.join("Source", "Platform", "Linux"), "Scripts/run-linux.sh",
     os.path.join("build", "linux")),
    (os.path.join("Source", "Platform", "Web"), "Scripts/check-web-gpu-parity.sh",
     os.path.join("build", "web")),
    # Wscons is configurable only on OpenBSD/NetBSD — CMakeLists hard-errors
    # anywhere else — so no arm in this repo compiles it. build-host.sh
    # compiles POSIX and Host out of Source/Platform and nothing else, which
    # makes its green an answer to a different question. While Wscons holds no
    # static_assert this entry fires for nobody; it is spelled truthfully so
    # that the first one is checked.
    # Compiled by a script rather than a configured build: -fsyntax-only against
    # a stub for the one header no host has. It writes no compile database, so
    # the database rule below would clear its entry by finding nothing — which is
    # how this entry stayed spelled "no arm compiles it" after an arm existed.
    (os.path.join("Source", "Platform", "Wscons"),
     "Scripts/check-wscons-compiles.sh",
     "Scripts/check-wscons-compiles.sh"),
)

# Namespaces whose types are Core's. A frontend asserting on one of these is
# pinning a contract it does not own. The list is read from the Source/Core
# folder names rather than written down: a hardcoded set of eleven let a
# static_assert on a Core type in an unlisted namespace — Attributes, Selection,
# Preferences — match nothing and pass unseen, the drift this check exists to catch
# turned on the check itself. The Ubiquitty:: prefix is required, not optional:
# several of these names (Preferences, Cursor, Title, Image) are also used bare in the
# frontends for their own types, and a bare match would flag a frontend pinning
# its own struct as if it pinned Core's. Every Core-type assert in the tree is
# fully qualified today, so requiring the prefix drops no coverage.
def coreNamespaces():
    """The Core namespace names, from the Source/Core directory (folder=namespace).

    - Returns: the sorted immediate subdirectory names of Source/Core.
    - Refuses (exit 2) when the directory is gone, since a namespace set of zero
      would make CORE_TYPE match nothing and the gate pass over every assert.
    """
    core = os.path.join(REPO, "Source", "Core")
    try:
        names = sorted(entry for entry in os.listdir(core)
                       if os.path.isdir(os.path.join(core, entry)))
    except OSError:
        names = []
    if not names:
        sys.exit("check-build-arm: REFUSED — no namespace folder under Source/Core; "
                 "the tree moved and CORE_TYPE would match nothing.")
    return names


CORE_TYPE = re.compile(
    r'\bUbiquitty::(?:' + '|'.join(coreNamespaces()) + r')::([A-Z][A-Za-z0-9]*)')

ASSERTION = re.compile(r'static_assert\((.*?)\);', re.S)

FRONTEND_SUFFIXES = (".mm", ".m", ".cpp", ".cc", ".h", ".hpp")

# The Swift spelling of a Core type, and the layout query that pins it.
SWIFT_CORE_TYPE = re.compile(
    r'\bUbiquitty\.(?:' + '|'.join(coreNamespaces()) + r')\.([A-Z][A-Za-z0-9]*)')
SWIFT_LAYOUT = re.compile(r'MemoryLayout<([^>]*)>')

# A struct the shader declares, and a header it includes by a quoted path.
SHADER_STRUCT = re.compile(r'^\s*struct\s+([A-Z][A-Za-z0-9]*)\s*\{', re.M)
SHADER_INCLUDE = re.compile(r'^\s*#\s*include\s*"([^"]+)"', re.M)

# Every directory a frontend arm compiles, which is where its consumers live.
FRONTEND_DIRECTORIES = tuple(prefix for prefix, _, _ in ARMS)


def tracked(prefix):
    listing = subprocess.run(["git", "-C", REPO, "ls-files", prefix],
                             capture_output=True, text=True)
    return [path for path in listing.stdout.split("\n") if path]


def databaseFor(build):
    """The compile database for an arm's build directory, wherever it landed.

    - Parameter build: The directory named in ``ARMS``.
    - Returns: An existing `compile_commands.json` path, or None.

    An arm that builds through a container writes under a different root on the
    host: `Scripts/run-linux.sh` bind-mounts its build directory at `/src/build`,
    so the tree the table calls `build/linux` is `build/linux-container/linux`
    here. The table's name is right on a Linux host and wrong on every macOS
    machine, which is most of them, and the symptom was one advisory line per push
    saying the Linux claim "went unread" — permanently, since no path on this
    host was ever going to be the one it looked for.

    The container's database holds host-absolute paths, so it needs no
    translation once found.
    """
    direct = os.path.join(REPO, build, "compile_commands.json")
    if os.path.exists(direct):
        return direct
    name = os.path.basename(build)
    containerised = os.path.join(REPO, os.path.dirname(build),
                                 name + "-container", name, "compile_commands.json")
    if os.path.exists(containerised):
        return containerised
    return None


def compiledDirectories(database):
    """Repo-relative directory prefixes the database holds a translation unit for.

    - Parameter database: Path to a `compile_commands.json`.
    - Returns: The set of `Source/Platform/<name>` prefixes it compiles, empty
      when the file is missing or unreadable.
    """
    try:
        with open(database, encoding="utf-8") as handle:
            entries = json.load(handle)
    except (OSError, ValueError):
        return set()
    found = set()
    for entry in entries:
        path = entry.get("file", "")
        for prefix, _, _ in ARMS:
            if prefix in path:
                found.add(prefix)
    return found


def mappingProblems():
    """Where an arm's claim disagrees with what the build actually compiles.

    The table says which build compiles a directory, and that is a statement
    about a compile database rather than a convention — so it can be read back.
    @ubiquitty-layers found Source/Platform/Wscons mapped to build-host.sh,
    which compiles no Wscons file at all: the entry sent a reader to a build
    whose green answers a different question, and nothing contradicted it
    because the directory declares no assertion for the entry to fire on.

    A claim of "no arm compiles this" is the one worth checking hardest, since
    it is cleared by every database being silent and a database that is merely
    absent is silent too.

    - Returns: `(problems, unchecked)` — contradictions found, and the arms
      whose database is not configured here and so decided nothing.
    """
    problems, unchecked = [], []
    databases = sorted(glob.glob(os.path.join(REPO, "build", "*", "compile_commands.json")))
    compiled = {database: compiledDirectories(database) for database in databases}
    for prefix, script, build in ARMS:
        if build is not None and build.endswith(".sh"):
            # A script arm compiles without configuring, so there is no database
            # to read back. What is decidable is that the script exists, that it
            # names the directory it claims, and that something invokes it — an
            # arm nothing runs is the same as no arm, spelled differently.
            path = os.path.join(REPO, build)
            if not os.path.exists(path):
                problems.append("%s names %s, which does not exist" % (prefix, build))
                continue
            with open(path, encoding="utf-8", errors="replace") as handle:
                body = handle.read()
            if prefix.replace(os.sep, "/") not in body:
                problems.append("%s names %s, and that script does not mention the "
                                "directory" % (prefix, build))
            # The working tree, not `git grep`. git grep reads the index, so an
            # invocation deleted but not yet staged still answers as present —
            # the gate would clear a tree that no longer runs the arm.
            name = os.path.basename(build)
            invoked = False
            # This file is excluded as well as the arm script. The table above
            # names it, so scanning Scripts/ without that exclusion finds the
            # gate's own claim and reads it as the invocation the claim is about.
            for candidate in sorted(glob.glob(os.path.join(REPO, "Scripts", "*"))):
                if os.path.abspath(candidate) in (os.path.abspath(path), __file__,
                                                  os.path.abspath(__file__)):
                    continue
                try:
                    with open(candidate, encoding="utf-8", errors="replace") as reader:
                        if name in reader.read():
                            invoked = True
                            break
                except (OSError, IsADirectoryError):
                    continue
            if not invoked:
                problems.append("%s names %s, and no script invokes it — an arm "
                                "nobody runs covers nothing" % (prefix, build))
            continue
        if build is None:
            for database, directories in compiled.items():
                if prefix in directories:
                    problems.append(
                        "%s is spelled as compiled by no arm here, and %s compiles it"
                        % (prefix, os.path.relpath(database, REPO)))
            if not compiled:
                unchecked.append("%s: no compile database here, so 'no arm compiles it' "
                                 "was not contradicted rather than confirmed" % prefix)
            continue
        database = databaseFor(build)
        if database is None:
            unchecked.append("%s: %s is not configured here, so its claim on %s "
                             "went unread" % (prefix, build, script))
            continue
        if prefix not in compiledDirectories(database):
            problems.append(
                "%s names %s, and %s compiles no file under it"
                % (prefix, script, build))
    return problems, unchecked


def armFor(path):
    for prefix, script, _ in ARMS:
        if path.startswith(prefix + os.sep):
            return script
    return None


def frontendSources():
    """(path, text) for every tracked file under a frontend directory."""
    for directory in FRONTEND_DIRECTORIES:
        for path in tracked(directory):
            try:
                with open(os.path.join(REPO, path), encoding="utf-8",
                          errors="replace") as handle:
                    yield path, handle.read()
            except OSError:
                continue


def assertedTypes():
    """{type name: {frontend file}} for every Core type a frontend pins.

    The C++ assertions and the Swift layout queries name Core types outright, so
    a name they carry that no Core header declares is reported by the caller.
    A shader's struct is a pin only when Core declares the same name: the
    shader's own vertex outputs are not Core types.
    """
    found = collections.defaultdict(set)
    shaderStructs = collections.defaultdict(set)
    for path, text in frontendSources():
        if path.endswith(FRONTEND_SUFFIXES):
            for match in ASSERTION.finditer(text):
                for name in CORE_TYPE.findall(match.group(1)):
                    found[name].add(path)
        elif path.endswith(".swift"):
            for match in SWIFT_LAYOUT.finditer(text):
                for name in SWIFT_CORE_TYPE.findall(match.group(1)):
                    found[name].add(path)
        elif path.endswith(".metal"):
            for name in SHADER_STRUCT.findall(text):
                shaderStructs[name].add(path)
    for name in declaringHeaders(set(shaderStructs)):
        found[name] |= shaderStructs[name]
    return found


def shaderHeaders():
    """{Core header: {shader}} for every header a frontend shader includes.

    Followed transitively, because a header the included one includes is
    compiled into the shader as well.
    """
    found = collections.defaultdict(set)
    for shader, text in frontendSources():
        if not shader.endswith(".metal"):
            continue
        pending = [(shader, text)]
        seen = set()
        while pending:
            source, body = pending.pop()
            for include in SHADER_INCLUDE.findall(body):
                header = os.path.normpath(os.path.join(os.path.dirname(source), include))
                if header in seen:
                    continue
                seen.add(header)
                found[header].add(shader)
                try:
                    with open(os.path.join(REPO, header), encoding="utf-8",
                              errors="replace") as handle:
                        pending.append((header, handle.read()))
                except OSError:
                    continue
    return found


def advise(changed, asserted, declared, included):
    """{build script: {reason}} for the builds a change to `changed` needs.

    - Parameters:
      - changed: the repository paths the change touches.
      - asserted: assertedTypes().
      - declared: declaringHeaders() over the asserted names.
      - included: shaderHeaders().
    """
    touched = set(changed)
    needed = collections.defaultdict(set)
    for name, headers in declared.items():
        if not (headers & touched):
            continue
        for path in asserted[name]:
            arm = armFor(path)
            if arm:
                needed[arm].add("%s (pinned in %s)" % (name, path))
    for header in sorted(touched & set(included)):
        for shader in included[header]:
            arm = armFor(shader)
            if arm:
                needed[arm].add("%s (compiled into %s)" % (header, shader))
    return needed


def selfTest():
    """Proves each kind of pin reaches the advice, read from this tree.

    - Returns: 0 when every arm behaves as stated, 1 otherwise.
    """
    failures = []
    asserted = assertedTypes()
    declared = declaringHeaders(set(asserted))
    included = shaderHeaders()
    macOS = "Scripts/build-macos.sh"
    cases = (
        ("a stride the Swift renderer and the shader read",
         ["Source/Core/Rendering/CellInstance.h"], macOS),
        ("a Core header the Metal shader includes",
         ["Source/Core/Tek/BeamRaster.h"], macOS),
    )
    for label, changed, arm in cases:
        needed = advise(changed, asserted, declared, included)
        if arm not in needed:
            failures.append("%s (%s) advised [%s], not %s"
                            % (label, " ".join(changed), ", ".join(sorted(needed)) or "-", arm))
    if advise(["Docs/note.md"], asserted, declared, included):
        failures.append("a change to no pinned header was advised a build")
    # Each kind on its own: the Swift layout query, the shader's mirrored
    # struct, and the shader's include. A scan that stopped reading one kind
    # would still pass the CellInstance case through another.
    pinnedBy = asserted.get("TekLineInstance", set())
    if not any(path.endswith(".swift") for path in pinnedBy):
        failures.append("no Swift MemoryLayout pin of TekLineInstance was read")
    if not any(path.endswith(".metal") for path in pinnedBy):
        failures.append("the shader's mirror of TekLineInstance was not read")
    if "VertexOut" in asserted:
        failures.append("the shader's own VertexOut was read as a Core type")
    if "Source/Core/Tek/BeamRaster.h" not in included:
        failures.append("the shader's include of BeamRaster.h was not followed")
    for failure in failures:
        print("check-build-arm --self-test: " + failure, file=sys.stderr)
    if failures:
        return 1
    print("check-build-arm --self-test: ok (a pinned stride and a shader include each "
          "advise %s, an unpinned change advises nothing, and each kind of pin is read)"
          % macOS)
    return 0


def declaringHeaders(names):
    """{type name: {header}} — where Core declares each pinned type."""
    declared = collections.defaultdict(set)
    # An ATTRIBUTE MACRO may sit between the keyword and the name:
    # `struct UBIQUITTY_ESCAPABLE CellInstance {`. Without allowing for it, the
    # four instance payload types resolve to no header at all, and this reports
    # that a change to CellInstance needs no build arm — for the types whose
    # stride the shaders pin (`sizeof(CellInstance) == 64, "must match the
    # shader"`). The resolver said so itself on every push: "the declaration is
    # spelled in a form this does not read".
    #
    # Bounded to one all-caps token rather than `.*`, so it reaches an attribute
    # and not the next declaration on a line that happens to name the type.
    patterns = {name: re.compile(r'\b(?:struct|class|enum class)\s+(?:[A-Z][A-Z0-9_]*\s+)?%s\b' % name)
                for name in names}
    for path in tracked(os.path.join("Source", "Core")):
        if not path.endswith((".h", ".hpp")):
            continue
        try:
            with open(os.path.join(REPO, path), encoding="utf-8",
                      errors="replace") as handle:
                text = handle.read()
        except OSError:
            continue
        for name, pattern in patterns.items():
            if pattern.search(text):
                declared[name].add(path)
    return declared


def changedFiles(argv):
    if "--staged" in argv:
        command = ["git", "-C", REPO, "diff", "--cached", "--name-only"]
    else:
        base = "origin/main"
        if "--since" in argv:
            index = argv.index("--since")
            if index + 1 < len(argv):
                base = argv[index + 1]
        merge = subprocess.run(["git", "-C", REPO, "merge-base", "HEAD", base],
                               capture_output=True, text=True)
        if merge.returncode != 0:
            return None
        command = ["git", "-C", REPO, "diff", "--name-only",
                   merge.stdout.strip(), "HEAD"]
    listing = subprocess.run(command, capture_output=True, text=True)
    return [path for path in listing.stdout.split("\n") if path]


def main(argv):
    if "--self-test" in argv:
        return selfTest()
    problems, unchecked = mappingProblems()
    for note in unchecked:
        print("check-build-arm: %s" % note, file=sys.stderr)
    if problems:
        print("check-build-arm: FAILED — the arm table disagrees with what the "
              "builds compile", file=sys.stderr)
        for problem in problems:
            print("    %s" % problem, file=sys.stderr)
        print("  An entry naming the wrong build sends a reader to a green that "
              "answers a", file=sys.stderr)
        print("  different question, and the advisory below is only as true as "
              "this table.", file=sys.stderr)
        return 1

    asserted = assertedTypes()
    if not asserted:
        print("check-build-arm: no frontend assertion, layout query or shader names "
              "a Core type — either the", file=sys.stderr)
        print("  pins moved or the namespace list stopped matching. Nothing "
              "was compared.", file=sys.stderr)
        return 2

    declared = declaringHeaders(set(asserted))
    changed = changedFiles(argv[1:])
    if changed is None:
        print("check-build-arm: no merge base — nothing compared.", file=sys.stderr)
        return 2

    # A type declared in no Core header is one this resolver lost, and reporting
    # nothing for it would be indistinguishable from the change being safe.
    unresolved = sorted(name for name in asserted if name not in declared)
    if unresolved:
        print("check-build-arm: pinned by a frontend but declared in no Core "
              "header: %s" % ", ".join(unresolved), file=sys.stderr)
        print("  The type moved, or the declaration is spelled in a form this "
              "does not read. A", file=sys.stderr)
        print("  change to it would be reported as needing no arm.", file=sys.stderr)
        return 1

    included = shaderHeaders()
    needed = advise(changed, asserted, declared, included)

    if not needed:
        print("check-build-arm: ok (%d Core types pinned at %d frontend sites and "
              "%d header(s) compiled into a shader; this change touches none of them)"
              % (len(asserted), sum(len(v) for v in asserted.values()), len(included)))
        return 0

    print("check-build-arm: ADVISORY — this change touches a Core header pinned "
          "outside any")
    print("  portable build. The gates that just passed do not compile its consumer.")
    for arm, entries in sorted(needed.items()):
        print("    %s" % arm)
        for entry in sorted(entries):
            print("      %s" % entry)
    print("\n  Run that arm before merging. It exits zero either way — the point "
          "is that")
    print("  \"every gate green\" and \"this compiles\" are different claims here.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
