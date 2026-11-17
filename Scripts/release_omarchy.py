#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Build and verify chromeless Omarchy components independently of signed assets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile

import release_ci

SCHEMA = 'ubiquitty.omarchy-preparation.v1'
ARCHITECTURES = ('x86_64', 'aarch64')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inspect_archive(path, architecture, version):
    with tarfile.open(path) as archive:
        member = archive.getmember('ubiquitty/manifest.json')
        if not member.isfile() or member.size > 65536:
            raise ValueError('Omarchy manifest must be a bounded regular file')
        metadata = json.load(archive.extractfile(member))
        if (metadata.get('format') != 1 or metadata.get('configuration') != 'Release'
                or metadata.get('chromeless') is not True or metadata.get('architecture') != architecture
                or metadata.get('version', '').split()[:2] != ['ubiquitty', version]):
            raise ValueError('Omarchy archive is not the requested native chromeless Release')
    return metadata


def build(root, builder, build_root, output, tag, architecture):
    if architecture not in ARCHITECTURES or architecture != platform.machine():
        raise ValueError('Omarchy must be built on its native architecture')
    composition = release_ci.validate(root, tag)
    revision = release_ci.git(builder, 'rev-parse', 'HEAD')
    subprocess.run(['git', '-C', str(builder), 'merge-base', '--is-ancestor', revision, 'origin/main'], check=True)
    if release_ci.git(builder, 'status', '--porcelain'):
        raise ValueError('Omarchy build helpers must be clean')
    # Build tooling may advance while the released integration stays frozen.
    # Its installed runtime helpers must still match the tagged integration.
    if release_ci.git(builder, 'rev-parse', 'HEAD:libexec') != release_ci.git(root / release_ci.OMARCHY_PATH, 'rev-parse', 'HEAD:libexec'):
        raise ValueError('Omarchy builder changes the tagged runtime integration')
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='omarchy-build-', dir=output.parent) as temporary:
        staged = Path(temporary)
        subprocess.run([str(builder / 'scripts/build-local-release.sh'), '--source-root', str(root),
                        '--build-root', str(build_root), '--output-dir', str(staged)], check=True)
        cache = (build_root / 'linux/CMakeCache.txt').read_text()
        for key, value in [('CMAKE_BUILD_TYPE', 'Release'), ('UBIQUITTY_LINUX_CHROMELESS', 'ON'), ('UBIQUITTY_PGO', 'REQUIRE')]:
            if not re.search('^' + key + r':[^=]+=' + value + '$', cache, re.MULTILINE):
                raise ValueError('Omarchy build does not require ' + key + '=' + value)
        archives = list(staged.glob('*.tar.gz'))
        if len(archives) != 1:
            raise ValueError('Omarchy builder must produce exactly one archive')
        archive = archives[0]
        metadata = inspect_archive(archive, architecture, composition['version'])
        if archive.with_name(archive.name + '.sha256').read_text().split() != [digest(archive), archive.name]:
            raise ValueError('Omarchy builder checksum differs')
        target = output / f"Ubiquitty-{composition['version']}-omarchy-{architecture}.tar.gz"
        shutil.copy2(archive, target)
        checksum = digest(target)
        target.with_name(target.name + '.sha256').write_text(checksum + '  ' + target.name + '\n')
        proof = {'schema': SCHEMA, 'tag': tag, 'architecture': architecture,
                 'repositories': composition['repositories'], 'builder': revision,
                 'run': {'repository': os.environ.get('GITHUB_REPOSITORY'), 'id': os.environ.get('GITHUB_RUN_ID'), 'head': os.environ.get('GITHUB_SHA')},
                 'configuration': {'type': 'Release', 'chromeless': True, 'pgo': 'REQUIRE'},
                 'metadata': metadata, 'assets': {name: digest(output / name) for name in [target.name, target.name + '.sha256']}}
        (output / (architecture + '-omarchy-build.json')).write_text(json.dumps(proof, indent=2) + '\n')


def collect(root, inputs, output, tag, builder):
    composition = release_ci.validate(root, tag)
    run = {'repository': os.environ.get('GITHUB_REPOSITORY'), 'id': os.environ.get('GITHUB_RUN_ID'), 'head': os.environ.get('GITHUB_SHA')}
    output.mkdir(parents=True, exist_ok=True)
    proofs = {}
    for architecture in ARCHITECTURES:
        matches = list(inputs.rglob(architecture + '-omarchy-build.json'))
        if len(matches) != 1:
            raise ValueError('Missing or duplicate native Omarchy proof: ' + architecture)
        proof = json.loads(matches[0].read_text())
        expected_names = {f"Ubiquitty-{composition['version']}-omarchy-{architecture}.tar.gz" + suffix for suffix in ['', '.sha256']}
        if (proof.get('schema') != SCHEMA or proof.get('tag') != tag or proof.get('run') != run
                or proof.get('repositories') != composition['repositories'] or proof.get('builder') != builder
                or proof.get('configuration') != {'type': 'Release', 'chromeless': True, 'pgo': 'REQUIRE'}
                or proof.get('architecture') != architecture or set(proof.get('assets', {})) != expected_names):
            raise ValueError('Omarchy build provenance differs: ' + architecture)
        for name, checksum in proof['assets'].items():
            source = matches[0].parent / name
            if not source.is_file() or source.is_symlink() or digest(source) != checksum:
                raise ValueError('Omarchy artifact checksum differs: ' + name)
            shutil.copy2(source, output / name)
        archive = output / f"Ubiquitty-{composition['version']}-omarchy-{architecture}.tar.gz"
        inspect_archive(archive, architecture, composition['version'])
        if archive.with_name(archive.name + '.sha256').read_text().split() != [digest(archive), archive.name]:
            raise ValueError('Omarchy archive checksum sidecar differs')
        proofs[architecture] = proof
    manifest = {'schema': SCHEMA, 'tag': tag, 'repositories': composition['repositories'],
                'builder': builder, 'run': run, 'builds': proofs,
                'assets': {name: checksum for proof in proofs.values() for name, checksum in proof['assets'].items()}}
    (output / 'omarchy-preparation.json').write_text(json.dumps(manifest, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('build', 'collect'))
    parser.add_argument('--source-root', type=Path, default=Path.cwd())
    parser.add_argument('--builder', required=True)
    parser.add_argument('--build-root', type=Path)
    parser.add_argument('--architecture', choices=ARCHITECTURES)
    parser.add_argument('--inputs', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--tag', required=True)
    args = parser.parse_args()
    if args.command == 'build':
        if not args.build_root or not args.architecture:
            parser.error('build requires --build-root and --architecture')
        build(args.source_root.resolve(), Path(args.builder).resolve(), args.build_root.resolve(), args.output.resolve(), args.tag, args.architecture)
    else:
        if not args.inputs or not re.fullmatch('[0-9a-f]{40}', args.builder):
            parser.error('collect requires --inputs and the exact builder commit')
        collect(args.source_root.resolve(), args.inputs.resolve(), args.output.resolve(), args.tag, args.builder)


if __name__ == '__main__':
    main()
