#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Open the Sync workspace client with local or SSH hosts in one browser session.

Native relays preserve host authority and existing terminal sessions. SSH starts
the installed host if needed; --start-host does the same locally. Run-scoped
paths and explicit page origins protect the loopback server and bridges.
"""

import argparse
import ctypes
import hmac
import importlib.util
import json
import mimetypes
import os
from pathlib import Path
import re
import secrets
import socket
import stat
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit
import webbrowser


class LauncherHTTPServer(ThreadingHTTPServer):
    """Bound requests before a worker reads even the first HTTP header."""

    max_connections = 16
    request_timeout = 10

    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(self.max_connections)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            request.settimeout(self.request_timeout)
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


def installed_host_binary():
    candidates = [Path('/Applications/Ubiquitty.app/Contents/Helpers/ubiquitty-host'),
                  Path.home() / 'Applications/Ubiquitty.app/Contents/Helpers/ubiquitty-host']
    return next((path for path in candidates if path.is_file()), None)


def running_host_binary(socket_path):
    """Pair an existing daemon with its own relay, including after app updates."""
    try:
        pid_file = socket_path.with_suffix('.pid')
        facts = pid_file.lstat()
        if not stat.S_ISREG(facts.st_mode) or facts.st_uid != os.getuid() or facts.st_size > 32:
            return None
        process_id = int(pid_file.read_text().strip())
        if process_id <= 0:
            return None
        if sys.platform == 'darwin':
            library = ctypes.CDLL('/usr/lib/libproc.dylib')
            library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
            library.proc_pidpath.restype = ctypes.c_int
            buffer = ctypes.create_string_buffer(4096)
            if library.proc_pidpath(process_id, buffer, len(buffer)) <= 0:
                return None
            path = Path(os.fsdecode(buffer.value))
        else:
            path = Path(f'/proc/{process_id}/exe').resolve(strict=True)
        return path if path.name == 'ubiquitty-host' and path.is_file() else None
    except (OSError, ValueError):
        return None


def live_host_sockets(directory, binary):
    """Use the host's read-only probe; stale socket files are not live hosts."""
    if not directory.is_dir():
        return []
    candidates = []
    for path in directory.iterdir():
        if not re.fullmatch(r'host-[0-9a-f]{16}\.sock', path.name):
            continue
        facts = path.lstat()
        if stat.S_ISSOCK(facts.st_mode) and facts.st_uid == os.getuid():
            candidates.append(path)
    candidates.sort(key=lambda path: path.stat().st_mtime, reverse=True)
    deadline = time.monotonic() + 3
    for path in candidates[:64]:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            probe = subprocess.run([str(binary), '--probe-daemon', '--socket', path.name],
                                   env=dict(os.environ, UBIQUITTY_HOME=str(directory)),
                                   capture_output=True, timeout=min(1, remaining), check=False)
            if probe.returncode == 0:
                return [path]
        except subprocess.TimeoutExpired:
            continue
    return []


def connection_plan(arguments, runtime_directory, authenticate=True):
    if arguments.ssh:
        from web_connections import ssh_plan
        plan = ssh_plan(arguments.ssh, runtime_directory, arguments.remote_binary,
                        arguments.remote_socket, authenticate=authenticate)
        if arguments.name:
            plan['name'] = arguments.name
        return plan
    binary = arguments.host_binary or installed_host_binary()
    if not binary or not Path(binary).is_file():
        raise ValueError('Install Ubiquitty, or pass --host-binary /path/to/ubiquitty-host.')
    socket_path = Path(arguments.socket) if arguments.socket else None
    if socket_path is None:
        directory = Path(os.environ.get('UBIQUITTY_HOME', Path.home() / '.ubiquitty')).resolve()
        candidates = live_host_sockets(directory, binary)
        if not candidates and arguments.start_host:
            subprocess.run([str(binary), '--ensure-daemon', '--quic-port', '0'], check=True)
            candidates = live_host_sockets(directory, binary)
        if not candidates:
            raise ValueError('No local host is listening. Open Ubiquitty or use --start-host.')
        socket_path = candidates[0]
    if not socket_path.is_socket():
        raise ValueError('The host socket no longer exists. Omit --socket to discover a live host.')
    socket_path = socket_path.resolve()
    binary = Path(arguments.host_binary) if arguments.host_binary else running_host_binary(socket_path)
    if not binary or not binary.is_file():
        raise ValueError('Cannot identify the host executable. Pass its matching --host-binary.')
    return {'key': 'local:' + str(socket_path), 'name': arguments.name or 'Local host',
            'transport': 'local', 'managedRelay': True, 'localRelay': True,
            'socket': str(socket_path), 'hostBinary': str(binary.resolve())}


def main():
    import tempfile
    import shlex
    import urllib.request
    import urllib.error
    from web_connections import read_registration
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', type=Path, required=True, help='web-dist from Scripts/build-web.sh')
    parser.add_argument('--socket', type=Path, help='an exact existing local host socket')
    parser.add_argument('--host-binary', type=Path, help='the matching local host executable')
    parser.add_argument('--start-host', action='store_true', help='start the installed native host if none listens')
    parser.add_argument('--ssh', help='SSH configuration name or [user@]host')
    parser.add_argument('--remote-binary', help='remote host executable; defaults to ~/.ubiquitty/ubiquitty-host')
    parser.add_argument('--remote-socket', help='optional exact remote host-<id>.sock basename')
    parser.add_argument('--token-file', type=Path, help='optional capability token')
    parser.add_argument('--name', help='display name in the host picker')
    parser.add_argument('--no-open', action='store_true')
    parser.add_argument('--registry', type=Path, help='reuse this launcher and add hosts to its browser session')
    arguments = parser.parse_args()
    stage = arguments.stage.resolve()
    if arguments.registry is None:
        arguments.registry = stage.parent / 'web-launcher.json'
    if not (stage / 'workspace.html').is_file():
        parser.error('the stage has no workspace.html; build the web client first')
    if arguments.ssh and (arguments.socket or arguments.host_binary):
        parser.error('--ssh uses --remote-binary and --remote-socket, not local paths')
    token = arguments.token_file.read_text().strip() if arguments.token_file else ''
    if len(token) > 256:
        parser.error('the token is too large')
    existing = read_registration(arguments.registry) if arguments.registry else None
    if existing:
        try:
            request = urllib.request.Request(existing['url'] + 'launcher-status')
            with urllib.request.urlopen(request, timeout=2) as response:
                live = json.load(response).get('id') == existing['id']
        except (OSError, ValueError, KeyError, urllib.error.URLError):
            live = False
        if live:
            try:
                connection_plan(arguments, existing['runtimeDirectory'])  # Authenticate in this terminal.
                fields = {key: str(value) if isinstance(value, Path) else value for key, value in vars(arguments).items()
                          if key in {'ssh', 'socket', 'host_binary', 'remote_binary', 'remote_socket', 'name', 'start_host'}}
                fields['token'] = token
                request = urllib.request.Request(existing['url'] + 'add-connection',
                    data=json.dumps(fields).encode(), headers={'Authorization': 'Bearer ' + existing['key'], 'Content-Type': 'application/json'}, method='POST')
                with urllib.request.urlopen(request, timeout=15) as response:
                    result = json.load(response)
                print(f"Added {result['name']}. Choose it from the host control in your existing browser window.")
                print(existing['url'] + 'workspace.html')
                return
            except (OSError, ValueError, subprocess.CalledProcessError) as error:
                parser.error(str(error))
    runtime = tempfile.TemporaryDirectory(prefix='ubq-web-')
    try:
        initial = connection_plan(arguments, runtime.name)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        runtime.cleanup()
        parser.error(str(error))
    specification = importlib.util.spec_from_file_location('ubiquitty_web_proxy', Path(__file__).with_name('web-proxy.py'))
    proxy = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(proxy)
    route = '/' + secrets.token_urlsafe(24) + '/'
    admin_key, launcher_id = secrets.token_urlsafe(32), secrets.token_urlsafe(16)
    connections, listeners = {}, []
    connection_lock = threading.RLock()
    slots = threading.BoundedSemaphore(proxy.MAX_CONNECTIONS)
    launcher_command = shlex.join(['env', 'UBQ_BUILD_ROOT=' + str(stage.parent),
                                  str(Path(__file__).with_name('open-web.sh').resolve()), '--no-build'])

    def register(plan, capability=''):
        with connection_lock:
            if plan['key'] in connections:
                return connections[plan['key']]
            if len(connections) >= 8:
                raise ValueError('This browser launcher already has eight hosts.')
            listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            listener.bind(('127.0.0.1', 0))
            listener.listen(proxy.MAX_CONNECTIONS)
            bridge_route = '/' + secrets.token_urlsafe(24)
            port = listener.getsockname()[1]
            settings = proxy.Settings(bridge_route, port, [origin])
            public = {key: value for key, value in plan.items() if key in {'key', 'name', 'transport', 'managedRelay', 'localRelay'}}
            public.update(url=f'ws://127.0.0.1:{port}{bridge_route}', token=capability)
            connections[plan['key']] = public
            listeners.append(listener)

            def bridge():
                while True:
                    try:
                        client, _ = listener.accept()
                    except OSError:
                        break
                    if not slots.acquire(blocking=False):
                        client.close()
                        continue
                    target = (client, plan.get('socket', ''), settings, slots, plan.get('hostBinary'),
                              plan.get('relayCommand'), plan.get('relayPreamble'))
                    threading.Thread(target=proxy.serve, args=target, daemon=True).start()
            threading.Thread(target=bridge, daemon=True).start()
            return public

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # No run-scoped URLs or credentials in access logs.

        def admitted_path(self):
            if self.headers.get('Host') not in {f'127.0.0.1:{self.server.server_port}', f'localhost:{self.server.server_port}'}:
                self.send_error(403)
                return None
            path = urlsplit(self.path).path
            if not hmac.compare_digest(path[:len(route)], route):
                self.send_error(404)
                return None
            return unquote(path[len(route):])

        def answer(self, body, mime):
            self.send_response(200)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            relative = self.admitted_path()
            if relative is None:
                return
            if relative == 'sync-config':
                with connection_lock:
                    hosts = list(connections.values())
                    body = json.dumps({**hosts[0], 'connections': hosts, 'launcherCommand': launcher_command}).encode()
                self.answer(body, 'application/json')
            elif relative == 'launcher-status':
                self.answer(json.dumps({'id': launcher_id}).encode(), 'application/json')
            else:
                target = (stage / (relative or 'workspace.html')).resolve()
                if not target.is_relative_to(stage) or not target.is_file():
                    self.send_error(404)
                    return
                mime = 'application/wasm' if target.suffix == '.wasm' else mimetypes.guess_type(target)[0] or 'application/octet-stream'
                self.answer(target.read_bytes(), mime)

        def do_POST(self):
            relative = self.admitted_path()
            if relative is None:
                return
            if relative != 'add-connection':
                self.send_error(404)
                return
            if self.headers.get('Origin') or not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + admin_key):
                self.send_error(403)
                return
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 16384:
                    raise ValueError('Invalid request size')
                self.connection.settimeout(10)
                fields = json.loads(self.rfile.read(length))
                if not isinstance(fields, dict) or set(fields) - {'ssh', 'socket', 'host_binary', 'remote_binary', 'remote_socket', 'name', 'start_host', 'token'}:
                    raise ValueError('Unknown connection fields')
                capability = fields.pop('token', '')
                if not isinstance(capability, str) or len(capability) > 256:
                    raise ValueError('Invalid token')
                options = argparse.Namespace(**{key: fields.get(key) for key in ['ssh', 'socket', 'host_binary', 'remote_binary', 'remote_socket', 'name', 'start_host']})
                result = register(connection_plan(options, runtime.name, authenticate=False), capability)
                self.answer(json.dumps({'name': result['name']}).encode(), 'application/json')
            except (ValueError, TypeError, OSError, subprocess.CalledProcessError) as error:
                self.send_error(400, str(error))

    http = LauncherHTTPServer(('127.0.0.1', 0), Handler)
    origin = f'http://127.0.0.1:{http.server_port}'
    register(initial, token)
    url = origin + route
    registration = {'url': url, 'id': launcher_id, 'key': admin_key, 'runtimeDirectory': runtime.name}
    if arguments.registry:
        arguments.registry.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode='w', dir=arguments.registry.parent, delete=False) as output:
            json.dump(registration, output)
        os.replace(output.name, arguments.registry)
    print(url + 'workspace.html', flush=True)
    print(f"Host: {initial['name']}. Ctrl+C stops the web launcher; terminal sessions keep running.", flush=True)
    if not arguments.no_open:
        webbrowser.open(url + 'workspace.html')
    try:
        http.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        for listener in listeners:
            listener.close()
        http.server_close()
        if arguments.registry and read_registration(arguments.registry) == registration:
            arguments.registry.unlink(missing_ok=True)
        runtime.cleanup()


if __name__ == '__main__':
    main()
