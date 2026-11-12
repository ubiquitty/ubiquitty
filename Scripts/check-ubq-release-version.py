#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Check the packaged client's release version through its MCP handshake."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary, expected = sys.argv[1:]
request = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "release-check", "version": "1"}}}
with tempfile.TemporaryDirectory(prefix="ubq-release-version-") as temporary:
    environment = dict(os.environ, HOME=temporary, UBIQUITTY_HOME=str(Path(temporary) / "host"))
    result = subprocess.run([binary, "mcp"], input=json.dumps(request) + "\n", capture_output=True,
                            text=True, env=environment, timeout=15, check=True)
replies = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
version = next(reply["result"]["serverInfo"]["version"] for reply in replies if reply.get("id") == 1)
if version != expected:
    raise SystemExit(f"packaged ubq reports {version}, expected App release {expected}")
print(f"packaged ubq MCP version: {version}")
