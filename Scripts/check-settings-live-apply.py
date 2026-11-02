#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Require live settings changes to reach open windows through one subscription.

A settings write configures Core (configureOwnKey and its siblings), and Core
tells each ConfigurationSubscription once. The macOS window owner holds the one
subscription and re-applies what moved to every open window. A setter that also
broadcasts to the windows it thinks it touches can reach one shell and miss
another, so a broadcast from a settings write is a finding.

Two calls stay because they are intents rather than configuration: a picked
cursor shape hands the style back over a program's DECSCUSR, and a theme pick
applies a theme index the system-appearance resolver chose. UI scenarios verify
what each window shows.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DELEGATE = sorted((ROOT / "Source/Platform/macOS/App/Application").glob("AppDelegate*.swift"))
FOLLOWER = ROOT / "Source/Platform/macOS/App/Windowing/TerminalWindowController+Configuration.swift"
SETTINGS_SWIFT = sorted((ROOT / "Source/Platform/macOS/App").glob("*.swift"))

FUNCTION = re.compile(r"\bfunc (\w+)\(")
WRITER = re.compile(r"^(settingsSet|toggle|choose)")
SWIFT_BROADCAST = re.compile(r"TerminalWindowController\.(apply\w*ToOpenWindows|refreshClosePolicy|refreshTabAccessoriesForOpenWindows)\((at:)?")
# A picked cursor shape and a theme index the resolver chose are intents, not
# configuration; every other broadcast from a writer is a finding.
INTENTS = {("applyPickedCursorShapeToOpenWindows", ""), ("applyThemeToOpenWindows", "at:")}


def methods(source):
    """Each function's name and body, the body read to its matching brace."""
    for match in FUNCTION.finditer(source):
        start = source.find("{", match.end())
        if start < 0:
            continue
        depth = 0
        for index in range(start, len(source)):
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
                if depth == 0:
                    yield match.group(1), source[start + 1:index]
                    break


def delegate_findings(source):
    findings = []
    for name, body in methods(source):
        if not WRITER.match(name):
            continue
        if "mutableValues()" in body:
            findings.append(f"{name} writes the live values; configure the key instead")
        for action, argument in SWIFT_BROADCAST.findall(body):
            if (action, argument) not in INTENTS:
                findings.append(f"{name} broadcasts {action}; the window owner's subscription applies it")
    return findings


def swift_findings(sources):
    findings = []
    for path, source in sources:
        for match in SWIFT_BROADCAST.finditer(source):
            line = source.count("\n", 0, match.start()) + 1
            findings.append(f"{path.name}:{line}: a settings surface calls {match.group(1)}; the subscription applies it")
    return findings


def follower_findings(source):
    if not re.search(r"ConfigurationSubscription\.notifying\(", source):
        return ["the window owner holds no ConfigurationSubscription"]
    if "liveRenderConfiguration()" not in source:
        return ["the window owner's subscription does not re-read liveRenderConfiguration()"]
    return []


def main():
    if "--self-test" in sys.argv:
        quiet = "func settingsSetFont(_ isOn: Bool) {\n    setSetting(.FontLigatures, bool: isOn)\n}\n"
        assert not delegate_findings(quiet)
        loud = quiet.replace("setSetting", "TerminalWindowController.applyFontConfigurationToOpenWindows()\n    setSetting")
        assert delegate_findings(loud)
        intent = quiet.replace("setSetting", "TerminalWindowController.applyPickedCursorShapeToOpenWindows()\n    setSetting")
        assert not delegate_findings(intent)
        chosen = quiet.replace("setSetting", "TerminalWindowController.applyThemeToOpenWindows(at: 2)\n    setSetting")
        assert not delegate_findings(chosen)
        assert delegate_findings(quiet.replace("setSetting", "TerminalWindowController.applyThemeToOpenWindows()\n    setSetting"))
        assert delegate_findings(quiet.replace("setSetting(", "mutableValues().x = isOn; setSetting("))
        assert swift_findings([(Path("Pane.swift"), "set: { TerminalWindowController.applyAppearanceToOpenWindows() }")])
        assert follower_findings("")
        assert not follower_findings("ConfigurationSubscription.notifying( liveRenderConfiguration()")
        print("check-settings-live-apply: self-test ok")
        return 0
    delegate = "\n".join(path.read_text() for path in DELEGATE)
    findings = delegate_findings(delegate)
    findings += swift_findings([(path, path.read_text()) for path in SETTINGS_SWIFT])
    findings += follower_findings(FOLLOWER.read_text() if FOLLOWER.exists() else "")
    for finding in findings:
        print(finding, file=sys.stderr)
    writers = sum(1 for name, _ in methods(delegate) if WRITER.match(name))
    print(f"check-settings-live-apply: {writers} settings writers and one subscription checked, {len(findings)} failures")
    return bool(findings)


if __name__ == "__main__":
    sys.exit(main())
