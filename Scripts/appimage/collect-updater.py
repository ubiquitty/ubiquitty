# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

import hashlib, json, os, re, shutil, subprocess, sys, tarfile
from pathlib import Path
arch = sys.argv[1]
root = Path('/work')
stage = root / f'stage-{arch}'
output = root / f'updater-{arch}'
sources = root / f'sources-{arch}'
for directory in (output/'bin', output/'lib', output/'notices', sources/'debian', sources/'upstream'):
    directory.mkdir(parents=True, exist_ok=True)
exe = stage/'usr/bin/appimageupdatetool'
shutil.copy2(exe, output/'bin/appimageupdatetool')
result = subprocess.check_output(['ldd', str(exe)], text=True)
if 'not found' in result:
    raise RuntimeError(result)
print(result, flush=True)
system = {'libc.so.6', 'libm.so.6', 'libdl.so.2', 'libpthread.so.0', 'librt.so.1', 'libstdc++.so.6', 'libgcc_s.so.1'}
packages = {}
libraries = []
for line in result.splitlines():
    match = re.match(r'\s*(\S+) => (/\S+)', line)
    if not match or match[1] in system:
        continue
    name, path = match.groups()
    library = Path(path)
    shutil.copy2(library, output/'lib'/name)
    record = {'name': name, 'originalSHA256': hashlib.sha256(library.read_bytes()).hexdigest()}
    if not path.startswith('/work/'):
        candidates = [path, str(library.resolve())]
        if path.startswith('/lib/'):
            candidates.append('/usr'+path)
        if path.startswith('/usr/lib/'):
            candidates.append(path[4:])
        owner = None
        for candidate in candidates:
            found = subprocess.run(['dpkg-query','-S',candidate], capture_output=True, text=True)
            if not found.returncode:
                owner = found.stdout.split(': /')[0]
                break
        if not owner:
            raise RuntimeError(f'No package owner for {path}')
        fields = subprocess.check_output(['dpkg-query','-W','-f=${Package}\t${Version}\t${source:Package}\t${source:Version}',owner],text=True).split('\t')
        package, version, source, source_version = fields
        record.update(package=package, version=version, source=source, sourceVersion=source_version)
        packages[source] = source_version
        notice = Path('/usr/share/doc')/package/'copyright'
        if not notice.exists():
            raise RuntimeError(f'Missing copyright for {package}')
        shutil.copy2(notice, output/'notices'/f'{package}-copyright')
    libraries.append(record)
    subprocess.run(['patchelf','--set-rpath','$ORIGIN',str(output/'lib'/name)],check=True)
subprocess.run(['patchelf','--set-rpath','$ORIGIN/../lib/ubiquitty-updater',str(output/'bin/appimageupdatetool')],check=True)
shutil.copytree('/usr/share/common-licenses', output/'notices/common-licenses', dirs_exist_ok=True)
upstream = [root/'source', *(root/f'build-{arch}'/'_deps').glob('*-src')]
revisions = []
for source in upstream:
    if (source/'.git').exists():
        revision = subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()
        remote = subprocess.check_output(['git','-C',str(source),'remote','get-url','origin'],text=True).strip()
    elif source.name == 'curl-src':
        revision = 'sha256:a132bd93188b938771135ac7c1f3ac1d3ce507c1fcbef8c471397639214ae2ab'
        remote = 'https://github.com/curl/curl/releases/download/curl-7_80_0/curl-7.80.0.tar.xz'
    else:
        raise RuntimeError(f'Unknown source provenance: {source}')
    destination = sources/'upstream'/source.name
    shutil.copytree(source, destination, ignore=shutil.ignore_patterns('.git'), dirs_exist_ok=True)
    revisions.append({'directory': source.name, 'repository': remote, 'revision': revision})
    notices = output/'notices'/source.name
    notices.mkdir(exist_ok=True)
    for file in source.rglob('*'):
        if not file.is_file() or '.git' in file.parts:
            continue
        if file.name.lower().startswith(('license','licence','copying','copyright')):
            target = notices/file.relative_to(source)
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(file,target)
for package in ('argagg-dev', 'nlohmann-json3-dev'):
    fields = subprocess.check_output(['dpkg-query', '-W', '-f=${source:Package}\t${source:Version}', package], text=True).split('\t')
    packages[fields[0]] = fields[1]
    shutil.copy2(Path('/usr/share/doc')/package/'copyright', output/'notices'/f'{package}-copyright')
for package, version in sorted(packages.items()):
    print('Source',package,version,flush=True)
    subprocess.run(['apt-get','source','--download-only',f'{package}={version}'], cwd=sources/'debian',check=True)
metadata = {'architecture':arch, 'upstream':revisions, 'libraries':libraries, 'sourcePackages':packages}
(output/'provenance.json').write_text(json.dumps(metadata,indent=2)+'\n')
shutil.copy2(output/'provenance.json',sources/'provenance.json')
shutil.copy2('/etc/os-release',sources/'os-release')
for name in ('Dockerfile','build-helper.sh','collect-helper.py'):
    shutil.copy2(root/name,sources/name)
shutil.copytree(output/'notices',sources/'notices',dirs_exist_ok=True)
(sources/'README.txt').write_text('AppImageUpdate CLI and bundled library sources.\nBuild environment and exact source/library versions: Dockerfile and provenance.json.\nBuild with build-helper.sh; collect-helper.py copies dependencies and changes only their ELF RPATHs.\nDebian .dsc files and matching source archives include packaging patches and build instructions.\nThe upstream directories are complete checkouts without Git metadata.\nThe final AppImage keeps these shared libraries in usr/lib/ubiquitty-updater.\nExtract the AppImage with --appimage-extract, replace a library there, and run AppRun or repack with appimagetool to use a modified library.\n')
files = {str(f.relative_to(output)):hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(output.rglob('*')) if f.is_file() and f.name!='manifest.json'}
(output/'manifest.json').write_text(json.dumps({'architecture':arch,'files':files},indent=2)+'\n')
with tarfile.open(root/f'updater-sources-{arch}.tar.xz','w:xz') as archive:
    archive.add(sources,arcname=f'updater-sources-{arch}')
print('Bundled',len(libraries),'libraries; sources',len(packages),'Debian packages',flush=True)
