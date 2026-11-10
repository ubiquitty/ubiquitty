#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""check-macos-smokes — run every headless test mode the macOS binary dispatches.

A smoke that asserts into an exit code no gate reads is a check that passes
without running. The mode list is DERIVED from the entry point's own dispatch
(ApplicationMain.swift), so a smoke added there is gated the day it lands, or this fails loudly because the
derivation broke.

The pattern reaches the smoke family alone, so a bench — which asserts nothing
and costs minutes — is out by construction rather than by a second filter.

Reports rather than fails when there is no app to run: a gate that fails for the
machine it sits on is one people switch off, and a Linux runner builds no macOS
app. What the skip names is the part that carries — the frontend files this
branch changed that nothing then examined.
"""

import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import library_scripts  # noqa: E402,F401 — makes the libraries' modules importable
import ubq_roots  # noqa: E402
from gate_framework import Gate  # noqa: E402

APP_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

#: The trees the app is built from. A change under one of these is what a skip leaves uncovered.
APP_SOURCES = ("Source/Platform/macOS", "Source/Platform/Apple",
               "Source/UbiquittyKit", "Source/UbiquittyRenderKit", "Source/Core")

#: The source kinds a build consumes; a newer one means the app predates the tree.
SOURCE_SUFFIXES = (".swift", ".cpp", ".h", ".mm")

#: The entry point whose dispatch names every headless mode.
DISPATCH = ("Source", "Platform", "macOS", "App", "Application", "ApplicationMain.swift")

#: The dispatch's own literals: the smoke family plus its selftest/print/dump siblings.
MODE = re.compile(r'"(--(?:smoke|selftest|print-config|dump-png)[a-z-]*)"')

#: Modes known red, each against the item that owns the failure.
#:
#: The set is compared, not the count, so this cannot rot in either direction: a
#: mode that is red and unlisted fails, and a mode that is listed and GREEN fails
#: too, under its own name, so the line is deleted rather than left standing over
#: a failure that has gone. An entry with no owner is how a red becomes
#: permanent, so the owner is part of the entry rather than a comment beside it.
WAIVED = {}


class MacOSSmokes(Gate):
    name = "check-macos-smokes"
    subject = "the app is built from"

    def __init__(self, argv=None):
        super().__init__(argv)
        # The framework roots a gate at its own checkout, which is Core's where
        # Core is a library; this gate reads the app's tree.
        self.root = APP_ROOT

    def examine(self):
        build = os.path.join(self.buildRoot(), "macos")
        binary = os.path.join(build, "Source", "Platform", "macOS",
                              "Ubiquitty.app", "Contents", "MacOS", "Ubiquitty")
        if not os.access(binary, os.X_OK):
            return self.skipped(f"no macOS app in {build} (./Scripts/build-macos.sh builds it).",
                                self.uncovered())

        newer = self.newerSource(binary)
        if newer:
            return self.failed(f"{newer} is newer than the app ({binary}); "
                               "./Scripts/build-macos.sh builds the app these smokes should judge")

        modes = self.modes()
        if not modes:
            return self.failed("no test modes found in ApplicationMain.swift; the derivation broke")

        logs = os.path.join(self.buildRoot(), "macos-smokes")
        os.makedirs(logs, exist_ok=True)
        outcomes = {}
        # Each smoke reads an empty configuration directory of its own. A smoke
        # builds its surface from the configuration it finds, so one run with
        # the developer's own file judged that file's settings rather than the
        # tree's, and two machines disagreed about the same commit.
        isolated = tempfile.mkdtemp(prefix="ubq-macos-smokes-config-")
        environment = {**os.environ, "XDG_CONFIG_HOME": isolated}
        for mode in modes:
            log = os.path.join(logs, mode.removeprefix("--smoke-") + ".log")
            with open(log, "wb") as handle:
                finished = subprocess.run([binary, mode], stdout=handle,
                                          stderr=subprocess.STDOUT, check=False, env=environment)
            outcomes[mode] = finished.returncode
            waiver = WAIVED.get(mode)
            if finished.returncode == 0:
                if not waiver:
                    self.detail(f"{mode} green")
            elif waiver:
                self.detail(f"{mode} red, waived against {waiver[0]}: {waiver[1]}")
            else:
                self.finding(log, f"{mode} exited {finished.returncode}: {self.lastLine(log)}")
        shutil.rmtree(isolated, ignore_errors=True)

        # The grid cache switched on against switched off, frame for frame: the
        # same app, so it rides the same gate rather than one of its own that a
        # Linux runner would only ever skip.
        differential = "grid-cache-differential"
        log = os.path.join(logs, differential + ".log")
        config = library_scripts.locate("Tests/Snapshots/configs/native/jetbrains_mono_13.toml")
        with open(log, "wb") as handle:
            finished = subprocess.run([sys.executable, library_scripts.locate("Scripts/check-grid-cache-differential.py"),
                                       binary, config], stdout=handle, stderr=subprocess.STDOUT, check=False)
        outcomes[differential] = finished.returncode
        if finished.returncode == 0:
            self.detail(f"{differential} green")
        else:
            self.finding(log, f"{differential} exited {finished.returncode}: {self.lastLine(log)}")

        red, greenButWaived = self.classify(outcomes)
        if red:
            return self.failed("mode(s) red", red)
        if greenButWaived:
            return self.failed("waived mode(s) now green — delete the entry", greenButWaived)
        waived = sorted(mode for mode in modes if mode in WAIVED)
        if waived:
            return self.ok(f"{len(modes) - len(waived)} mode(s) green and the grid cache differential; waived: {' '.join(waived)} ")
        return self.ok(f"{len(modes)} mode(s) green and the grid cache differential: {' '.join(modes)} ")

    def newerSource(self, binary):
        """The first source file the app was built from that is newer than it, or None.

        An app older than its sources is the previous build, and it passes or
        fails for the previous build's reasons; a failed compile leaves the last
        good app in place. The iOS smokes apply the same rule to their bundle.
        """
        stamp = os.path.getmtime(binary)
        coreRoot = str(ubq_roots.core_root())
        kitRoot = str(ubq_roots.kit_root())
        trees = [os.path.join(self.root, tree) for tree in APP_SOURCES]
        trees += [os.path.join(kitRoot, "Source", "UbiquittyKit"),
                  os.path.join(kitRoot, "Source", "UbiquittyRenderKit")]
        trees += [os.path.join(coreRoot, "Source", tree) for tree in ("Core", "PAL", "Base")]
        for tree in trees:
            for directory, _, names in os.walk(tree):
                for name in sorted(names):
                    if name.endswith(SOURCE_SUFFIXES):
                        path = os.path.join(directory, name)
                        if os.path.getmtime(path) > stamp:
                            return os.path.relpath(path, self.root)
        return None

    @staticmethod
    def classify(outcomes, waivers=None):
        """The two ways a run can disagree with the waiver set.

        Kept apart from the running so the rule can be asserted without a
        binary: a control that has to plant an executable tests the planting as
        much as the rule, and the rule is what a waiver gets wrong.

        - Parameters:
          - outcomes: Each mode's exit status, keyed by mode.
          - waivers: The waiver set to judge against; WAIVED when omitted. The
            self-test passes one it plants, so the rule is exercised whether or
            not any mode is waived.
        - Returns: The unwaived modes that were red, and the waived modes that
          were green, each sorted so a verdict reads the same twice.
        """
        judged = WAIVED if waivers is None else waivers
        red = sorted(mode for mode, code in outcomes.items() if code != 0 and mode not in judged)
        stale = sorted(f"{mode} (waived against {judged[mode][0]})"
                       for mode, code in outcomes.items() if code == 0 and mode in judged)
        return red, stale

    def selfTest(self):
        """The derivation is what this gate rests on, so the self-test plants a fault in it.

        A dispatch carrying a mode must yield it, and one carrying only the prefix
        literal must not: running the prefix asks the binary to reject it, and a
        gate that ran it would read the refusal as a red smoke. The planted
        dispatch carries a bench too, which the pattern must not reach either.
        """
        import tempfile

        failures = []
        planted = ('func dispatch(_ flag: String) {\n'
                   '    switch flag {\n'
                   '    case "--smoke-shell": runShell()\n'
                   '    case "--bench-parse": runBench()\n'
                   '    default: if flag.hasPrefix("--smoke-") { refuse() }\n'
                   '    }\n'
                   '}\n')
        with tempfile.TemporaryDirectory() as directory:
            dispatch = pathlib.Path(directory, *DISPATCH)
            dispatch.parent.mkdir(parents=True)
            dispatch.write_text(planted, encoding="utf-8")
            probe = MacOSSmokes([])
            probe.root = directory
            found = probe.modes()

        if found != ["--smoke-shell"]:
            failures.append(f"the derivation read {found}, not ['--smoke-shell']")
        if "--smoke-" in found:
            failures.append("the prefix literal was taken for a mode the binary accepts")
        # The waiver's failure modes, planted rather than reasoned about. A
        # waiver that swallowed everything would leave the gate green while
        # nothing gated, which is the shape this whole stage exists to end.
        # The waiver set is planted too, so the rule is exercised whether or not
        # any mode is waived.
        waivedMode = "--smoke-planted"
        plantedWaivers = {waivedMode: ("a-planted-owner", "a waiver the self-test plants")}
        if self.classify({waivedMode: 1}, plantedWaivers)[0]:
            failures.append("a waived red was reported as a failure")
        if self.classify({"--smoke-not-waived": 1}, plantedWaivers)[0] != ["--smoke-not-waived"]:
            failures.append("an unwaived red did not fail the gate")
        if not self.classify({waivedMode: 0}, plantedWaivers)[1]:
            failures.append("a waived mode that passed did not ask for its entry to be deleted")
        if self.classify({"--smoke-not-waived": 0}, plantedWaivers) != ([], []):
            failures.append("an unwaived green was not simply green")

        # A planted app, dated after every real source, is fresh; a source dated
        # after it is the previous build's evidence, and is named.
        with tempfile.TemporaryDirectory() as directory:
            binary = pathlib.Path(directory, "Ubiquitty")
            binary.write_text("", encoding="utf-8")
            future = os.path.getmtime(binary) + 10 * 365 * 86400
            os.utime(binary, (future, future))
            source = pathlib.Path(directory, "Source", "Platform", "macOS", "Planted.swift")
            source.parent.mkdir(parents=True)
            source.write_text("", encoding="utf-8")
            probe = MacOSSmokes([])
            probe.root = directory
            if probe.newerSource(str(binary)) is not None:
                failures.append("an app newer than every source was called stale")
            os.utime(source, (future + 60, future + 60))
            if probe.newerSource(str(binary)) != os.path.join("Source", "Platform", "macOS", "Planted.swift"):
                failures.append("a source newer than the app was not named")

        if failures:
            return self.failed("self-test finding(s)", failures)
        return self.ok("the derivation takes a mode, refuses the prefix literal, "
                       "the waiver set fails both ways, and a stale app is refused")

    def modes(self):
        """Every mode the dispatch accepts, from the dispatch.

        A literal ending in the separator is a PREFIX the dispatch tests against
        rather than a mode it accepts — `flag.hasPrefix("--smoke-")` is how the
        unknown-flag refusal recognises its own family. Running one asks the
        binary to reject it, which it correctly does, and a gate reads that as a
        red smoke.
        """
        dispatch = os.path.join(self.root, *DISPATCH)
        with open(dispatch, encoding="utf-8") as handle:
            found = MODE.findall(handle.read())
        return sorted({mode for mode in found if not mode.endswith("-")})

    def uncovered(self):
        """The app's own files this branch changed, which a skip leaves unexamined.

        Against the merge base rather than origin/main's tip: a diff against the
        tip attributes to this branch every file someone else moved since it
        forked.
        """
        # A library mount that moved is read as the files between its pins.
        return ubq_roots.changed_paths("origin/main", self.root, APP_SOURCES) or []

    def buildRoot(self):
        """Where builds land, which is outside the checkout."""
        return subprocess.run([sys.executable, library_scripts.locate("Scripts/build_root.py")],
                              capture_output=True, text=True, check=False).stdout.strip()

    def git(self, *arguments):
        """Git's answer, or empty where it has none. A repository question is not a gate failure."""
        return subprocess.run(["git", "-C", self.root, *arguments],
                              capture_output=True, text=True, check=False).stdout.strip()

    @staticmethod
    def lastLine(path):
        """The last line of a log, or a stand-in when the run wrote none."""
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                lines = handle.read().splitlines()
        except OSError:
            return "no output"
        return lines[-1] if lines else "no output"


if __name__ == "__main__":
    raise SystemExit(MacOSSmokes.main())
