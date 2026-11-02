#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# make-signing-cert.sh — create a self-signed code-signing identity for Ubiquitty.
#
# build-macos.sh auto-signs Ubiquitty.app with a code-signing cert named
# "Ubiquitty Dev" when one is present, else it falls back to ad-hoc (and macOS
# re-prompts for folder access every rebuild). This is the command-line
# equivalent of Keychain Access ▸ Certificate Assistant ▸ Create a Certificate
# (Self Signed Root, Code Signing).
#
# A self-signed cert gives a STABLE code identity so TCC grants persist across
# rebuilds. It does not satisfy Gatekeeper on anyone else's Mac — for clean
# distribution you need an Apple Developer ID + notarization.
#
#   ./Scripts/make-signing-cert.sh                   create "Ubiquitty Dev"
#   NAME="My Name" ./Scripts/make-signing-cert.sh    custom common name
#
set -euo pipefail

NAME="${NAME:-Ubiquitty Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
DAYS=3650

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "A certificate named \"$NAME\" already exists in the login keychain."
    echo "  Delete it first: security delete-certificate -c \"$NAME\""
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
# A non-empty passphrase avoids a MAC-verification quirk in `security import`.
PASS="ubiquitty-transient"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS" 2>/dev/null

# Import key+cert into the login keychain; -T lets codesign use the private key.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Trust the self-signed root for code signing so it counts as a *valid* identity
# (security find-identity -v -p codesigning) and build-macos.sh auto-picks it.
# This pops a one-time keychain dialog — enter your login password to allow it.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "✓ Code-signing identity \"$NAME\" created and trusted."
    echo "  Rebuild and it gets signed automatically:  ./Scripts/build-macos.sh"
else
    echo "Created \"$NAME\" but it is not yet a valid codesigning identity."
    echo "  Inspect: security find-identity -v -p codesigning"
fi
