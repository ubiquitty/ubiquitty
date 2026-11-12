#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# Scripts/run-tests-stanzas-app.sh — the stanzas of the app.
#
# Sourced by Core's Scripts/run-tests.sh in a checkout that holds the app, after the stanzas
# of ubiquitty-core when it holds those too. Every stanza is written against that
# driver's helpers (`wanted`, `build_and_run`, `ubq_build_test`, `OUT`, `ROOT`,
# `CORE_ROOT`, `KIT_ROOT`, `RAN`), and its name is literal so
# Scripts/stanza-declarations.awk can list it. `ROOT` is the app's checkout; a file
# of a library is named through the library's root, which is `ROOT` where one tree
# holds every repository.

# The Linux host route, against a stand-in ssh and rsync: which machine a
# Linux arm runs on, and that the remote directory goes whatever the stage did.
if wanted linux_host; then
    echo "=== linux_host ==="
    RAN=$((RAN + 1))
    python3 "$ROOT/Scripts/test-linux-host.py" || exit 1
fi

# OSC 52 clipboard-read resolver registry (UBClipboardReadInterop.cpp). Registers a
# stub resolver, drives the approve + deny edges of resolveClipboardRead, and
# asserts the opaque token pointer + bool marshal through unchanged.
build_and_run test_clipboard_read_resolver \
    -DUBIQUITTY_TEST_WITHOUT_CORE \
    -I"$ROOT/Source" -I"$CORE_ROOT/Source" -I"$KIT_ROOT/Source" \
    -I"$ROOT/Tests" -I"$CORE_ROOT/Tests" \
    "$ROOT/Tests/Platform/test_clipboard_read_resolver.cpp" \
    "$ROOT/Source/Platform/macOS/App/UBClipboardReadInterop.cpp" \
    "$CORE_ROOT/Source/Platform/POSIX/SystemPAL.cpp"

if wanted ui_test_pasteboard_isolation; then
    echo "=== ui_test_pasteboard_isolation ==="
    if [ "$(uname -s)" = "Darwin" ]; then
        bash "$ROOT/Scripts/test-ui-pasteboard-isolation.sh" || exit 1
        RAN=$((RAN + 1))
    else
        ubq_skip "UI-test clipboard isolation requires AppKit"
        SKIPPED=$((SKIPPED + 1))
    fi
fi

# Settings search model — the first SWIFT host test: pins SettingsModel.swift's
# settingsSearchHits() flatten (pane rows -> hits with rowID + the detail ??
# card-title fallback; .custom -> one title-level hit carrying its
# searchKeywords) and SettingsSearchHit.matches() (case-insensitive
# label/detail/category filter) on a synthetic catalog. Plain `xcrun swiftc`,
# no bridging header / C++ interop / app module — the pure data model compiles
# alone, so the logic is host-testable headlessly. -parse-as-library because
# the test main is @main in a named file. Darwin-only (SwiftUI SDK). Outside the
# coverage report: that instruments the C/C++ suite via llvm-profdata, and
# swiftc takes different profile flags.
if [ "$(uname -s)" = "Darwin" ] && wanted test_macos_settings_search; then
    NAME=test_macos_settings_search
    OUT_BIN="$OUT/$NAME"
    mkdir -p "$OUT"
    echo "=== $NAME ==="
    xcrun swiftc -parse-as-library \
        "$ROOT/Tests/Platform/test_macos_settings_search.swift" \
        "$ROOT/Source/Platform/macOS/App/SettingsModel.swift" \
        -o "$OUT_BIN" || exit 1
    "$OUT_BIN" || exit 1
    RAN=$((RAN + 1))
fi

# Trigger actions — the macOS arm's run_command spawn performs Core's argv with
# no shell: a match full of shell syntax is one argument to the program, named
# by path or found on the search path. The gate, the template split and the
# webhook checks are Core's (test_trigger_effects, test_trigger_actions). Plain
# `xcrun swiftc` with TriggerActions.swift alone, as test_macos_settings_search
# is built. Darwin-only.
if [ "$(uname -s)" = "Darwin" ] && wanted test_macos_trigger_actions; then
    NAME=test_macos_trigger_actions
    OUT_BIN="$OUT/$NAME"
    mkdir -p "$OUT"
    echo "=== $NAME ==="
    xcrun swiftc -parse-as-library \
        "$ROOT/Tests/Platform/test_macos_trigger_actions.swift" \
        "$ROOT/Source/Platform/macOS/App/Windowing/TriggerActions.swift" \
        -o "$OUT_BIN" || exit 1
    "$OUT_BIN" || exit 1
    RAN=$((RAN + 1))
fi

# Drop-down hotkey — QuakeHotkey.swift reads the `[quake] hotkey` spec into the
# Carbon modifier mask and virtual key code the global hotkey registers: the
# Input::Keybindings modifier spellings, named keys, digits, letters, F1 to F20,
# and no chord for a spec naming no key. Plain `xcrun swiftc` with the parser
# alone. Darwin-only.
if [ "$(uname -s)" = "Darwin" ] && wanted test_macos_quake_hotkey; then
    NAME=test_macos_quake_hotkey
    OUT_BIN="$OUT/$NAME"
    mkdir -p "$OUT"
    echo "=== $NAME ==="
    xcrun swiftc -parse-as-library \
        "$ROOT/Tests/Platform/test_macos_quake_hotkey.swift" \
        "$ROOT/Source/Platform/macOS/App/DropDown/QuakeHotkey.swift" \
        -o "$OUT_BIN" || exit 1
    "$OUT_BIN" || exit 1
    RAN=$((RAN + 1))
fi

# Kitty file-transport reader: the macOS frontend's UBFileReadClient
# — the hardened t=f/t=t readFile. Escape-driven arbitrary-file-read surface, so the
# test pins the security contract with real temp files: fail-closed sans policy,
# origin-gated (Local only), S_ISREG-only (FIFO rejected), bounded read, temp-dir only
# (a user path is never read), and the t=t unlink is inode + temp-dir + marker verified
# (a temp file without `tty-graphics-protocol` is neither read nor deleted). Links the
# Core (Terminal + CapabilityPolicy); Darwin-only (F_GETPATH / _CS_DARWIN_USER_TEMP_DIR).
if [ "$(uname -s)" = "Darwin" ] && wanted test_macos_file_read; then
    NAME=test_macos_file_read
    OUT_BIN="$OUT/$NAME"
    mkdir -p "$OUT"
    echo "=== $NAME ==="
    ubq_build_test test_macos_file_read "$OUT_BIN" "$OUT/test_macos_file_read-build.log" || { cat "$OUT/test_macos_file_read-build.log" >&2; exit 1; }
    "$OUT_BIN" || exit 1
    RAN=$((RAN + 1))
fi

# AppleScript wiring: the scripting dictionary must be well-formed
# XML whose XInclude of the system Standard Suite resolves, declare the `do
# script` command + the window/tab classes, and Info.plist must turn scripting
# on (NSAppleScriptEnabled) and name the dictionary (OSAScriptingDefinition).
# A pure structural check — the runtime classes need a live app (verified by the
# `sdef <App>` extraction during a real build). Darwin-only (xmllint/PlistBuddy).
if [ "$(uname -s)" = "Darwin" ] && wanted test_macos_applescript; then
    NAME=test_macos_applescript
    echo "=== $NAME ==="
    SDEF="$ROOT/Source/Platform/macOS/Ubiquitty.sdef"
    # The template, because that is the file the tree carries: cmake configures it
    # into the bundle, and a gate reading the configured copy would pass or fail on
    # whether someone had built rather than on what the declaration says. Its
    # placeholders sit inside string values, so it parses as a plist unconfigured.
    PLIST="$ROOT/Source/Platform/macOS/Info.plist.in"
    fail=0
    xmllint --noout "$SDEF" || { echo "FAIL: $SDEF is not well-formed XML"; fail=1; }
    xmllint --xinclude --noout "$SDEF" || { echo "FAIL: $SDEF XInclude (Standard Suite) does not resolve"; fail=1; }
    grep -q 'name="do script"' "$SDEF" || { echo "FAIL: sdef missing the 'do script' command"; fail=1; }
    grep -q 'class="UBDoScriptCommand"' "$SDEF" || { echo "FAIL: sdef 'do script' not bound to UBDoScriptCommand"; fail=1; }
    grep -q 'class="UBScriptableWindow"' "$SDEF" || { echo "FAIL: sdef window not bound to UBScriptableWindow"; fail=1; }
    grep -q 'class="UBScriptableTab"' "$SDEF" || { echo "FAIL: sdef tab not bound to UBScriptableTab"; fail=1; }
    [ "$(/usr/libexec/PlistBuddy -c 'Print :NSAppleScriptEnabled' "$PLIST" 2>/dev/null)" = "true" ] \
        || { echo "FAIL: Info.plist NSAppleScriptEnabled is not true"; fail=1; }
    [ "$(/usr/libexec/PlistBuddy -c 'Print :OSAScriptingDefinition' "$PLIST" 2>/dev/null)" = "Ubiquitty.sdef" ] \
        || { echo "FAIL: Info.plist OSAScriptingDefinition is not Ubiquitty.sdef"; fail=1; }
    if [ "$fail" -ne 0 ]; then
        gate_failed_count "test_macos_applescript" 1 "AppleScript case(s) failed; detail above"
        exit 1
    fi
    echo "test_macos_applescript: all passed"
    RAN=$((RAN + 1))
fi

# Font changes must reach every pane sharing the window's renderer. The Swift
# control compiles the real fan-out bodies without AppKit windows or a clipboard.
if wanted test_font_fanout; then
    echo "=== test_font_fanout ==="
    if python3 "$ROOT/Scripts/test-font-fanout.py" \
            --controller "$ROOT/Source/Platform/macOS/App/Windowing/TerminalWindowController.swift"; then
        RAN=$((RAN + 1))
    else
        font_fanout_status=$?
        if [ "$font_fanout_status" -ne 77 ]; then
            exit "$font_fanout_status"
        fi
        ubq_skip "test_font_fanout unavailable (Darwin and Swift are required)"
        SKIPPED=$((SKIPPED + 1))
        # CTest invokes one stanza and preserves its unavailable result.
        if [ "${#FILTERS[@]}" -eq 1 ]; then
            exit 77
        fi
    fi
fi

# emacs_sync_admission — real editor readers with memory-only own-consent fixtures.
if wanted emacs_sync_admission; then
    echo "=== emacs_sync_admission ==="
    if ! command -v emacs >/dev/null 2>&1; then
        ubq_skip_unless_required emacs "emacs not installed"
        SKIPPED=$((SKIPPED + 1))
    else
        RAN=$((RAN + 1))
        emacs -Q --batch -l "$ROOT/Tests/Platform/emacs-sync-admission-test.el" \
            --eval '(ert-run-tests-batch-and-exit "^ubiquitty-admission-")' || exit 1
    fi
fi

# emacs_sync_effects — strict effect grammar, receipts and real frame dispatch.
if wanted emacs_sync_effects; then
    echo "=== emacs_sync_effects ==="
    if ! command -v emacs >/dev/null 2>&1; then
        ubq_skip_unless_required emacs "emacs not installed"
        SKIPPED=$((SKIPPED + 1))
    else
        RAN=$((RAN + 1))
        emacs --batch -Q -l "$ROOT/Tests/Platform/emacs-sync-effects-test.el" || exit 1
        emacs --batch -Q -l "$ROOT/Tests/Platform/emacs-sync-clipboard-test.el" || exit 1
    fi
fi

# emacs_sync_cell_metrics — bounded braille drawing without fallback-font drift.
if wanted emacs_sync_cell_metrics; then
    echo "=== emacs_sync_cell_metrics ==="
    if ! command -v emacs >/dev/null 2>&1; then
        ubq_skip_unless_required emacs "emacs not installed"
        SKIPPED=$((SKIPPED + 1))
    else
        RAN=$((RAN + 1))
        emacs --batch -Q -l "$ROOT/Tests/Platform/emacs-sync-cell-metrics-test.el" || exit 1
    fi
fi

# neovim_sync_admission — real editor readers with memory-only own-consent fixtures.
if wanted neovim_sync_admission; then
    echo "=== neovim_sync_admission ==="
    if neovim_unusable="$(ubq_neovim_unusable_reason)"; then
        ubq_skip_unless_required nvim "$neovim_unusable"
        SKIPPED=$((SKIPPED + 1))
    else
        RAN=$((RAN + 1))
        nvim --headless --noplugin -u NONE -i NONE -n \
            -l "$ROOT/Tests/Platform/neovim_sync_admission_test.lua" || exit 1
    fi
fi

# neovim_sync_effects — exact cursors and streamed image digest verification.
if wanted neovim_sync_effects; then
    echo "=== neovim_sync_effects ==="
    if neovim_unusable="$(ubq_neovim_unusable_reason)"; then
        ubq_skip_unless_required nvim "$neovim_unusable"
        SKIPPED=$((SKIPPED + 1))
    else
        RAN=$((RAN + 1))
        nvim --headless -u NONE -l "$ROOT/Tests/Platform/neovim_sync_effects_test.lua" || exit 1
    fi
fi

# emacs_sync_decode — the Emacs client decodes the stream a Sync host
# connection sent a client that attached: the checkpoint across its bulk
# chunks, then the update after more output. A client behind the host's body
# version, gating rendering on exact equality, drops every frame in silence and
# leaves the buffer empty; only a real stream compared against what the client
# believes one looks like shows it. Needs emacs on
# PATH; skipped where it is absent.
if wanted emacs_sync_decode && command -v cmake >/dev/null 2>&1; then
    echo "=== emacs_sync_decode ==="
    if ! command -v emacs >/dev/null 2>&1; then
        ubq_skip_unless_required emacs "emacs not installed"
        SKIPPED=$((SKIPPED + 1))
    else
        RAN=$((RAN + 1))
        EMACS_BUILD="$OUT/emacs-fixture"
        mkdir -p "$EMACS_BUILD"
        if EMACS_FIXTURE="$(ubq_sync_stream_fixture "$OUT/emacs-fixture-build.log")"; then
            "$EMACS_FIXTURE" "$EMACS_BUILD/attach.bin" "$EMACS_BUILD/update.bin" "$EMACS_BUILD/control.bin" "$EMACS_BUILD/pictures.bin" || exit 1
            emacs --batch -Q -l "$ROOT/Tests/Platform/emacs-sync-decode-test.el" \
                "$EMACS_BUILD/attach.bin" "$EMACS_BUILD/update.bin" "$EMACS_BUILD/control.bin" "$EMACS_BUILD/upstream.bin" "$EMACS_BUILD/pictures.bin" || exit 1
            # What the client sent, read by the host's own decoders: every
            # frame one the host takes, and the transcript the one recorded.
            if ! "$EMACS_FIXTURE" --verify "$EMACS_BUILD/upstream.bin" >"$EMACS_BUILD/upstream.txt"; then
                cat "$EMACS_BUILD/upstream.txt"
                echo "emacs_sync_decode: FAILED — $(grep -c '^REFUSED' "$EMACS_BUILD/upstream.txt") frame(s) the host refuses"
                exit 1
            fi
            diff -u "$ROOT/Tests/Platform/emacs-sync-upstream.expected" "$EMACS_BUILD/upstream.txt" || {
                echo "emacs_sync_decode: FAILED — 1 transcript differs from Tests/Platform/emacs-sync-upstream.expected"
                exit 1
            }
        else
            build_broken "emacs_sync_decode fixture build failed (see $OUT/emacs-fixture-build.log)"
        fi
    fi
fi

# neovim_sync_decode — the Neovim client decodes the stream the Emacs stanza
# above reads, produced by a Sync host connection. The Lua decoder retypes
# every field it walks, and nothing but a real stream can say whether the
# cursor it reports came from the cursor block. Needs nvim on PATH; skipped
# where it is absent.
if wanted neovim_sync_decode && command -v cmake >/dev/null 2>&1; then
    echo "=== neovim_sync_decode ==="
    if neovim_unusable="$(ubq_neovim_unusable_reason)"; then
        ubq_skip_unless_required nvim "$neovim_unusable"
        SKIPPED=$((SKIPPED + 1))
    else
        RAN=$((RAN + 1))
        NEOVIM_BUILD="$OUT/neovim-fixture"
        mkdir -p "$NEOVIM_BUILD"
        if NEOVIM_FIXTURE="$(ubq_sync_stream_fixture "$OUT/neovim-fixture-build.log")"; then
            "$NEOVIM_FIXTURE" "$NEOVIM_BUILD/attach.bin" "$NEOVIM_BUILD/update.bin" "$NEOVIM_BUILD/control.bin" "$NEOVIM_BUILD/pictures.bin" || exit 1
            nvim --headless -l "$ROOT/Tests/Platform/neovim_sync_decode_test.lua" \
                "$NEOVIM_BUILD/attach.bin" "$NEOVIM_BUILD/update.bin" "$NEOVIM_BUILD/control.bin" "$NEOVIM_BUILD/upstream.bin" "$NEOVIM_BUILD/pictures.bin" || exit 1
            # What the client sent, read by the host's own decoders: every
            # frame one the host takes, and the transcript the one recorded.
            if ! "$NEOVIM_FIXTURE" --verify "$NEOVIM_BUILD/upstream.bin" >"$NEOVIM_BUILD/upstream.txt"; then
                cat "$NEOVIM_BUILD/upstream.txt"
                echo "neovim_sync_decode: FAILED — $(grep -c '^REFUSED' "$NEOVIM_BUILD/upstream.txt") frame(s) the host refuses"
                exit 1
            fi
            diff -u "$ROOT/Tests/Platform/neovim_sync_upstream.expected" "$NEOVIM_BUILD/upstream.txt" || {
                echo "neovim_sync_decode: FAILED — 1 transcript differs from Tests/Platform/neovim_sync_upstream.expected"
                exit 1
            }
        else
            build_broken "neovim_sync_decode fixture build failed (see $OUT/neovim-fixture-build.log)"
        fi
    fi
fi

# emacs_live — the Emacs client against a daemon: it attaches through the
# bridge in batch, and what it sends is read by the host that serves it. Typed
# input run by a Return key event, a paste, its theme and a new size each come
# back on the screen, and the host's count of input written reaches the count
# sent. The daemon is this run's, in its scratch state directory, and ends
# with the session. Its shell is /bin/sh under a scratch HOME
# (ubq_with_hermetic_shell), so no hook of the person running the suite starts
# in it. Needs emacs on PATH; declined, saying so, where it is absent.
if wanted emacs_live; then
    echo "=== emacs_live ==="
    if ! command -v emacs >/dev/null 2>&1; then
        ubq_skip_unless_required emacs "emacs_live: emacs not installed"
        SKIPPED=$((SKIPPED + 1))
    else
        RAN=$((RAN + 1))
        if HOST_BINARY="$(ubq_host_binary "$OUT/emacs-live-host-build.log")"; then
            ubq_with_hermetic_shell emacs --batch -Q -l "$ROOT/Tests/Platform/emacs-live-check.el" "$HOST_BINARY" 10 || exit 1
        else
            build_broken "emacs_live host build failed (see $OUT/emacs-live-host-build.log)"
        fi
    fi
fi

# emacs_resume — the Emacs client across a restart: one Emacs attaches and
# exits without a Bye, a second draws the stored screen before its bridge
# starts, greets as the same client and is continued with a diff. The daemon
# is the check's own, under a scratch UBIQUITTY_HOME, and ends with the
# session the check exits.
if wanted emacs_resume; then
    echo "=== emacs_resume ==="
    if ! command -v emacs >/dev/null 2>&1; then
        ubq_skip_unless_required emacs "emacs_resume: emacs not installed"
        SKIPPED=$((SKIPPED + 1))
    else
        RAN=$((RAN + 1))
        if HOST_BINARY="$(ubq_host_binary "$OUT/emacs-resume-host-build.log")"; then
            # Keep the daemon socket within sockaddr_un::sun_path even when
            # the per-user TMPDIR is long.
            resume_scratch="$(mktemp -d /tmp/ubq-emacs-resume.XXXXXX)"
            mkdir -p "$resume_scratch/home"
            for phase in first second; do
                UBIQUITTY_HOME="$resume_scratch/home" emacs --batch -Q -l "$ROOT/Tests/Platform/emacs-sync-resume-check.el" \
                    "$HOST_BINARY" "$resume_scratch/state" "$phase" 10 || { rm -rf "$resume_scratch"; exit 1; }
            done
            rm -rf "$resume_scratch"
        else
            build_broken "emacs_resume host build failed (see $OUT/emacs-resume-host-build.log)"
        fi
    fi
fi

# neovim_live — the Neovim client against a daemon, as emacs_live is for
# Emacs: typed input, a paste and a new size come back on the screen, the
# host's count of input written reaches the count sent, and the echo context
# arrives. Needs nvim on PATH; declined, saying so, where it is absent.
if wanted neovim_live; then
    echo "=== neovim_live ==="
    if neovim_unusable="$(ubq_neovim_unusable_reason)"; then
        ubq_skip_unless_required nvim "neovim_live: $neovim_unusable"
        SKIPPED=$((SKIPPED + 1))
    else
        RAN=$((RAN + 1))
        if HOST_BINARY="$(ubq_host_binary "$OUT/neovim-live-host-build.log")"; then
            nvim --headless -l "$ROOT/Tests/Platform/neovim_live_check.lua" "$HOST_BINARY" 10 || exit 1
        else
            build_broken "neovim_live host build failed (see $OUT/neovim-live-host-build.log)"
        fi
    fi
fi

# neovim_resume — the Neovim client across a restart, as emacs_resume is for
# Emacs: the second Neovim draws the stored screen before its bridge delivers a
# byte, greets as the same client and is continued with a diff. The daemon is
# the check's own, under a scratch UBIQUITTY_HOME, and ends with the session.
if wanted neovim_resume; then
    echo "=== neovim_resume ==="
    if neovim_unusable="$(ubq_neovim_unusable_reason)"; then
        ubq_skip_unless_required nvim "neovim_resume: $neovim_unusable"
        SKIPPED=$((SKIPPED + 1))
    else
        RAN=$((RAN + 1))
        if HOST_BINARY="$(ubq_host_binary "$OUT/neovim-resume-host-build.log")"; then
            # Keep the daemon socket within sockaddr_un::sun_path even when
            # the per-user TMPDIR is long.
            resume_scratch="$(mktemp -d /tmp/ubq-neovim-resume.XXXXXX)"
            mkdir -p "$resume_scratch/home"
            for phase in first second; do
                UBIQUITTY_HOME="$resume_scratch/home" nvim --headless -l "$ROOT/Tests/Platform/neovim_resume_check.lua" \
                    "$HOST_BINARY" "$resume_scratch/state" "$phase" 10 || { rm -rf "$resume_scratch"; exit 1; }
            done
            rm -rf "$resume_scratch"
        else
            build_broken "neovim_resume host build failed (see $OUT/neovim-resume-host-build.log)"
        fi
    fi
fi

if wanted unwired_flags; then
    echo "=== unwired_flags ==="
    RAN=$((RAN + 1))
    python3 "$ROOT/Scripts/check-unwired-flags.py" --self-test || exit 1
    python3 "$ROOT/Scripts/check-unwired-flags.py" || exit 1
fi

# check-selection-bounds-callers compares a git grep against a record, so a tree
# that agrees and a search that matched nothing print alike. It refuses on an
# empty search rather than passing, and its self-test carries the same arm — the
# call-site count is what makes a clean verdict the tree's.
# check-sync-struct-defaults compares the header against a recorded residue, so a
# header whose shape changed and a header with nothing left print alike. It
# refuses on a parse that finds no struct, and its self-test proves the parser
# sees a field behind a trailing comment — the case that hid a whole struct from
# two earlier enumerations of this same fact.
# check-colour-slot-helper compares the arms against a recorded set, so a tree
# that lost the binding type and a tree where every arm holds print the same
# verdict. It refuses on a measurement of zero binders, and its self-test carries
# the same arm.
if wanted colour_slot_helper; then
    echo "=== colour_slot_helper ==="
    RAN=$((RAN + 1))
    python3 "$ROOT/Scripts/check-colour-slot-helper.py" --self-test || exit 1
    python3 "$ROOT/Scripts/check-colour-slot-helper.py" || exit 1
fi

# check-assertions-against-magic-bounds catches the assertion that measures the
# ENVIRONMENT rather than the behaviour — a zoom leg asserting the re-fitted grid
# was under 80 columns passed with the re-fit deleted, because the window was 54.
# It refuses on a root that is not in the tree rather than passing silently, and
# its self-test runs the reported defect through the pattern in both idioms plus
# three clean lines, so a pattern that stops matching is caught here.
if wanted assertions_against_magic_bounds; then
    echo "=== assertions_against_magic_bounds ==="
    RAN=$((RAN + 1))
    python3 "$ROOT/Scripts/check-assertions-against-magic-bounds.py" --self-test || exit 1
    python3 "$ROOT/Scripts/check-assertions-against-magic-bounds.py" || exit 1
fi

# Cached settings must notify the Swift window owner on every live edit.
if wanted settings_live_apply; then
    echo "=== settings_live_apply ==="
    RAN=$((RAN + 1))
    python3 "$ROOT/Scripts/check-settings-live-apply.py" --self-test || exit 1
    python3 "$ROOT/Scripts/check-settings-live-apply.py" || exit 1
fi

# check-tracking-area-owners reads the owners out of the tree rather than listing
# them, because the defect it catches is invisible in the reading: a Swift owner
# that spells the callbacks and answers no selector compiles clean and is skipped
# by AppKit in silence. It refuses on a tree with no tracking area at all, and
# its self-test runs the shipped shape of the defect through the judge.
if wanted tracking_area_owners; then
    echo "=== tracking_area_owners ==="
    RAN=$((RAN + 1))
    python3 "$ROOT/Scripts/check-tracking-area-owners.py" --self-test || exit 1
    python3 "$ROOT/Scripts/check-tracking-area-owners.py" || exit 1
fi

# check-renderer-arm-selection runs the shipping selector against a stand-in
# git rather than restating its table, because a second copy of the table would agree
# with itself forever. Selecting too few arms is invisible at push time — the
# stanza reports what it ran and passes — so this is the only place a selector
# that stopped matching can be caught.
if wanted renderer_arm_selection; then
    echo "=== renderer_arm_selection ==="
    RAN=$((RAN + 1))
    python3 "$ROOT/Scripts/check-renderer-arm-selection.py" --self-test || exit 1
    python3 "$ROOT/Scripts/check-renderer-arm-selection.py" || exit 1
fi

# check-test-only-operations compares the operations surface against a record,
# and a surface fully wired and a parse that stopped seeing the header print the
# same nothing — it refuses on an empty parse, and the self-test bounds the
# parser at ten declarations.
if wanted test_only_operations; then
    echo "=== test_only_operations ==="
    RAN=$((RAN + 1))
    python3 "$ROOT/Scripts/check-test-only-operations.py" --self-test || exit 1
    python3 "$ROOT/Scripts/check-test-only-operations.py" || exit 1
fi

if wanted selection_bounds_callers; then
    echo "=== selection_bounds_callers ==="
    RAN=$((RAN + 1))
    python3 "$ROOT/Scripts/check-selection-bounds-callers.py" --self-test || exit 1
    python3 "$ROOT/Scripts/check-selection-bounds-callers.py" || exit 1
fi

# Signing discovery uses mocked public certificate metadata and no Keychain writes.
if wanted apple_development_teams; then
    echo "=== apple_development_teams ==="
    RAN=$((RAN + 1))
    python3 "$ROOT/Scripts/test-apple-development-teams.py" || exit 1
fi

# The conformance wrappers must preserve normal consent unless the caller
# selects the isolated clipboard-read-only configuration. No app is launched.
if wanted esctest_security; then
    echo "=== esctest_security ==="
    RAN=$((RAN + 1))
    python3 "$ROOT/Scripts/test-esctest-security.py" || exit 1
fi

if wanted web_proxy_frames; then
    echo "=== web_proxy_frames ==="
    RAN=$((RAN + 1))
    python3 "$ROOT/Tests/test-web-proxy-frames.py" || exit 1
    python3 "$ROOT/Tests/test-web-launcher.py" || exit 1
fi

# The page is the one frontend no C++ test reaches: WebTerminal is portable and
# runs under ctest, terminal.js runs only in a browser. The probes under
# Tests/Web stand it up against a fixture and ask one question each.
#
# They are here rather than left as manual tools because a probe nothing runs
# rots, and rots quietly: live-reconnect.mjs threw inside its own fixture for
# long enough that nobody knows how long, reporting it as "the page never opened
# a socket" — which is also what the defect it watches for looks like.
#
# Each prerequisite is a decline rather than a failure. A missing web build is
# the common one: build-web.sh needs emscripten, which a host-only checkout has
# no reason to have.
# shellcheck source=Scripts/build-provenance.sh
. "$CORE_ROOT/Scripts/build-provenance.sh"
ubq_web_probe_ready() {
    UBQ_WEB_DIST="$UBQ_BUILD_ROOT/web-dist"
    if ! command -v node >/dev/null 2>&1; then
        ubq_skip "$1: no node, which runs the page"
        SKIPPED=$((SKIPPED + 1))
        return 1
    fi
    if [ ! -f "$UBQ_WEB_DIST/terminal.js" ]; then
        ubq_skip "$1: no staged page at $UBQ_WEB_DIST (Scripts/build-web.sh)"
        SKIPPED=$((SKIPPED + 1))
        return 1
    fi
    # Nothing here rebuilds the stage, so a page staged from other bytes would
    # be driven and its verdict reported against this tree.
    if ! build_provenance_current "$ROOT" "$UBQ_BUILD_ROOT/web" "$1"; then
        echo "$1: the page at $UBQ_WEB_DIST was staged from another tree; rebuild it with Scripts/build-web.sh" >&2
        exit 1
    fi
    return 0
}

# Needs the staged page and nothing else: it drives the page against the fixture
# with no host at all, which is the whole of what it asserts.
if wanted web_page_smoke; then
    echo "=== web_page_smoke ==="
    if ubq_web_probe_ready web_page_smoke; then
        RAN=$((RAN + 1))
        node "$ROOT/Tests/Web/page-smoke.mjs" "$UBQ_WEB_DIST" || exit 1
    fi
fi

# The module's own render of a selection over a scaled proportional run, read
# back from the PNG the snapshot arm writes: the last letter is lit through its
# ink, on every band row. No C++ test sees the pixels; the page draws what the
# module hands it, so the module's frame is the page's.
if wanted web_scaled_run_selection; then
    echo "=== web_scaled_run_selection ==="
    if ubq_web_probe_ready web_scaled_run_selection; then
        RAN=$((RAN + 1))
        node "$ROOT/Tests/Web/scaled-run-selection.mjs" "$UBQ_WEB_DIST" || exit 1
    fi
fi

# web_outline_rows — the page's renderer for a session outline's rows, drawn
# into a stand-in document from the rows Core spells (which
# test_session_outline_text holds to App::outlineJSON). It reads the source and
# needs no built page, only node; declined, saying so, where node is absent.
if wanted web_outline_rows; then
    echo "=== web_outline_rows ==="
    if ! command -v node >/dev/null 2>&1; then
        ubq_skip_unless_required node "web_outline_rows: node not installed"
        SKIPPED=$((SKIPPED + 1))
    else
        RAN=$((RAN + 1))
        UBIQUITTY_CORE_SOURCE_DIR="$CORE_ROOT" node "$ROOT/Tests/Web/outline-rows.mjs" || exit 1
    fi
fi

# Executes the page's source functions with controlled browser promises; no
# WASM build, host, or access to the machine clipboard is required.
if wanted web_clipboard_promises; then
    echo "=== web_clipboard_promises ==="
    if ! command -v node >/dev/null 2>&1; then
        ubq_skip_unless_required node "web_clipboard_promises: node not installed"
        SKIPPED=$((SKIPPED + 1))
    else
        RAN=$((RAN + 1))
        node "$ROOT/Tests/Web/clipboard-promises.mjs" || exit 1
    fi
fi

# These need a host to talk to, which Tests/test-web-live-probe.sh stands up
# and tears down around them: the Host frontend the host stanzas run, asked for
# once the page is known to be there, so a checkout with no staged page builds
# nothing for it.
#
# Written out rather than looped, because the name has to be a literal here:
# Scripts/stanza-declarations.awk reads this file to answer --list-stanzas, and
# CMake reads that list to give each stanza its own ctest entry. A name built
# from a variable runs only when the whole suite does, and cannot be asked for.
if wanted web_live_reconnect; then
    echo "=== web_live_reconnect ==="
    if ubq_web_probe_ready web_live_reconnect; then
        HOST_BINARY="$(ubq_host_binary "$OUT/web-live-reconnect-host-build.log")" \
            || build_broken "web_live_reconnect: ubiquitty-host did not build (see $OUT/web-live-reconnect-host-build.log)"
        RAN=$((RAN + 1))
        "$ROOT/Tests/test-web-live-probe.sh" "$HOST_BINARY" "$UBQ_WEB_DIST" \
            "$ROOT/Tests/Web/live-reconnect.mjs" || exit 1
    fi
fi

# web_reload_resume — the page across a reload: the second page draws the
# stored picture before its first socket and greets as the same window.
if wanted web_reload_resume; then
    echo "=== web_reload_resume ==="
    if ubq_web_probe_ready web_reload_resume; then
        HOST_BINARY="$(ubq_host_binary "$OUT/web-reload-resume-host-build.log")" \
            || build_broken "web_reload_resume: ubiquitty-host did not build (see $OUT/web-reload-resume-host-build.log)"
        RAN=$((RAN + 1))
        "$ROOT/Tests/test-web-live-probe.sh" "$HOST_BINARY" "$UBQ_WEB_DIST" \
            "$ROOT/Tests/Web/reload-resume.mjs" || exit 1
    fi
fi

if wanted web_refused_reconnect; then
    echo "=== web_refused_reconnect ==="
    if ubq_web_probe_ready web_refused_reconnect; then
        HOST_BINARY="$(ubq_host_binary "$OUT/web-refused-reconnect-host-build.log")" \
            || build_broken "web_refused_reconnect: ubiquitty-host did not build (see $OUT/web-refused-reconnect-host-build.log)"
        RAN=$((RAN + 1))
        "$ROOT/Tests/test-web-live-probe.sh" "$HOST_BINARY" "$UBQ_WEB_DIST" \
            "$ROOT/Tests/Web/refused-reconnect.mjs" || exit 1
    fi
fi

# The app's tool contracts, run against fixture bundles and stand-in tools: the
# macOS installer, the bundle's licence notices and Sparkle's fetch. Tests/Tools
# holds the others of the app's tool tests, which no driver runs.
if wanted test_app_tools; then
    echo "=== test_app_tools ==="
    RAN=$((RAN + 1))
    python3 "$ROOT/Tests/Tools/test_install_macos.py" || exit 1
    python3 "$ROOT/Tests/Tools/test_bundle_resources.py" || exit 1
    python3 "$ROOT/Tests/Tools/test_fetch_sparkle.py" || exit 1
    python3 "$ROOT/Tests/Tools/test_test_routing.py" || exit 1
    python3 "$ROOT/Tests/Tools/test_package_notices.py" || exit 1
    python3 "$ROOT/Tests/Tools/test_release_ci.py" || exit 1
fi
