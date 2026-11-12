#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""style_sections_app — the sections the app owns.

check-style.py loads this table beside ubiquitty-core's in a checkout that holds
the app's files. A section runs in the app's checkout, and in a checkout that
holds every repository.
"""

REPOSITORY = "app"

HAND = {}

SECTIONS = (
    {
        "title": 'a header claiming a frontend has one (Scripts/check-frontend-claims.py)',
        "after": 'a diagnostic write cannot end the process (Scripts/check-log-writes.py)',
        "kind": "gate",
        "gate": 'check-frontend-claims.py',
        "command": ['./Scripts/check-frontend-claims.py'],
        "ok": 'ok',
        "bad": 'all',
        "fail": None,
    },
    {
        "title": 'the Wscons frontend type-checks (Scripts/check-wscons-compiles.sh)',
        "after": 'Swift bridging reaches portable code through one door (Scripts/check-swift-interop.py)',
        "kind": "gate",
        "gate": 'check-wscons-compiles.sh',
        "command": ['./Scripts/check-wscons-compiles.sh'],
        "ok": 'all',
        "bad": 'all',
        "fail": None,
    },
    {
        "title": 'every settings range has a setting (Scripts/check-settings-schema-live.py)',
        "after": 'the blink hint and its stamp move together (Scripts/check-blink-hint-chokepoint.py)',
        "kind": "gate",
        "gate": 'check-settings-schema-live.py',
        "command": ['python3', './Scripts/check-settings-schema-live.py'],
        "ok": 'all',
        "bad": 'all',
        "fail": None,
    },
    {
        "title": "the editors' wire numbers are what the headers produce (Scripts/check-wire-tables.py)",
        "after": "the editors' own wire tables name what the headers hold (Scripts/check-editor-wire-tables.py)",
        "kind": "gate",
        "gate": 'check-wire-tables.py',
        "command": ['python3', './Scripts/check-wire-tables.py'],
        "ok": 'all',
        "bad": 'all',
        "fail": None,
    },
    {
        "title": 'each arm says which glyph path it drives (Scripts/check-glyph-slot-arms.py)',
        "after": 'the hooks this clone will actually run (Scripts/check-hooks-installed.py)',
        "kind": "gate",
        "gate": 'check-glyph-slot-arms.py',
        "command": ['python3', './Scripts/check-glyph-slot-arms.py'],
        "ok": 'all',
        "bad": 'all',
        "fail": None,
    },
    {
        "title": 'the Wscons Core trim is the Linux one (Scripts/check-core-subset-parity.sh)',
        "after": 'a hand-copied struct still matches (Scripts/check-bench-mirrors.py)',
        "kind": "gate",
        "gate": 'check-core-subset-parity.sh',
        "command": ['./Scripts/check-core-subset-parity.sh'],
        "ok": 'all',
        "bad": 'all',
        "fail": None,
    },
    {
        "title": 'every GTK smoke passes and prints an agreeing verdict (Scripts/check-linux-smokes.sh)',
        "after": 'every content gate reaches a new file (Scripts/check-gate-subjects.sh)',
        "kind": "deferred",
        "to": '"Linux battery (frontend)"',
        "why": 'the required linux-smokes stage runs every GTK smoke against the '
               'frontend built in that job; a source or unit-test job has no GTK application',
        "gate": 'check-linux-smokes.sh',
        "command": ['./Scripts/check-linux-smokes.sh'],
        "ok": 'all',
        "bad": 'all',
        "fail": None,
    },
    {
        "title": 'every macOS smoke, or the frontend files a skip left uncovered '
                 '(Scripts/check-macos-smokes.py)',
        "after": 'every GTK smoke passes and prints an agreeing verdict (Scripts/check-linux-smokes.sh)',
        "kind": "deferred",
        "to": '"Apple battery (macos)"',
        "why": 'the required macos-smokes stage invokes this same gate against '
               'the application built in that job',
        "gate": 'check-macos-smokes.py',
        "command": ['python3', './Scripts/check-macos-smokes.py'],
        "ok": 'all',
        "bad": 'all',
        "fail": None,
    },
    {
        "title": 'every bundled family has its file beside each binary (Scripts/check-bundled-fonts.py)',
        "after": 'the acronym scanners agree (Scripts/check-acronym-rules.py)',
        "kind": "gate",
        "gate": 'check-bundled-fonts.py',
        "command": ['python3', './Scripts/check-bundled-fonts.py'],
        "ok": 'last',
        "bad": 'all',
        "fail": None,
    },
    {
        "title": 'every exposed operation is in the method registry',
        "after": 'every message the daemon dispatches is accounted for',
        "kind": "gate",
        "gate": 'check-method-registry.py',
        "command": ['./Scripts/check-method-registry.py'],
        "ok": 'last',
        "bad": 'all',
        "fail": 'an operation is exposed outside the method registry (Scripts/check-method-registry.py)',
    },
    {
        "title": "the editors' own wire tables name what the headers hold (Scripts/check-editor-wire-tables.py)",
        "after": 'what quotes or names a wire number tracks the headers (Scripts/check-wire-version-pins.py)',
        "kind": "gate",
        "gate": 'check-editor-wire-tables.py',
        "command": ['python3', './Scripts/check-editor-wire-tables.py'],
        "ok": 'last',
        "bad": 'all',
        "fail": None,
    },
)
