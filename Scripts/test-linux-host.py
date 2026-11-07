#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Exercise Scripts/linux-host.sh against a stand-in ssh and rsync."""

import os
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent / "linux-host.sh"

# ssh answers by running its remote script locally, with HOME moved into the
# sandbox, so the remote side's directory handling is exercised for real. The
# host name `down` does not answer. Every invocation is logged.
FAKE_SSH = r'''#!/bin/bash
echo "ssh $*" >> "$UBQ_TEST_LOG"
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift 2 ;;
        *) break ;;
    esac
done
host=$1; shift
[ "$host" != down ] || exit 255
HOME="$UBQ_TEST_REMOTE_HOME" exec "$@"
'''

# rsync to the remote path lands in the sandbox home; from it, likewise.
FAKE_RSYNC = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import sys
with open(os.environ['UBQ_TEST_LOG'], 'a') as log:
    log.write('rsync ' + ' '.join(sys.argv[1:]) + '\n')
arguments = iter(sys.argv[1:])
paths = []
listed = False
for argument in arguments:
    if argument == '-e':
        next(arguments)
    elif argument == '--files-from=-':
        listed = True
    elif argument not in ('-a', '--from0'):
        paths.append(argument)
def mapped(value):
    return Path(os.environ['UBQ_TEST_REMOTE_HOME']) / value.split(':', 1)[1] if ':' in value else Path(value)
source, destination = map(mapped, paths)
destination.mkdir(parents=True, exist_ok=True)
if listed:
    entries = [os.fsdecode(name) for name in sys.stdin.buffer.read().split(b'\0') if name]
    for name in entries:
        origin, target = source / name, destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if origin.is_symlink():
            target.symlink_to(os.readlink(origin))
        else:
            shutil.copy2(origin, target)
elif source.is_dir():
    shutil.copytree(source, destination, dirs_exist_ok=True, symlinks=True)
else:
    sys.exit(1)
'''


class LinuxHostTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="ubq-linux-host-")
        self.addCleanup(scratch.cleanup)
        self.directory = Path(scratch.name).resolve()
        self.root = self.directory / "checkout"
        scripts = self.root / "Scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(SCRIPT, scripts / "linux-host.sh")
        shutil.copy2(SCRIPT.parent / "library-scripts.sh", scripts / "library-scripts.sh")
        (scripts / "build-version.sh").write_text('#!/bin/sh\nprintf "0.0.0\\n"\n')
        (scripts / "build-version.sh").chmod(0o755)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (scripts / "ci_batteries.py").write_text("")
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        for name, body in (("ssh", FAKE_SSH), ("rsync", FAKE_RSYNC),
                           ("sha256sum", '#!/bin/sh\nexec shasum -a 256 "$@"\n')):
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        self.remoteHome = self.directory / "remote"
        self.remoteHome.mkdir()
        self.log = self.directory / "log"
        self.log.write_text("")
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith(("GIT_", "UBIQUITTY_", "UBQ_"))}
        self.environment.update(
            PATH=f"{self.bin}:{os.environ['PATH']}", UBQ_TEST_LOG=str(self.log),
            UBQ_TEST_REMOTE_HOME=str(self.remoteHome), UBQ_CI_ROOT=str(self.directory / "ci"),
            UBQ_LINUX_HOST_RESULTS=str(self.directory / "results"),
            UBIQUITTY_SNAPSHOT_FAILURE_DIR=str(self.directory / "failures"))

    def run_script(self, *arguments, **environment):
        merged = dict(self.environment, **environment)
        return subprocess.run(
            ["bash", str(self.root / "Scripts/linux-host.sh"), *arguments],
            env=merged, capture_output=True, text=True, check=False, stdin=subprocess.DEVNULL)

    def setConfigured(self, host):
        subprocess.run(["git", "-C", str(self.root), "config", "ubiquitty.linuxHost", host], check=True)

    def test_unset_means_container_and_asks_nobody(self):
        result = self.run_script("route")
        self.assertTrue(result.stdout.startswith("container "), result.stdout)
        self.assertEqual(self.log.read_text(), "")

    def test_configured_host_that_answers_is_the_route(self):
        self.setConfigured("fake")
        self.assertEqual(self.run_script("route").stdout.strip(), "host fake")

    def test_environment_overrides_the_clone_and_empty_forces_the_container(self):
        self.setConfigured("fake")
        self.assertEqual(self.run_script("route", UBIQUITTY_LINUX_HOST="").stdout.split()[0], "container")
        self.assertEqual(self.run_script("route", UBIQUITTY_LINUX_HOST="other").stdout.strip(), "host other")

    def test_unreachable_host_falls_back_with_the_reason(self):
        self.setConfigured("down")
        route = self.run_script("route").stdout
        self.assertTrue(route.startswith("container down did not answer"), route)

    def test_probe_is_batch_mode_with_a_short_connect_timeout(self):
        self.setConfigured("fake")
        self.run_script("route")
        self.assertIn("-o BatchMode=yes -o ConnectTimeout=5", self.log.read_text())

    def test_a_host_name_that_could_be_an_option_is_refused(self):
        for name in ("-oProxyCommand=x", "a b", "a;b"):
            route = self.run_script("route", UBIQUITTY_LINUX_HOST=name).stdout
            self.assertTrue(route.startswith("container "), route)
        self.assertEqual(self.log.read_text(), "")

    def test_stages_without_a_host_refuse_instead_of_running_locally(self):
        result = self.run_script("stages", "linux-build")
        self.assertEqual(result.returncode, 2)
        self.assertIn("no Linux host", result.stderr)

    def runsDirectory(self):
        return self.remoteHome / "ubiquitty-linux-runs"

    def test_a_run_removes_its_remote_directory_and_brings_logs_back_when_the_stage_fails(self):
        # The stand-in for the remote ci_batteries.py leaves a log and fails.
        (self.root / "Scripts/ci_batteries.py").write_text(
            "import os, sys\nlog = os.path.join(os.environ['UBQ_CI_ROOT'], 'linux')\n"
            "os.makedirs(log); open(os.path.join(log, '01-stage.log'), 'w').write(' '.join(sys.argv[1:]))\n"
            "sys.exit(7)\n")
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        (self.root / "Scripts/fetch-quic-deps.sh").write_text("")
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        # The stand-in rsync copies the file list's tree; give it the checkout.
        result = self.run_script("stages", "linux-build", "linux-smokes", UBIQUITTY_LINUX_HOST="fake")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(list(self.runsDirectory().iterdir()), [])
        brought = (self.directory / "results/01-stage.log").read_text()
        self.assertIn("run linux --source-root ", brought)
        self.assertTrue(brought.endswith("--only linux-build --only linux-smokes"), brought)

    def test_a_shared_run_keeps_its_directory_until_released(self):
        (self.root / "Scripts/ci_batteries.py").write_text("")
        (self.root / "Scripts/fetch-quic-deps.sh").write_text("")
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        shared = dict(UBIQUITTY_LINUX_HOST="fake", UBQ_LINUX_HOST_RUN="push-1")
        self.assertEqual(self.run_script("stages", "linux-build", **shared).returncode, 0)
        self.assertEqual([path.name for path in self.runsDirectory().iterdir()], ["push-1"])
        self.assertEqual(self.run_script("release", **shared).returncode, 0)
        self.assertEqual(list(self.runsDirectory().iterdir()), [])

    def make_split_sources(self):
        (self.root / "CMakeLists.txt").write_text("# App fixture\n")
        (self.root / "Scripts/repository.txt").write_text("app\n")
        core = self.root / "Libraries/ubiquitty-core"
        kit = self.root / "Libraries/ubiquitty-kit"
        nested = kit / "Libraries/ubiquitty-core"
        for path, role in ((core, "core"), (nested, "core"), (kit, "kit")):
            (path / "Scripts").mkdir(parents=True, exist_ok=True)
            (path / "CMakeLists.txt").write_text("# library fixture\n")
            (path / "Scripts/repository.txt").write_text(role + "\n")
            (path / "owned.txt").write_text(str(path.relative_to(self.root)))
            subprocess.run(["git", "init", "-q", str(path)], check=True)
            if path == core:
                (path / "Scripts/build-version.sh").write_text('#!/bin/sh\nprintf "0.0.0\\n"\n')
                (path / "Scripts/build-version.sh").chmod(0o755)
                (path / "Scripts/fetch-quic-deps.sh").write_text("# Core-owned QUIC recipe\n")
                (path / "Scripts/ci_batteries.py").write_text(
                    'import json, os, pathlib, sys\n'
                    'root=pathlib.Path.cwd()\n'
                    'assert sys.argv[1:3] == ["run", "linux"]\n'
                    'assert sys.argv[sys.argv.index("--source-root")+1] == str(root)\n'
                    'assert pathlib.Path(sys.argv[sys.argv.index("--core-source-root")+1]) == root/"Libraries/ubiquitty-core"\n'
                    'assert pathlib.Path(sys.argv[sys.argv.index("--kit-source-root")+1]) == root/"Libraries/ubiquitty-kit"\n'
                    'assert not list(root.rglob(".git"))\n'
                    'assert (root/"Libraries/ubiquitty-kit/Libraries/ubiquitty-core/owned.txt").is_file()\n'
                    'with open(os.environ["UBQ_CI_ROOT"]+"/calls", "a") as out: out.write("called\\n")\n')
            subprocess.run(["git", "-C", str(path), "add", "."], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(path), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                            "commit", "-qm", "fixture"], check=True)
        # A top-level impostor must not supply the shared runner or hash.
        (self.root / "Scripts/ci_batteries.py").write_text('raise SystemExit(91)\n')
        (self.root / "Scripts/fetch-quic-deps.sh").write_text("# wrong App recipe\n")
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True, capture_output=True)
        return core, kit, nested

    def test_split_sync_carries_pinned_nested_libraries_without_git_and_removes_deleted_files(self):
        core, kit, nested = self.make_split_sources()
        transient = core / "untracked.txt"
        transient.write_text("uncommitted library edit")
        shared = dict(UBIQUITTY_LINUX_HOST="fake", UBQ_LINUX_HOST_RUN="split-1")
        first = self.run_script("stages", "linux-build", **shared)
        self.assertEqual(first.returncode, 0, first.stderr)
        remote = self.runsDirectory() / "split-1/ubiquitty"
        for source in (core / "owned.txt", kit / "owned.txt", nested / "owned.txt", transient):
            self.assertEqual((remote / source.relative_to(self.root)).read_bytes(), source.read_bytes())
        self.assertEqual(list(remote.rglob(".git")), [])
        digest = hashlib.sha256((core / "Scripts/fetch-quic-deps.sh").read_bytes()).hexdigest()[:12]
        self.assertTrue((self.remoteHome / f".cache/ubiquitty-linux-host/quic-deps-{digest}").is_dir())
        (core / "owned.txt").unlink()
        transient.unlink()
        (nested / "CMakeLists.txt").unlink()
        second = self.run_script("stages", "linux-snapshots", **shared)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertFalse((remote / "Libraries/ubiquitty-core/owned.txt").exists())
        self.assertFalse((remote / "Libraries/ubiquitty-core/untracked.txt").exists())
        self.assertFalse((remote / "Libraries/ubiquitty-kit/Libraries/ubiquitty-core/CMakeLists.txt").exists())
        calls = self.runsDirectory() / "split-1/ci/calls"
        self.assertEqual(calls.read_text().splitlines(), ["called", "called"])
        self.assertEqual(self.run_script("release", **shared).returncode, 0)

    def test_uninitialized_nested_library_refuses_before_any_remote_stage(self):
        _, _, nested = self.make_split_sources()
        shutil.rmtree(nested)
        result = self.run_script("stages", "host-tests", UBIQUITTY_LINUX_HOST="fake")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required submodule is not initialized", result.stderr)
        self.assertEqual(list(self.runsDirectory().iterdir()), [])

    def test_release_without_a_run_asks_nobody(self):
        self.assertEqual(self.run_script("release", UBQ_LINUX_HOST_RUN="push-2").returncode, 0)
        self.assertEqual(self.log.read_text(), "")

    def test_the_run_directory_is_refused_when_the_host_is_nearly_full(self):
        (self.root / "Scripts/ci_batteries.py").write_text("")
        result = self.run_script("stages", "linux-build", UBIQUITTY_LINUX_HOST="fake",
                                 UBQ_LINUX_HOST_MIN_FREE_GB="99999999")
        self.assertEqual(result.returncode, 3)
        self.assertIn("GB free", result.stderr)
        self.assertEqual(list(self.runsDirectory().iterdir()), [])

    def test_an_unsafe_run_identifier_is_refused(self):
        self.setConfigured("fake")
        result = self.run_script("stages", "linux-build", UBQ_LINUX_HOST_RUN="../escape")
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
