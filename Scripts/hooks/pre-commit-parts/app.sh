#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# The pre-commit gates whose subject is the app: the web page, the frontends'
# capability policy, the healing frame and the entry points' flags. Sourced by
# Scripts/hooks/pre-commit after its own gates, with its ROOT, CORE_SCRIPTS and
# runGate.

if ! runGate python3 "$ROOT/Scripts/check-unwired-flags.py"; then
    {
        echo
        echo "pre-commit: a flag is read by an entry point and spelled nowhere else."
        echo "  Those entry points are driven by scripts and cases, so a flag no script"
        echo "  passes reaches its code in no run — and a gate reading that code's output"
        echo "  reports agreement about a lane nothing fed. Wire it, or record it in"
        echo "  Tests/unwired-flags.txt with which of the two it is."
    } >&2
    exit 1
fi

if ! runGate python3 "$ROOT/Scripts/check-web-fixture.py"; then
    {
        echo
        echo "pre-commit: a Tests/Web probe builds a browser of its own (above)."
        echo "  The copies drift, and the probe nobody runs drifts furthest: one"
        echo "  threw inside its own fixture for long enough that nobody knows how"
        echo "  long, and reported it as the page never opening a socket."
    } >&2
    exit 1
fi

if ! runGate python3 "$ROOT/Scripts/check-web-host-bytes.py"; then
    {
        echo
        echo "pre-commit: the Web page routes host bytes into its parser (above)."
        echo "  The page stamps CapabilityOrigin::Local on everything its parser"
        echo "  sees, which is true only while that is its own bytes. Host bytes"
        echo "  belong to feedFromHost and SyncClientCore, which runs no gate."
    } >&2
    exit 1
fi

if ! runGate python3 "$ROOT/Scripts/check-frontend-capability-policy.py"; then
    {
        echo
        echo "pre-commit: a module wires a Terminal client and installs no policy (above)."
        echo "  A null capabilityPolicy is not the module's answer. Core falls back to"
        echo "  PAL's defaultDecision, which allows Local everything and keeps Remote's"
        echo "  benign effects, and nothing else here would report it."
        echo "  Install one the way Source/Platform/Linux/CapabilityPolicy.h does, or"
        echo "  record the module in the script's KNOWN_OPEN with the reason."
    } >&2
    exit 1
fi

if ! runGate python3 "$ROOT/Scripts/check-web-parser-entries.py"; then
    {
        echo
        echo "pre-commit: the web page's parser gained an entry, or lost a recorded one (above)."
        echo "  Web is the one frontend that both parses bytes itself and attaches to a"
        echo "  host. Those coexist only while \`feedFromHost\` stays out of the parser:"
        echo "  it decodes frames into SyncClientCore, so host content reaches no gate"
        echo "  site and CapabilityOrigin::Local is true rather than merely default."
        echo "  Route host bytes through processBytes and every gate there answers for"
        echo "  a principal the wire never carried."
    } >&2
    exit 1
fi

if ! runGate python3 "$ROOT/Scripts/check-healing-frame-pair.py"; then
    {
        echo
        echo "pre-commit: an incrementally painted row and a wholly painted one"
        echo "  disagree (above). The two cases end with identical cells and differ"
        echo "  only in which frame painted them, so reuse changed the result rather"
        echo "  than the work. Render both and look at the pair before re-minting:"
        echo "  a re-mint of one side records the defect as the expectation."
    } >&2
    exit 1
fi
