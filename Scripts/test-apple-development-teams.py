#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Exercise signing discovery with public-metadata fixtures, never real Keychain."""

import base64
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import unittest


scripts = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("teams", scripts / "apple-development-teams.py")
teams = importlib.util.module_from_spec(spec)
spec.loader.exec_module(teams)


class SigningTeamsTests(unittest.TestCase):
    def setUp(self):
        self.records = []
        self.calls = []

    def certificate(self, suffix="PERSON1234", team="TEAM567890", der=b"fixture certificate"):
        name = f"Apple Development: Fixture ({suffix})"
        fingerprint = hashlib.sha1(der).hexdigest().upper()
        pem = b"-----BEGIN CERTIFICATE-----\n" + base64.b64encode(der) + b"\n-----END CERTIFICATE-----\n"
        self.records.append({"name": name, "fingerprint": fingerprint,
                             "pem": pem, "der": der,
                             "subject": f"subject=\n    CN={name}\n    OU={team}\n".encode()})
        return self.records[-1]

    def runCommand(self, arguments, inputBytes=None):
        self.calls.append((arguments, inputBytes))
        if arguments[1] == "find-identity":
            return b"\n".join(f'  {index}) {record["fingerprint"]} "{record["name"]}"'.encode()
                              for index, record in enumerate(self.records, 1))
        if arguments[1] == "find-certificate":
            return next(record["pem"] for record in self.records if record["name"] == arguments[4])
        self.assertEqual(arguments, ["openssl", "x509", "-inform", "DER", "-noout", "-subject",
                                     "-nameopt", "sep_multiline,sname"])
        return next(record["subject"] for record in self.records if record["der"] == inputBytes)

    def testTeamComesFromSubjectNotDeveloperSuffix(self):
        self.certificate()
        self.assertEqual(teams.developmentTeams(self.runCommand), ["TEAM567890"])

    def testOnlyTheExactUsableCertificateIsRead(self):
        record = self.certificate()
        record["pem"] = b"-----BEGIN CERTIFICATE-----\n" + base64.b64encode(b"different certificate") + b"\n-----END CERTIFICATE-----\n" + record["pem"]
        self.assertEqual(teams.developmentTeams(self.runCommand), ["TEAM567890"])
        self.assertEqual(sum(call[0][0] == "openssl" for call in self.calls), 1)

    def testMismatchedFingerprintDoesNotSelectATeam(self):
        self.certificate()["fingerprint"] = "0" * 40
        self.assertEqual(teams.developmentTeams(self.runCommand), [])
        self.assertFalse(any(call[0][0] == "openssl" for call in self.calls))

    def testMissingOrAmbiguousTeamDoesNotUseCommonName(self):
        record = self.certificate()
        for subject in (b"subject=\n CN=Fixture (PERSON1234)\n",
                        b"subject=\n OU=short\n", b"subject=\n OU=TEAM567890\n OU=OTHER12345\n"):
            with self.subTest(subject=subject):
                record["subject"] = subject
                self.assertEqual(teams.developmentTeams(self.runCommand), [])

    def testMultipleTeamsStayDistinctAndDuplicateTeamCoalesces(self):
        self.certificate(suffix="PERSON0001", team="TEAM000001", der=b"one")
        self.certificate(suffix="PERSON0002", team="TEAM000002", der=b"two")
        self.certificate(suffix="PERSON0003", team="TEAM000001", der=b"three")
        self.assertEqual(teams.developmentTeams(self.runCommand), ["TEAM000001", "TEAM000002"])

    def testUnavailableCommandsAndMalformedCertificatesYieldNoSelection(self):
        self.assertEqual(teams.developmentTeams(lambda *args: None), [])
        record = self.certificate()
        for certificate in (None, b"not a certificate", b"-----BEGIN CERTIFICATE-----\nA\n-----END CERTIFICATE-----\n"):
            record["pem"] = certificate
            self.assertEqual(teams.developmentTeams(self.runCommand), [])

    def testUnrelatedSigningIdentityIsNotQueried(self):
        self.certificate()["name"] = "Unrelated Dev"
        self.assertEqual(teams.developmentTeams(self.runCommand), [])
        self.assertEqual(len(self.calls), 1)

    def testExplicitTeamBypassesDiscovery(self):
        source = (scripts / "generate-xcode-workspace.sh").read_text()
        begin = source.index('if [ -z "${UBIQUITTY_DEVELOPMENT_TEAM:-}" ]; then')
        end = source.index("\ngenerateFrontend()", begin)
        # The real discovery block would try a nonexistent helper if the
        # explicit override failed to short-circuit. No Keychain command runs.
        script = 'set -eu\nroot=/nonexistent-signing-fixture\n' + source[begin:end]
        script += '\nprintf "%s" "$UBIQUITTY_DEVELOPMENT_TEAM"\n'
        environment = dict(os.environ, UBIQUITTY_DEVELOPMENT_TEAM="EXPLICIT12")
        result = subprocess.run(["bash", "-c", script], capture_output=True,
                                text=True, env=environment, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "EXPLICIT12")


if __name__ == "__main__":
    unittest.main()
