#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Print teams from usable Apple signing certificates, without changing Keychain."""

import base64
import hashlib
import re
import subprocess


def readCommand(arguments, inputBytes=None):
    """Read public metadata; missing tools or refused queries yield no selection."""
    try:
        result = subprocess.run(arguments, input=inputBytes, capture_output=True,
                                check=False, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout if result.returncode == 0 else None


def developmentTeams(run=readCommand):
    """Resolve each usable identity's exact certificate before reading its OU."""
    identities = run(["security", "find-identity", "-v", "-p", "codesigning"])
    if identities is None:
        return []
    teams = set()
    for match in re.finditer(
            rb'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(Apple Develop[^"\r\n]*)"',
            identities, re.MULTILINE):
        fingerprint = match[1].decode("ascii").lower()
        name = match[2].decode("utf-8", errors="strict")
        certificates = run(["security", "find-certificate", "-a", "-c", name, "-p"])
        if certificates is None:
            continue
        for certificate in re.findall(
                rb'-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\r\n]+)-----END CERTIFICATE-----',
                certificates):
            try:
                der = base64.b64decode(re.sub(rb'\s+', b'', certificate), validate=True)
            except ValueError:
                continue
            if hashlib.sha1(der).hexdigest() != fingerprint:
                continue
            subject = run(["openssl", "x509", "-inform", "DER", "-noout", "-subject",
                           "-nameopt", "sep_multiline,sname"], der)
            if subject is None:
                continue
            units = re.findall(rb'^\s*OU\s*=\s*([A-Z0-9]{10})\s*$', subject, re.MULTILINE)
            if len(units) == 1:
                teams.add(units[0].decode("ascii"))
    return sorted(teams)


if __name__ == "__main__":
    for team in developmentTeams():
        print(team)
