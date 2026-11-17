#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Omarchy component provenance cannot silently select the decorated variant."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Scripts'))
import release_omarchy as native


class OmarchyReleaseTests(unittest.TestCase):
    def fixture(self, root, damage=''):
        repositories = {'ubiquitty': 'a' * 40, 'kit': 'b' * 40, 'core': 'c' * 40, 'omarchy': 'd' * 40}
        run = {'repository': 'ubiquitty/ubiquitty', 'id': '123', 'head': 'e' * 40}
        for architecture in native.ARCHITECTURES:
            if damage == 'missing architecture' and architecture == 'aarch64':
                continue
            folder = root / architecture
            folder.mkdir()
            name = f'Ubiquitty-0.5.0-omarchy-{architecture}.tar.gz'
            metadata = {'format': 1, 'configuration': 'Release', 'version': 'ubiquitty 0.5.0 (fixture)', 'architecture': architecture, 'chromeless': damage != 'decorated'}
            body = json.dumps(metadata).encode()
            with tarfile.open(folder / name, 'w:gz') as archive:
                entry = tarfile.TarInfo('ubiquitty/manifest.json')
                entry.size = len(body)
                archive.addfile(entry, io.BytesIO(body))
            checksum = native.digest(folder / name)
            (folder / (name + '.sha256')).write_text(checksum + '  ' + name + '\n')
            proof = {'schema': native.SCHEMA, 'tag': 'v0.5.0', 'run': run.copy(), 'repositories': repositories,
                     'architecture': architecture, 'builder': 'f' * 40,
                     'configuration': {'type': 'Release', 'chromeless': True, 'pgo': 'REQUIRE'},
                     'assets': {item: native.digest(folder / item) for item in [name, name + '.sha256']}}
            if damage == 'wrong run':
                proof['run']['id'] = '124'
            if damage == 'changed bytes':
                (folder / name).write_bytes((folder / name).read_bytes() + b'changed')
            (folder / (architecture + '-omarchy-build.json')).write_text(json.dumps(proof))
        return repositories, run

    def test_both_verified_chromeless_architectures_are_collected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inputs = root / 'inputs'
            inputs.mkdir()
            repositories, run = self.fixture(inputs)
            environment = {'GITHUB_REPOSITORY': run['repository'], 'GITHUB_RUN_ID': run['id'], 'GITHUB_SHA': run['head']}
            with patch.dict(os.environ, environment), patch.object(native.release_ci, 'validate', return_value={'version': '0.5.0', 'repositories': repositories}):
                native.collect(root, inputs, root / 'output', 'v0.5.0', 'f' * 40)
            manifest = json.loads((root / 'output/omarchy-preparation.json').read_text())
            self.assertEqual(len(manifest['assets']), 4)
            self.assertEqual(set(manifest['builds']), set(native.ARCHITECTURES))

    def test_missing_decorated_tampered_and_wrong_run_packages_are_rejected(self):
        for damage in ['missing architecture', 'decorated', 'changed bytes', 'wrong run']:
            with self.subTest(damage=damage), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                inputs = root / 'inputs'
                inputs.mkdir()
                repositories, run = self.fixture(inputs, damage)
                environment = {'GITHUB_REPOSITORY': run['repository'], 'GITHUB_RUN_ID': run['id'], 'GITHUB_SHA': run['head']}
                with patch.dict(os.environ, environment), patch.object(native.release_ci, 'validate', return_value={'version': '0.5.0', 'repositories': repositories}), self.assertRaises(ValueError):
                    native.collect(root, inputs, root / 'output', 'v0.5.0', 'f' * 40)
                self.assertFalse((root / 'output/omarchy-preparation.json').exists())


if __name__ == '__main__':
    unittest.main()
