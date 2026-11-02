#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""web-proxy.py — bridge a browser WebSocket to the ubiquitty-host socket.

A page cannot dial AF_UNIX, and the daemon binds one. This moves bytes between
the two and nothing else: it does not parse, frame or interpret the Sync
protocol, because the browser already speaks it — SyncClientCore compiles to
wasm and runs in the page. Anything smarter here would be a second
implementation of the protocol living outside Core.

What it does decide is who reaches the daemon. Every connection it bridges
arrives at the daemon as this user's own process, so a port anyone may open
would hand the owner-only socket to every local user and every page the browser
loads. An upgrade is bridged only when it names this run's secret path, its Host
is this loopback listener, and its Origin, when it carries one, is a page origin
given with --origin. A browser sends Origin on every WebSocket, so a page served
from anywhere else is refused before a byte reaches the daemon; a local program
that sends none still needs the path. The daemon's own token check follows.

Development scaffolding. Production wants the daemon accepting WebSocket
directly rather than a Python hop.

    ./Scripts/web-proxy.py [--socket PATH] [--port 8778] [--path /SECRET] [--origin URL]...
"""
import argparse, base64, hashlib, hmac, os, secrets, socket, struct, subprocess, sys, threading

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"  # RFC 6455

# An upgrade request is a few hundred bytes; one past this is not an upgrade.
MAX_HANDSHAKE_BYTES = 8192
# A client that has not finished its upgrade by then is only holding a slot.
HANDSHAKE_SECONDS = 5
# One WebSocket message carries the Sync frames a page queued together, each of
# which the daemon bounds far below this, so a longer one is refused here
# rather than read into memory whole.
MAX_MESSAGE_BYTES = 4 * 1024 * 1024
# Each bridged connection is one of the daemon's clients, which it caps too.
MAX_CONNECTIONS = 16


class Refused(Exception):
    """An upgrade this proxy does not bridge, with the status it answers."""

    def __init__(self, status, reason):
        super().__init__(reason)
        self.status = status


class Settings:
    """What an upgrade must name to be bridged."""

    def __init__(self, path, port, origins):
        self.path = path.encode()
        self.hosts = {b"127.0.0.1:%d" % port, b"localhost:%d" % port}
        self.origins = {origin.rstrip("/").lower().encode() for origin in origins}


def parse_request(data):
    """The request target and lower-cased headers of an upgrade request."""
    head = data.split(b"\r\n\r\n", 1)[0]
    lines = head.split(b"\r\n")
    request = lines[0].split(b" ")
    if len(request) != 3 or request[0] != b"GET" or not request[2].startswith(b"HTTP/1."):
        raise Refused(b"400 Bad Request", "not a WebSocket upgrade")
    headers = {}
    for line in lines[1:]:
        name, separator, value = line.partition(b":")
        if not separator:
            raise Refused(b"400 Bad Request", "a malformed header line")
        key = name.strip().lower()
        # A repeated security header is ambiguous, and which copy a client
        # meant is not this proxy's to guess.
        if key in headers and key in (b"host", b"origin", b"sec-websocket-key"):
            raise Refused(b"400 Bad Request", "a repeated %s header" % key.decode())
        headers[key] = value.strip()
    return request[1], headers


def admit(target, headers, settings):
    """The upgrade's key, or Refused unless the request is one this run bridges."""
    if not hmac.compare_digest(target, settings.path):
        raise Refused(b"404 Not Found", "the request names another path")
    if headers.get(b"host", b"").lower() not in settings.hosts:
        raise Refused(b"403 Forbidden", "the Host is not this loopback listener")
    origin = headers.get(b"origin")
    if origin is not None and origin.lower() not in settings.origins:
        raise Refused(b"403 Forbidden", "the Origin %s is not an allowed page" % origin.decode("latin-1"))
    if headers.get(b"upgrade", b"").lower() != b"websocket" or not headers.get(b"sec-websocket-key"):
        raise Refused(b"400 Bad Request", "not a WebSocket upgrade")
    return headers[b"sec-websocket-key"].decode("latin-1")


def handshake(conn, settings):
    """Reads and answers the upgrade; returns whether to bridge the connection."""
    data = bytearray()
    try:
        while b"\r\n\r\n" not in data:
            if len(data) > MAX_HANDSHAKE_BYTES:
                raise Refused(b"431 Request Header Fields Too Large", "an oversized upgrade request")
            chunk = conn.recv(4096)
            if not chunk:
                return False
            data += chunk
        target, headers = parse_request(bytes(data))
        key = admit(target, headers, settings)
    except Refused as refusal:
        conn.sendall(b"HTTP/1.1 " + refusal.status + b"\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
        print("web-proxy: refused an upgrade: %s" % refusal, file=sys.stderr)
        return False
    accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    conn.sendall(
        b"HTTP/1.1 101 Switching Protocols\r\n"
        b"Upgrade: websocket\r\nConnection: Upgrade\r\n"
        b"Sec-WebSocket-Accept: " + accept.encode() + b"\r\n\r\n")
    return True


def recv_exact(conn, n):
    out = bytearray()
    while len(out) < n:
        chunk = conn.recv(min(n - len(out), 65536))
        if not chunk:
            return None
        out += chunk
    return bytes(out)


def read_frame(conn):
    """One WebSocket frame -> payload bytes, or None when the connection ends."""
    header = recv_exact(conn, 2)
    if not header:
        return None
    opcode = header[0] & 0x0F
    masked = header[1] & 0x80
    length = header[1] & 0x7F
    if length >= 126:
        extended = recv_exact(conn, 2 if length == 126 else 8)
        if extended is None:
            return None
        length = struct.unpack(">H" if len(extended) == 2 else ">Q", extended)[0]
    # The WebSocket protocol has a client mask every frame and a server close
    # a connection on one that is not masked (RFC 6455, 5.1). The length is
    # judged before anything is read on its strength.
    if not masked or length > MAX_MESSAGE_BYTES:
        return None
    mask = recv_exact(conn, 4)
    payload = recv_exact(conn, length) if length else b""
    if mask is None or payload is None:
        return None
    payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    # Only a data frame carries Sync bytes. A control frame's payload is the
    # WebSocket layer's own — a keepalive body, a close reason — and writing it
    # to the daemon puts those bytes in the middle of the client's frame stream,
    # where the daemon reads the next five as a header and either refuses the
    # client or drops it. Any intermediary in front of the page can send one.
    if opcode == 0x8: # close
        return None
    if opcode == 0x9: # ping: answer it, and hand the daemon nothing
        write_frame(conn, payload, opcode=0xA)
        return b""
    if opcode not in (0x0, 0x1, 0x2): # pong and anything unassigned
        return b""
    if opcode == 0x1: # text: a page sending text is not speaking this protocol
        return b""
    return payload


def write_frame(conn, payload, opcode=0x2):
    """Server frames are never masked. Binary by default: this is protocol, not text.

    OPCODE carries a control frame instead — a pong, which is the one answer a
    keepalive needs and the one an intermediary drops the connection for missing.
    """
    header = bytearray([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header.append(n)
    elif n < 65536:
        header.append(126); header += struct.pack(">H", n)
    else:
        header.append(127); header += struct.pack(">Q", n)
    conn.sendall(bytes(header) + payload)


def pump(client, host):
    def host_to_client():
        try:
            while True:
                data = host.recv(65536)
                if not data:
                    break
                write_frame(client, data)
        except OSError:
            pass
        finally:
            client.close()
    threading.Thread(target=host_to_client, daemon=True).start()
    try:
        while True:
            payload = read_frame(client)
            if payload is None:
                break
            if payload:
                host.sendall(payload)
    except OSError:
        pass
    finally:
        host.close()


def serve(client, socket_path, settings, slots, host_binary=None, relay_command=None, relay_preamble=None):
    """Upgrades one connection and bridges it, then gives its slot back."""
    relay = None
    host = None
    try:
        client.settimeout(HANDSHAKE_SECONDS)
        try:
            if not handshake(client, settings):
                client.close()
                return
            client.settimeout(None)
            if host_binary or relay_command:
                # The same uid-gated native relay used by the GUI and SSH.
                # No identity is claimed by Python and no host gate changes.
                # This starts only after the exact path/Host/Origin admission.
                host, child = socket.socketpair()
                try:
                    environment = dict(os.environ)
                    if host_binary:
                        environment['UBIQUITTY_HOME'] = os.path.dirname(socket_path)
                    command = relay_command or [host_binary, '--attach', '--socket', os.path.basename(socket_path)]
                    relay = subprocess.Popen(command,
                                             stdin=child, stdout=child, env=environment, close_fds=True)
                except OSError:
                    host.close()
                    raise
                finally:
                    child.close()
                if relay_preamble:
                    host.settimeout(20)
                    prefix = bytearray()
                    while len(prefix) < MAX_HANDSHAKE_BYTES:
                        byte = host.recv(1)
                        if not byte:
                            raise OSError('SSH relay ended before the Sync stream')
                        prefix += byte
                        if prefix.endswith(relay_preamble):
                            break
                    else:
                        raise OSError('SSH relay did not announce the Sync stream')
                    host.settimeout(None)
            else:
                host = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                host.connect(socket_path)
        except OSError as error:
            print(f"web-proxy: {error}", file=sys.stderr)
            client.close()
            return
        pump(client, host)
    finally:
        if host:
            host.close()
        if relay:
            try:
                relay.wait(timeout=2)
            except subprocess.TimeoutExpired:
                relay.terminate()
                try:
                    relay.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    relay.kill()
                    relay.wait()
        slots.release()


def control_directory():
    override = os.environ.get("UBIQUITTY_HOME")
    if override:
        return override
    return os.path.join(os.path.expanduser("~"), ".ubiquitty")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", help="daemon socket path (default: newest host-*.sock)")
    ap.add_argument("--port", type=int, default=8778)
    ap.add_argument("--path", help="the request path an upgrade must name (default: a random one, printed)")
    ap.add_argument("--origin", action="append", default=[],
                    help="a page origin allowed to connect, such as http://127.0.0.1:8777; repeat for more")
    args = ap.parse_args()

    path = args.socket
    if not path:
        directory = control_directory()
        candidates = [os.path.join(directory, f) for f in os.listdir(directory)
                      if f.startswith("host") and f.endswith(".sock")] if os.path.isdir(directory) else []
        if not candidates:
            sys.exit(f"web-proxy: no host-*.sock under {directory} — start one with "
                     f"ubiquitty-host --ensure-daemon")
        path = max(candidates, key=os.path.getmtime)

    secret_path = args.path or "/" + secrets.token_urlsafe(24)
    if not secret_path.startswith("/") or len(secret_path) < 17 or any(c.isspace() for c in secret_path):
        sys.exit("web-proxy: --path must start with / and carry at least sixteen unguessable characters")
    settings = Settings(secret_path, args.port, args.origin)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", args.port))
    server.listen(4)
    print(f"web-proxy: ws://127.0.0.1:{args.port}{secret_path} -> {path}", file=sys.stderr)
    if not args.origin:
        print("web-proxy: no --origin given, so no browser page may connect", file=sys.stderr)

    slots = threading.BoundedSemaphore(MAX_CONNECTIONS)
    while True:
        client, _ = server.accept()
        if not slots.acquire(blocking=False):
            client.close()
            continue
        threading.Thread(target=serve, args=(client, path, settings, slots), daemon=True).start()


if __name__ == "__main__":
    main()
