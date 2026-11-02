# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Local and SSH connection plans for the loopback workspace launcher."""

import hashlib
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess

SYNC_PREAMBLE = b'\nUBIQUITTY-SYNC\n'


def ssh_words(host, control_path, interactive=False):
    if not isinstance(host, str) or len(host) > 255 or not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.@:\[\]-]*', host):
        raise ValueError('Use an SSH configuration name or [user@]host, without flags or shell text.')
    words = ['ssh', '-T', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15',
             '-o', 'ServerAliveCountMax=3', '-o', 'ControlMaster=auto', '-o', 'ControlPersist=60',
             '-o', f'ControlPath={control_path}']
    if not interactive:
        words += ['-o', 'BatchMode=yes']
    return words + ['--', host]


def remote_binary_word(binary):
    if binary is None:
        return '"$HOME/.ubiquitty/ubiquitty-host"'
    if not isinstance(binary, str) or not binary or len(binary) > 4096 or '\0' in binary or '\n' in binary:
        raise ValueError('The remote executable must be a single path.')
    if binary.startswith('~/'):
        return '"$HOME"/' + shlex.quote(binary[2:])
    return shlex.quote(binary)


def remote_commands(binary=None, socket_name=None):
    executable = remote_binary_word(binary)
    pin = ''
    if socket_name:
        if not isinstance(socket_name, str) or not re.fullmatch(r'host-[0-9a-f]{16}\.sock', socket_name):
            raise ValueError('The remote socket must be a host-<16 hex>.sock basename.')
        pin = ' --socket ' + shlex.quote(socket_name)
    # Matches Core/Session/RemoteBootstrap.h's installed helper and native
    # attach contract. No install, token creation or daemon replacement occurs.
    present = f'test -x {executable} || {{ echo "Install ubiquitty-host on this machine first." >&2; exit 1; }}; '
    prepare = executable + (' --probe-daemon' + pin if pin else ' --ensure-daemon --quic-port 0')
    probe = present + prepare + ' >/dev/null && ' + executable + ' --version'
    attach = present + "printf '\\nUBIQUITTY-SYNC\\n'; exec " + executable + ' --attach' + pin
    return probe, attach


def ssh_plan(host, runtime_directory, binary=None, socket_name=None, authenticate=False):
    identity = hashlib.sha256((host + '\0' + str(binary) + '\0' + str(socket_name)).encode()).hexdigest()[:16]
    control = Path(runtime_directory) / ('ssh-' + identity)
    probe, attach = remote_commands(binary, socket_name)
    if authenticate:
        print(f'Connecting to {host} using your SSH configuration…', flush=True)
        subprocess.run(ssh_words(host, control, interactive=True) + [probe], check=True)
    return {'key': 'ssh:' + identity, 'name': host, 'transport': 'ssh', 'managedRelay': True,
            'relayCommand': ssh_words(host, control) + [attach], 'relayPreamble': SYNC_PREAMBLE}


def read_registration(path):
    """The owner-only registration secret never goes into the browser config."""
    import json
    try:
        facts = path.lstat()
        if not stat.S_ISREG(facts.st_mode) or facts.st_uid != os.getuid() or facts.st_mode & 0o077 or facts.st_size > 16384:
            return None
        data = json.loads(path.read_text())
        from urllib.parse import urlsplit
        url = urlsplit(data['url'])
        if (url.scheme != 'http' or url.hostname != '127.0.0.1' or not url.port or url.username or url.password
                or url.query or url.fragment or not re.fullmatch(r'/[A-Za-z0-9_-]{24,}/', url.path)):
            return None
        if any(not isinstance(data.get(field), str) or not data[field] for field in ['id', 'key', 'runtimeDirectory']):
            return None
        if not Path(data['runtimeDirectory']).is_absolute():
            return None
        return data
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None
