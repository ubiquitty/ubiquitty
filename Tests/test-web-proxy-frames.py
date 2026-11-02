#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""test-web-proxy-frames.py — the browser proxy forwards data, answers control,
and admits only the page it serves.

Scripts/web-proxy.py sits between a page's WebSocket and the daemon's socket and
writes what it reads straight through. A WebSocket frame carries an opcode, and
only the data ones carry Sync bytes: a control frame's payload belongs to the
WebSocket layer — a keepalive body, a close reason — and writing it to the daemon
puts those bytes in the middle of the client's frame stream, where the daemon
reads the next five as a header and either refuses the client or drops it. Any
intermediary in front of the page can send one.

The proxy is development scaffolding, which is why it had no test; the framing it
speaks is still a protocol, and this is the part of it a reader cannot check by
looking.
"""

import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
from unittest.mock import MagicMock, patch

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

spec = importlib.util.spec_from_file_location("webproxy", os.path.join(ROOT, "Scripts", "web-proxy.py"))
webproxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(webproxy)
sys.path.insert(0, os.path.join(ROOT, 'Scripts'))
import web_connections

failures = []


def check(ok, what):
    if not ok:
        failures.append(what)


class FakeConnection:
    """One client frame to read, and whatever the proxy writes back."""

    def __init__(self, opcode, payload, mask=b"\xAA\xBB\xCC\xDD"):
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.inbound = bytes([0x80 | opcode, 0x80 | len(payload)]) + mask + masked
        self.at = 0
        self.written = b""

    def recv(self, count):
        chunk = self.inbound[self.at:self.at + count]
        self.at += len(chunk)
        return chunk

    def sendall(self, data):
        self.written += data


BODY = b"keepalive-body"

# A binary frame is Sync bytes and goes through whole.
connection = FakeConnection(0x2, BODY)
check(webproxy.read_frame(connection) == BODY, "a binary frame's payload is forwarded")
check(connection.written == b"", "a binary frame is answered with nothing")

# A continuation frame is the rest of one, and is data too.
connection = FakeConnection(0x0, BODY)
check(webproxy.read_frame(connection) == BODY, "a continuation frame's payload is forwarded")

# A close ends the pump.
connection = FakeConnection(0x8, b"")
check(webproxy.read_frame(connection) is None, "a close frame ends the connection")

# A ping is answered with a pong carrying the same body, and the daemon is
# handed nothing. Both halves matter: forwarding the body desynchronises the
# daemon, and not answering makes an intermediary that requires a pong hang up.
connection = FakeConnection(0x9, BODY)
check(webproxy.read_frame(connection) == b"", "a ping's payload is not forwarded to the daemon")
check(connection.written[:1] == bytes([0x80 | 0xA]), "a ping is answered with a pong")
check(connection.written.endswith(BODY), "the pong carries the ping's body")

# A pong and a text frame carry nothing this protocol reads.
for opcode, name in ((0xA, "pong"), (0x1, "text")):
    connection = FakeConnection(opcode, BODY)
    check(webproxy.read_frame(connection) == b"", "a %s frame's payload is not forwarded" % name)

# The server's own frames stay binary unless a control opcode is asked for.
connection = FakeConnection(0x2, b"")
webproxy.write_frame(connection, BODY)
check(connection.written[0] == 0x82, "a server frame is binary and final")

# A client frame that is not masked is refused (RFC 6455, 5.1), and a
# length past the message bound is refused before anything is read for it.
unmasked = FakeConnection(0x2, BODY)
unmasked.inbound = bytes([0x82, len(BODY)]) + BODY
check(webproxy.read_frame(unmasked) is None, "an unmasked client frame ends the connection")
huge = FakeConnection(0x2, b"")
huge.inbound = bytes([0x82, 0x80 | 127]) + struct.pack(">Q", webproxy.MAX_MESSAGE_BYTES + 1) + b"\xAA\xBB\xCC\xDD"
check(webproxy.read_frame(huge) is None, "a frame longer than a message may be is refused")
check(huge.at == len(huge.inbound) - 4, "nothing past the oversized length is read")


class FakeUpgrade:
    """An upgrade request to read, and the proxy's answer."""

    def __init__(self, request):
        self.inbound = request
        self.at = 0
        self.written = b""

    def recv(self, count):
        chunk = self.inbound[self.at:self.at + count]
        self.at += len(chunk)
        return chunk

    def sendall(self, data):
        self.written += data

    def settimeout(self, _):
        pass

    def close(self):
        pass


SECRET = "/the-per-run-secret-path-for-this-test"
PORT = 8778
settings = webproxy.Settings(SECRET, PORT, ["http://127.0.0.1:8777"])


def upgrade(path=SECRET, host="127.0.0.1:%d" % PORT, origin=None, extra=b""):
    lines = [b"GET %s HTTP/1.1" % path.encode(), b"Host: " + host.encode(), b"Upgrade: websocket",
             b"Connection: Upgrade", b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", b"Sec-WebSocket-Version: 13"]
    if origin is not None:
        lines.append(b"Origin: " + origin.encode())
    connection = FakeUpgrade(b"\r\n".join(lines) + b"\r\n" + extra + b"\r\n")
    return webproxy.handshake(connection, settings), connection.written


# The page this run serves is bridged, and so is a local program that sends no
# Origin and names the path.
admitted, answer = upgrade(origin="http://127.0.0.1:8777")
check(admitted and answer.startswith(b"HTTP/1.1 101 "), "the allowed page's upgrade is bridged")
check(b"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" in answer, "the upgrade answers with the RFC 6455 accept value")
admitted, answer = upgrade()
check(admitted, "an upgrade naming the path with no Origin is bridged")

# Every other page, path and Host is refused before anything reaches the daemon.
for name, arguments in (
        ("a page from another origin", {"origin": "https://attacker.example"}),
        ("a page with a null origin", {"origin": "null"}),
        ("an upgrade naming no secret", {"path": "/"}),
        ("an upgrade naming a guessed path", {"path": "/ws"}),
        ("a rebound Host", {"host": "attacker.example:%d" % PORT}),
        ("another port's Host", {"host": "127.0.0.1:1"}),
        ("a repeated Origin", {"origin": "http://127.0.0.1:8777", "extra": b"Origin: https://attacker.example\r\n"})):
    admitted, answer = upgrade(**arguments)
    check(not admitted, "%s is refused" % name)
    check(answer.startswith(b"HTTP/1.1 4"), "%s is answered with a 4xx status" % name)

# An HTTP request that is not a GET upgrade, the shape a cross-site form or a
# no-cors fetch takes, is refused too.
connection = FakeUpgrade(b"POST " + SECRET.encode() + b" HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n" % PORT)
check(not webproxy.handshake(connection, settings), "a POST to the path is refused")

# An upgrade request without end is cut off at its bound.
connection = FakeUpgrade(b"GET " + SECRET.encode() + b" HTTP/1.1\r\n" + b"X: " + b"y" * (2 * webproxy.MAX_HANDSHAKE_BYTES))
check(not webproxy.handshake(connection, settings), "an upgrade request past its bound is refused")
check(connection.at <= webproxy.MAX_HANDSHAKE_BYTES + 4096, "an oversized upgrade is not read past its bound")

# A native relay is a privileged local transport. Refused web requests must
# never start one, and admitted requests must use fixed argv, not a shell.
for path, origin, allowed in [(SECRET, 'http://127.0.0.1:8777', True),
                              ('/guessed', 'http://127.0.0.1:8777', False),
                              (SECRET, 'https://attacker.example', False)]:
    request = (f'GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\nUpgrade: websocket\r\n'
               f'Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
               f'Sec-WebSocket-Version: 13\r\nOrigin: {origin}\r\n\r\n').encode()
    client = FakeUpgrade(request)
    parent, child, relay, slots = MagicMock(), MagicMock(), MagicMock(), MagicMock()
    with patch.object(webproxy.socket, 'socketpair', return_value=(parent, child)), \
            patch.object(webproxy.subprocess, 'Popen', return_value=relay) as spawn, \
            patch.object(webproxy, 'pump') as pump:
        webproxy.serve(client, '/private/host/host-0123456789abcdef.sock', settings, slots, '/app/ubiquitty-host')
        check(spawn.called == allowed, 'only an admitted page starts a native relay')
        check(pump.called == allowed, 'only an admitted page reaches the native relay')
        check(slots.release.call_count == 1, 'every native relay connection releases its slot')
        if allowed:
            check(spawn.call_args.args[0] == ['/app/ubiquitty-host', '--attach', '--socket', 'host-0123456789abcdef.sock'], 'the relay gets the exact fixed attach argv')
            check(not spawn.call_args.kwargs.get('shell'), 'the relay never uses a shell')
            check(spawn.call_args.kwargs['env']['UBIQUITTY_HOME'] == '/private/host', 'the relay uses the selected host directory')
            check(child.close.call_count == 1 and relay.wait.call_count == 1, 'relay child descriptors and process are reaped')

# SSH shell banners are not Sync bytes. Strip exactly the bounded native-relay
# preamble and retain the first binary byte after it; a missing preamble closes
# the relay instead of corrupting the decoder.
for prefix, allowed in [(b'Welcome\n' + web_connections.SYNC_PREAMBLE, True),
                        (b'Access denied\n', False),
                        (b'x' * (webproxy.MAX_HANDSHAKE_BYTES + 1), False)]:
    client = FakeUpgrade(b'')
    stream = FakeUpgrade(prefix + (b'\x00\xFFsync' if allowed else b''))
    parent, child, relay, slots = MagicMock(), MagicMock(), MagicMock(), MagicMock()
    parent.recv.side_effect = stream.recv
    with patch.object(webproxy, 'handshake', return_value=True), \
            patch.object(webproxy.socket, 'socketpair', return_value=(parent, child)), \
            patch.object(webproxy.subprocess, 'Popen', return_value=relay) as spawn, \
            patch.object(webproxy, 'pump') as pump:
        command = ['ssh', '--', 'devbox', 'exec native --attach']
        webproxy.serve(client, '', settings, slots, relay_command=command,
                       relay_preamble=web_connections.SYNC_PREAMBLE)
        check(spawn.call_args.args[0] == command, 'SSH relay preserves its argv without a local shell')
        check(pump.called == allowed, 'only a framed SSH stream reaches the Sync pump')
        if allowed:
            check(stream.recv(6) == b'\x00\xFFsync', 'SSH preamble consumes no Sync bytes')
        check(stream.at <= webproxy.MAX_HANDSHAKE_BYTES, 'SSH greeting work is bounded')
        check(parent.close.call_count == 1 and child.close.call_count == 1,
              'successful and failed SSH connections release both descriptors')
        check(slots.release.call_count == 1 and relay.wait.call_count == 1,
              'failed SSH connections release capacity and reap their child')

for unsafe in ['-oProxyCommand=oops', 'devbox; id', 'devbox\nother', '$(id)', 'devbox -p 22', 'x' * 256]:
    try:
        web_connections.ssh_words(unsafe, '/tmp/control')
        check(False, 'unsafe SSH destination refused: ' + repr(unsafe))
    except ValueError:
        pass
words = web_connections.ssh_words('user@devbox', '/tmp/control')
check(words[-2:] == ['--', 'user@devbox'] and 'BatchMode=yes' in words,
      'SSH aliases are one operand and relay reconnects cannot prompt invisibly')
check('BatchMode=yes' not in web_connections.ssh_words('devbox', '/tmp/control', interactive=True),
      'initial SSH authentication can prompt in the invoking terminal')
try:
    web_connections.remote_commands(socket_name='../other.sock; id')
    check(False, 'remote socket traversal or shell text refused')
except ValueError:
    pass
with tempfile.TemporaryDirectory(prefix='ubq-web-tests-') as directory:
    # Exercise the actual shell quoting contract with punctuation in a legal
    # executable filename; a command substitution must remain literal text.
    binary = Path(directory) / "native' $(printf injected); helper"
    binary.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
    binary.chmod(0o700)
    probe, attach = web_connections.remote_commands(str(binary))
    result = subprocess.run(['/bin/sh', '-c', probe], capture_output=True, check=True)
    check(result.stdout == b'--version\n', 'remote executable shell punctuation stays inside one path')
    result = subprocess.run(['/bin/sh', '-c', attach], capture_output=True, check=True)
    check(result.stdout == web_connections.SYNC_PREAMBLE + b'--attach\n',
          'remote attach announces the preamble before executing the literal native path')
    registry = Path(directory) / 'launcher.json'
    registration = {'url': 'http://127.0.0.1:12345/' + 'a' * 32 + '/', 'id': 'run',
                    'key': 'private-admin-key', 'runtimeDirectory': directory}
    registry.write_text(json.dumps(registration)); registry.chmod(0o600)
    check(web_connections.read_registration(registry) == registration, 'owner-only launcher registration is reusable')
    registry.chmod(0o644)
    check(web_connections.read_registration(registry) is None, 'shared launcher registration is refused')
    registry.chmod(0o600)
    link = Path(directory) / 'link.json'; link.symlink_to(registry)
    check(web_connections.read_registration(link) is None, 'symlink launcher registration is refused')
    registration['url'] = 'https://outside.example/'
    registry.write_text(json.dumps(registration))
    check(web_connections.read_registration(registry) is None, 'registration cannot send its admin key to a remote origin')

if failures:
    for line in failures:
        print("test-web-proxy-frames: FAIL — %s" % line, file=sys.stderr)
    sys.exit(1)
print("test-web-proxy-frames: data frames carry Sync bytes, control frames do not; "
      "only this run's page and path reach the daemon")
