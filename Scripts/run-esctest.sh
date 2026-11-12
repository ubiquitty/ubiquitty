#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# run-esctest.sh — grade a macOS Ubiquitty build with the esctest2 suite.
#
# esctest2 writes control sequences to the PTY it was started on and reads the
# screen back through DECRQCRA checksums, so it grades the cells the terminal
# holds rather than whether a sequence has a handler. That works only with the
# suite running as the terminal's own child, so the app is started with `-e`
# and runs the suite where its login shell would be.
#
# Options:
#   --app PATH                the bundle to test; without it, the first
#                             Ubiquitty.app under the macOS build directory
#   --esctest PATH            the esctest2 checkout to run
#   --expected-terminal NAME  handed to esctest; xterm unless given
#   --allow-clipboard-read    use an isolated read-only grant
#   -- ARGS...                handed to esctest as they are, e.g. -- --include DECRQM
#
# Everything a run writes goes to BuildEsctest/, which git ignores, and none of
# it belongs in the repository. A pass count means little without the app, its
# version, the suite commit and the arguments behind it, so every run writes
# those to esctest-provenance.txt next to the log.
#
# esctest.py's first line asks env for `python`, which macOS stopped shipping
# in 12.3. Started directly, it dies inside env before the terminal sees a
# byte, which looks like a terminal crash; this script always names python3.

set -euo pipefail

repoRoot="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/library-scripts.sh
. "$repoRoot/Scripts/library-scripts.sh"
resultsDir="$repoRoot/BuildEsctest"

# Prints each argument on a line of its own to stderr, then exits with status 1.
refuse() {
    printf '%s\n' "$@" >&2
    exit 1
}

# The comment block under the licence header is the usage text.
printUsage() {
    awk 'NR > 4 { if (!/^#/) exit; print }' "${BASH_SOURCE[0]}"
}

bundle=""
# Resolution order: --esctest flag, then $ESCTEST2_DIR, then $UBIQUITTY_ESCTEST,
# then ~/Projects/esctest2, then a checkout under the repo (vendor/ or Tools/).
suiteDir="${ESCTEST2_DIR:-}"
terminalName=xterm
forwarded=()
# Consent remains normal unless this run explicitly selects the narrow test file.
allowsClipboardRead=0

while (($# > 0)); do
    case "$1" in
        --allow-clipboard-read) allowsClipboardRead=1; shift ;;
        --app) bundle="$2"; shift 2 ;;
        --esctest) suiteDir="$2"; shift 2 ;;
        --expected-terminal) terminalName="$2"; shift 2 ;;
        --) shift; forwarded=("$@"); break ;;
        -h|--help) printUsage; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [[ -z "$bundle" ]]; then
    # Build output lives outside the checkout on a machine that redirects it;
    # see Scripts/build-root.sh. Searching the in-tree path alone found nothing
    # there, and the suite then reported "no verdict" — a path miss wearing a
    # conformance failure's clothes. The in-tree path stays as the fallback for
    # a checkout that builds in place.
    # shellcheck source=Scripts/build-root.sh
    . "$CORE_ROOT/Scripts/build-root.sh"
    for candidate in "${UBQ_BUILD_ROOT:-}/macos" "$repoRoot/build/macos"; do
        [[ -n "$candidate" && -d "$candidate" ]] || continue
        bundle="$(find "$candidate" -maxdepth 4 -name 'Ubiquitty.app' -print -quit 2>/dev/null || true)"
        [[ -n "$bundle" ]] && break
    done
fi
[[ -n "$bundle" && -d "$bundle" ]] ||
    refuse "error: no Ubiquitty.app to test. Pass --app, or build one with ./Scripts/build-macos.sh."

executable="$bundle/Contents/MacOS/Ubiquitty"
[[ -x "$executable" ]] || refuse "error: $executable is missing or cannot be executed"

if [[ -z "$suiteDir" ]]; then
    # `UBIQUITTY_ESCTEST` and the `~/Projects/esctest2` default are where
    # run-linux.sh looks for the same checkout, and one checkout found two ways
    # is a checkout the two runners can disagree about.
    for candidate in "${UBIQUITTY_ESCTEST:-}" "$HOME/Projects/esctest2" \
        "$repoRoot/vendor/esctest2" "$repoRoot/Tools/esctest2"; do
        [[ -n "$candidate" && -f "$candidate/esctest/esctest.py" ]] || continue
        suiteDir="$candidate"
        break
    done
fi

if [[ -z "$suiteDir" || ! -f "$suiteDir/esctest/esctest.py" ]]; then
    cat >&2 <<'EOF'
error: no esctest2 checkout to run.

Name one with any of:
  --esctest <path>          on the command line
  ESCTEST2_DIR=<path>       in the environment, which skips the search below
  UBIQUITTY_ESCTEST=<path>  same; run-linux.sh reads this one too
  ~/Projects/esctest2       the default checkout location
  vendor/esctest2           inside this repository; Tools/esctest2 works too

To get the suite:
  git clone https://github.com/ThomasDickey/esctest2 vendor/esctest2
EOF
    exit 1
fi
suiteMain="$suiteDir/esctest/esctest.py"

interpreter="$(command -v python3 || true)"
[[ -n "$interpreter" ]] ||
    refuse "error: esctest needs python3 on PATH; the \`python\` its own first line asks for is absent from current macOS"

mkdir -p "$resultsDir"
suiteLog="$resultsDir/esctest.log"
provenanceFile="$resultsDir/esctest-provenance.txt"
consentPosture='normal policy (prompts can time out)'
testConfiguration='(none; normal user configuration)'
unset UBIQUITTY_UNATTENDED
if [[ "$allowsClipboardRead" = 1 ]]; then
    # A separate XDG directory keeps both this grant and app writes out of the
    # person's configuration. Retain it with the run's provenance for inspection.
    testConfigRoot="$(mktemp -d "$resultsDir/config.XXXXXX")"
    mkdir -p "$testConfigRoot/ubiquitty"
    testConfiguration="$testConfigRoot/ubiquitty/config.toml"
    cp "$repoRoot/Tests/Esctest/clipboard-read.toml" "$testConfiguration"
    export XDG_CONFIG_HOME="$testConfigRoot"
    consentPosture='isolated test configuration: clipboard_read=allow only'
fi

# Prints what the command prints, or `unknown` when it fails.
orUnknown() {
    "$@" 2>/dev/null || echo unknown
}
bundleVersion="$(orUnknown defaults read "$bundle/Contents/Info.plist" CFBundleShortVersionString)"
treeCommit="$(orUnknown git -C "$repoRoot" rev-parse --short HEAD)"
suiteCommit="$(orUnknown git -C "$suiteDir" rev-parse --short HEAD)"

# One fact per line, its value in a column of its own.
recordFact() {
    printf '%-19s %s\n' "$1" "$2"
}
# Written before the suite starts: a score is not a result without these, and a
# run that never finishes still leaves the record of what it attempted.
{
    recordFact target-app "$bundle"
    recordFact target-version "$bundleVersion"
    recordFact target-commit "$treeCommit"
    recordFact suite "esctest2 $suiteDir"
    recordFact suite-commit "$suiteCommit"
    recordFact interpreter "$interpreter ($("$interpreter" -V 2>&1))"
    recordFact expected-terminal "$terminalName"
    recordFact consent-posture "$consentPosture"
    recordFact test-configuration "$testConfiguration"
    recordFact extra-args "${forwarded[*]:-(none)}"
    recordFact machine "$(sysctl -n hw.model 2>/dev/null || uname -m)"
    recordFact os "$(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
} | tee "$provenanceFile"

printf '\nesctest2 runs inside %s in a window of its own; leave that window alone until the run ends\n' "$bundle"

rm -f "$suiteLog"

suiteCommand=("$interpreter" "$suiteMain" --expected-terminal="$terminalName" --logfile="$suiteLog" --no-print-logs)
"$executable" -e "${suiteCommand[@]}" ${forwarded+"${forwarded[@]}"} &
launcherPid=$!

# The suite must prove it started, and the proof has to be something the
# launcher cannot fake. An unrecognised argument does not stop the app: it falls
# through to a normal launch and opens a window running the login shell, so a
# binary that ignores `-e` looks exactly like one that accepted it. The log file
# is the discriminator — only esctest.py creates it.
#
# Waiting on `pgrep -f esctest.py` instead is a trap: the
# launcher's OWN command line contains that string, so the pattern matches the
# process that was supposed to start the suite and the loop never ends.
startDeadline=$((SECONDS + 45))
while [ ! -s "$suiteLog" ]; do
    if ! kill -0 "$launcherPid" 2>/dev/null; then
        break
    fi
    if [ "$SECONDS" -ge "$startDeadline" ]; then
        kill "$launcherPid" 2>/dev/null || true
        cat >&2 <<EOF
error: $executable did not start the suite.

The app took the launch but never ran esctest.py — no $suiteLog was created.
That is what an unrecognised '-e' looks like: the flag is ignored, the app
opens an ordinary login-shell window, and nothing reports an error.

Check that the target implements '-e <program> [args…]' to run a command in
place of the login shell:

  grep -n -- 'parseLaunchArguments' Source/Core/Runtime/LaunchArguments.h
EOF
        exit 1
    fi
    sleep 1
done

while kill -0 "$launcherPid" 2>/dev/null; do sleep 2; done

echo
if ! grep -q "tests passed" "$suiteLog" 2>/dev/null; then
    printf '%s\n' "error: the suite stopped before its summary; $suiteLog has no \"tests passed\" line" \
        "its last lines:" >&2
    tail -n 5 "$suiteLog" >&2 || true
    exit 1
fi
# The summary line, then the list of failing cases that follows it.
sed -n '/tests passed/,$p' "$suiteLog"
printf '\nprovenance: %s\nfull log:   %s\n' "$provenanceFile" "$suiteLog"
