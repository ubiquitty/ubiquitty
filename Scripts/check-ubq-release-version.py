#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Check the packaged client's release version through its MCP handshake."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def check(binary, expected):
    request = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "release-check", "version": "1"}}}
    with tempfile.TemporaryDirectory(prefix="ubq-release-version-") as temporary:
        environment = dict(os.environ, HOME=temporary, UBIQUITTY_HOME=str(Path(temporary) / "host"))
        result = subprocess.run([binary, "mcp"], input=json.dumps(request) + "\n", capture_output=True,
                                text=True, env=environment, timeout=15, check=True)
    replies = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    version = next((reply.get("result", {}).get("serverInfo", {}).get("version")
                    for reply in replies if reply.get("id") == 1), None)
    if version != expected:
        raise ValueError(f"packaged ubq reports {version}, expected App release {expected}")
    print(f"packaged ubq MCP version: {version}")


def self_test():
    with tempfile.TemporaryDirectory(prefix="ubq-version-selftest-") as directory:
        binary = Path(directory) / "ubq"
        for reported, identifier, succeeds in (("0.4.0", 1, True), ("0.3.4", 1, False), ("0.4.0", 2, False)):
            reply = json.dumps({"id": identifier, "result": {"serverInfo": {"version": reported}}})
            binary.write_text("#!/bin/sh\n[ \"$1\" = mcp ] || exit 1\n"
                              "[ \"$UBIQUITTY_HOME\" = \"$HOME/host\" ] || exit 1\n"
                              "printf '%s\\n' '" + reply + "'\n")
            binary.chmod(0o700)
            try:
                check(str(binary), "0.4.0")
            except ValueError:
                if succeeds:
                    raise
            else:
                if not succeeds:
                    raise ValueError("self-test accepted a wrong version or handshake")
    print("check-ubq-release-version --self-test: ok (version, handshake and isolated home)")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        else:
            check(*sys.argv[1:])
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"check-ubq-release-version: {error}", file=sys.stderr)
        sys.exit(1)
