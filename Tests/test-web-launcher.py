#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Exercise the multi-host HTTP contract without opening ports or native sessions."""

import argparse
import importlib.util
import io
import json
from pathlib import Path
import socket
import socketserver
import sys
import tempfile
import threading
import unittest
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Scripts'))
specification = importlib.util.spec_from_file_location('weblauncher', ROOT / 'Scripts/serve-web.py')
launcher = importlib.util.module_from_spec(specification)
specification.loader.exec_module(launcher)


class LauncherContract(unittest.TestCase):
    def test_registration_and_host_admission(self):
        with tempfile.TemporaryDirectory(prefix='ubq-launcher-test-') as directory:
            stage = Path(directory) / 'web-dist'
            stage.mkdir()
            (stage / 'workspace.html').write_text('<title>workspace</title>')
            registry = Path(directory) / 'web-launcher.json'
            server = MagicMock(server_port=49001)
            handler_type = None
            listeners = []

            def create_server(address, handler):
                nonlocal handler_type
                self.assertEqual(address, ('127.0.0.1', 0))
                handler_type = handler
                return server

            def socket_factory(*_):
                listener = MagicMock()
                listener.getsockname.return_value = ('127.0.0.1', 49100 + len(listeners))
                listeners.append(listener)
                return listener

            def plan(options, *_, **__):
                return {'key': options.ssh or 'local', 'name': options.name or options.ssh or 'Local host',
                        'transport': 'ssh' if options.ssh else 'local', 'managedRelay': True,
                        'relayCommand': ['native', '--attach'], 'relayPreamble': b'private-preamble',
                        'hostBinary': '/private/native', 'socket': '/private/socket'}

            def request(path, method='GET', data=None, headers=None):
                handler = handler_type.__new__(handler_type)
                handler.server = server
                handler.path = path
                body = json.dumps(data).encode() if data is not None else b''
                handler.headers = {'Host': '127.0.0.1:49001', 'Content-Length': str(len(body)), **(headers or {})}
                handler.rfile = io.BytesIO(body)
                handler.wfile = io.BytesIO()
                handler.connection = MagicMock()
                status = []
                handler.send_response = lambda value: status.append(value)
                handler.send_error = lambda value, *_: status.append(value)
                handler.send_header = lambda *_: None
                handler.end_headers = lambda: None
                getattr(handler, 'do_' + method)()
                return status[-1], handler.wfile.getvalue()

            def exercise():
                registration = json.loads(registry.read_text())
                self.assertEqual(registry.stat().st_mode & 0o777, 0o600)
                route = registration['url'].split(':49001', 1)[1]
                status, body = request(route + 'sync-config')
                self.assertEqual(status, 200)
                configuration = json.loads(body)
                self.assertEqual(len(configuration['connections']), 1)
                self.assertIn('UBQ_BUILD_ROOT=' + str(Path(directory).resolve()), configuration['launcherCommand'])
                for private in [registration['key'], 'relayCommand', 'hostBinary', '/private/socket', 'runtimeDirectory']:
                    self.assertNotIn(private, body.decode())
                self.assertEqual(request('/guessed/sync-config')[0], 404)
                self.assertEqual(request(route + 'sync-config', headers={'Host': 'attacker.example'})[0], 403)
                self.assertEqual(request(route + '../web-launcher.json')[0], 404)
                self.assertEqual(request(route + 'unknown', 'POST')[0], 404)
                self.assertEqual(request(route + 'add-connection', 'POST', {'ssh': 'devbox'})[0], 403)
                authorization = {'Authorization': 'Bearer ' + registration['key']}
                self.assertEqual(request(route + 'add-connection', 'POST', {'ssh': 'devbox'},
                                         {**authorization, 'Origin': 'https://attacker.example'})[0], 403)
                self.assertEqual(request(route + 'add-connection', 'POST', {'relayCommand': ['injected']}, authorization)[0], 400)
                self.assertEqual(len(listeners), 1)
                self.assertEqual(request(route + 'add-connection', 'POST', {'ssh': 'devbox'}, authorization)[0], 200)
                self.assertEqual(request(route + 'add-connection', 'POST', {'ssh': 'devbox'}, authorization)[0], 200)
                self.assertEqual(len(listeners), 2, 'adding the same host twice must reuse its listener')
                _, body = request(route + 'sync-config')
                hosts = json.loads(body)['connections']
                self.assertEqual([host['name'] for host in hosts], ['Local host', 'devbox'])
                self.assertNotEqual(hosts[0]['url'], hosts[1]['url'])
                for index in range(6):
                    self.assertEqual(request(route + 'add-connection', 'POST', {'ssh': f'host-{index}'}, authorization)[0], 200)
                self.assertEqual(request(route + 'add-connection', 'POST', {'ssh': 'one-too-many'}, authorization)[0], 400)
                self.assertEqual(len(listeners), 8)

            server.serve_forever.side_effect = exercise
            with patch.object(sys, 'argv', ['serve-web.py', '--stage', str(stage), '--no-open']), \
                    patch.object(launcher, 'LauncherHTTPServer', side_effect=create_server), \
                    patch.object(launcher.socket, 'socket', side_effect=socket_factory), \
                    patch.object(launcher.threading, 'Thread'), \
                    patch.object(launcher, 'connection_plan', side_effect=plan), \
                    patch('builtins.print'):
                launcher.main()
            self.assertFalse(registry.exists(), 'shutdown removes only its own registration')
            for listener in listeners:
                listener.bind.assert_called_once_with(('127.0.0.1', 0))
                listener.close.assert_called_once()
            server.server_close.assert_called_once()

    def test_ssh_plan_never_borrows_local_socket_paths(self):
        options = argparse.Namespace(ssh='devbox', remote_binary=None, remote_socket=None, name='Build host')
        with patch('web_connections.ssh_plan', return_value={'transport': 'ssh'}) as plan:
            connection = launcher.connection_plan(options, '/private/runtime', authenticate=False)
        plan.assert_called_once_with('devbox', '/private/runtime', None, None, authenticate=False)
        self.assertEqual(connection['name'], 'Build host')


class HTTPAdmission(unittest.TestCase):
    def test_idle_requests_are_bounded_and_release_their_slots(self):
        read_headers = threading.Event()

        class Server(launcher.LauncherHTTPServer):
            max_connections = 2
            request_timeout = 0.2

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.sendall(b'+')
                read_headers.wait(timeout=3)
                try:
                    self.request.recv(1)
                except TimeoutError:
                    pass

        with Server(('127.0.0.1', 0), Handler) as server:
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            clients = []
            try:
                for _ in range(2):
                    client = socket.create_connection(server.server_address, timeout=3)
                    clients.append(client)
                    self.assertEqual(client.recv(1), b'+')
                with socket.create_connection(server.server_address, timeout=3) as refused:
                    self.assertEqual(refused.recv(1), b'', 'excess requests must not start a worker')
                read_headers.set()
                for client in clients:
                    self.assertEqual(client.recv(1), b'', 'idle requests must time out before receiving headers')
                with socket.create_connection(server.server_address, timeout=3) as recovered:
                    self.assertEqual(recovered.recv(1), b'+', 'timed-out requests must return their slots')
            finally:
                read_headers.set()
                for client in clients:
                    client.close()
                server.shutdown()
                worker.join(timeout=3)


if __name__ == '__main__':
    unittest.main()
