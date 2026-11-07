#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# run-macos-signed-resume.sh — the remote window restart, team-signed.
#
# Builds the UI-test app signed with the development team, so it carries the
# keychain access group the sealed resume record needs, and runs the two
# scenarios that answer for it against the real protected keychain:
#
#   sealed_resume_store_answers_as_the_signature_says
#       the keychain probe: a team-signed app keeps a key in the data
#       protection keychain (SecItemAdd answers errSecSuccess, 0);
#   remote_window_resumes_across_an_application_restart
#       two app processes against one local daemon: the stored picture is
#       drawn before the first packet, the window greets as the same client
#       instance, and the host continues the attachment with a diff.
#
# Run it in Terminal, in the logged-in session: codesign reaches the login
# keychain's signing identity there and not from an ssh or agent session
# (errSecInternalComponent). One command from the repository root:
#
#   ./Scripts/run-macos-signed-resume.sh
#
# Needs an "Apple Development" (or "Developer ID Application") identity of the
# team, and a macOS provisioning profile for the UI-test app's identifier
# (org.ubiquitty.Ubiquitty.uitest) or the team's wildcard, with Keychain
# Sharing; build-macos.sh finds it under ~/Library, or takes
# UBIQUITTY_PROVISIONING_PROFILE. UBIQUITTY_TEAM_ID overrides the team and
# UBIQUITTY_SIGN_IDENTITY the identity.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The checkouts holding the scripts this one runs; see CMakeLists.txt.
CORE_ROOT="${UBIQUITTY_CORE_SOURCE_DIR:-$ROOT/Libraries/ubiquitty-core}"
export UBIQUITTY_TEAM_ID="${UBIQUITTY_TEAM_ID:-5TC8J8TCS3}"

# The team's identity: the first code-signing certificate whose organizational
# unit is the team.
team_of() { # <identity>
    security find-certificate -c "$1" -p 2>/dev/null \
        | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
        | sed -n 's/^ *organizationalUnitName *= *\([A-Z0-9]\{10\}\)$/\1/p' | head -1
}
if [ -z "${UBIQUITTY_SIGN_IDENTITY:-}" ]; then
    while IFS= read -r identity; do
        if [ "$(team_of "$identity")" = "$UBIQUITTY_TEAM_ID" ]; then
            UBIQUITTY_SIGN_IDENTITY="$identity"
            break
        fi
    done < <(security find-identity -v -p codesigning 2>/dev/null \
        | sed -En 's/.*"((Apple Development|Developer ID Application): [^"]*)".*/\1/p')
fi
if [ -z "${UBIQUITTY_SIGN_IDENTITY:-}" ]; then
    echo "run-macos-signed-resume: no code-signing identity of team $UBIQUITTY_TEAM_ID is installed." >&2
    echo "  Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Apple Development, then run this again." >&2
    exit 1
fi
export UBIQUITTY_SIGN_IDENTITY
echo "run-macos-signed-resume: signing with \"$UBIQUITTY_SIGN_IDENTITY\" (team $UBIQUITTY_TEAM_ID)."

"$ROOT/Scripts/run-ui-tests.sh" \
    sealed_resume_store_answers_as_the_signature_says \
    remote_window_resumes_across_an_application_restart \
    | tee "${TMPDIR:-/tmp}/ubq-signed-resume.log"
status="${PIPESTATUS[0]}"

# What the run was signed with, so the result names the signature it answers for.
. "$CORE_ROOT/Scripts/build-root.sh"
APP="${UBIQUITTY_BUILD_DIR:-$UBQ_BUILD_ROOT/macos-uitest}/Source/Platform/macOS/Ubiquitty.app"
echo "--- signature"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Authority)=' || true
codesign -d --entitlements - "$APP" 2>/dev/null | grep -A2 'keychain-access-groups' || echo "(no keychain access group: the run used no team entitlement)"
echo "--- probe"
grep -E '^remote-resume (probe|restart):' "${TMPDIR:-/tmp}/ubq-signed-resume.log" || true
exit "$status"
