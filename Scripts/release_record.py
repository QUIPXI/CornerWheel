#!/usr/bin/env python3
"""Capture a committed build and seal its recoverable release artifacts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile

LOCKFILE = Path('CornerWheel.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')
PUBLIC_SETTINGS = ('RELEASE_VERSION', 'RELEASE_BUILD', 'DEVELOPMENT_TEAM',
                   'SIGNING_IDENTITY', 'UPDATE_FEED_URL', 'DOWNLOAD_URL_PREFIX',
                   'UPDATE_PUBLIC_KEY')


def run(*args, cwd=None):
    return subprocess.check_output([str(a) for a in args], cwd=cwd, text=True).strip()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def clean_revision(project):
    project = project.resolve()
    if Path(run('git', 'rev-parse', '--show-toplevel', cwd=project)).resolve() != project:
        raise ValueError('Native project must have its own Git repository.')
    if run('git', 'status', '--porcelain', '--untracked-files=all', cwd=project):
        raise ValueError('Commit all native changes before preparing a release.')
    # Build inputs must be tracked, including the exact dependency resolution.
    for path in ('project.yml', 'LICENSE', 'Resources/Info.plist', 'Resources/ThirdPartyNotices.txt',
                 'CornerWheel.xcodeproj/project.pbxproj', str(LOCKFILE)):
        run('git', 'ls-files', '--error-unmatch', path, cwd=project)
    return run('git', 'rev-parse', 'HEAD', cwd=project)


def snapshot(project, work):
    revision = clean_revision(project)
    recovery = work / 'recovery'
    recovery.mkdir()
    run('git', 'archive', '--format=tar.gz', '-o', recovery / 'source.tar.gz', revision, cwd=project)
    run('git', 'bundle', 'create', recovery / 'source.bundle', '--all', 'HEAD', cwd=project)
    source = work / 'source'
    source.mkdir()
    with tarfile.open(recovery / 'source.tar.gz') as archive:
        archive.extractall(source, filter='data')
    shutil.copy2(source / LOCKFILE, recovery / 'Package.resolved')
    config = {key: os.environ['CORNERWHEEL_' + key] for key in PUBLIC_SETTINGS}
    config.update(source_revision=revision, architecture='arm64', configuration='Release',
                  tag=f"v{config['RELEASE_VERSION']}-build.{config['RELEASE_BUILD']}")
    write_json(recovery / 'configuration.json', config)
    write_json(recovery / 'toolchain.json', {
        'xcode': run('xcodebuild', '-version'), 'developer_dir': run('xcode-select', '-p'),
        'swift': run('xcrun', 'swiftc', '--version'), 'macos': run('sw_vers'),
        'sdk': run('xcrun', '--sdk', 'macosx', '--show-sdk-version'),
        'sdk_build': run('xcrun', '--sdk', 'macosx', '--show-sdk-build-version'),
        'architecture': run('uname', '-m'),
    })
    return revision


def uuids(path):
    output = run('xcrun', 'dwarfdump', '--uuid', path)
    pairs = re.findall(r'UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)', output)
    if not pairs:
        raise ValueError(f'No debugging UUID found: {path}')
    return {arch: uuid.upper() for uuid, arch in pairs}


def symbol_inventory(app, symbols):
    available = {}
    for dwarf in symbols.glob('*.dSYM/Contents/Resources/DWARF/*'):
        for arch, uuid in uuids(dwarf).items():
            available[(arch, uuid)] = str(dwarf.relative_to(symbols))
    inventory = []
    magic = {bytes.fromhex(v) for v in ('cffaedfe', 'cefaedfe', 'feedface', 'feedfacf',
                                      'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
    for binary in sorted(app.rglob('*')):
        if binary.is_symlink() or not binary.is_file():
            continue
        with binary.open('rb') as stream:
            if stream.read(4) not in magic:
                continue
        ids = uuids(binary)
        matches = {}
        for arch, uuid in ids.items():
            if (arch, uuid) not in available:
                raise ValueError(f'Missing matching dSYM: {binary.relative_to(app)} {arch} {uuid}')
            matches[arch] = available[(arch, uuid)]
        inventory.append({'binary': str(binary.relative_to(app)), 'uuids': ids, 'symbols': matches})
    if not any(item['binary'] == 'Contents/MacOS/CornerWheel' for item in inventory):
        raise ValueError('CornerWheel executable is absent from symbol inventory.')
    return inventory


def zip_directory(source, destination):
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', source, destination)


def seal(project, work, package):
    recovery = work / 'recovery'
    config = json.loads((recovery / 'configuration.json').read_text())
    archive = work / 'CornerWheel.xcarchive'
    app = work / 'export/CornerWheel.app'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    expected = {'CornerWheelSourceRevision': config['source_revision'],
                'CFBundleVersion': config['RELEASE_BUILD'],
                'CFBundleShortVersionString': config['RELEASE_VERSION']}
    if any(info.get(key) != value for key, value in expected.items()):
        raise ValueError('Exported app does not match the recorded source/version/build.')
    if digest(work / 'source' / LOCKFILE) != digest(recovery / 'Package.resolved'):
        raise ValueError('Package.resolved changed during the build.')
    inventory = symbol_inventory(app, archive / 'dSYMs')
    zip_directory(archive, recovery / 'CornerWheel.xcarchive.zip')
    zip_directory(archive / 'dSYMs', recovery / 'dSYMs.zip')
    zip_directory(work / 'DerivedData/SourcePackages', recovery / 'SourcePackages.zip')
    shutil.copy2(package, recovery / package.name)
    for feed in (work / 'updates').glob('*.xml'):
        shutil.copy2(feed, recovery / feed.name)
    for notes in (work / 'updates').glob('*.txt'):
        shutil.copy2(notes, recovery / notes.name)
    shutil.copy2(work / 'ExportOptions.plist', recovery / 'ExportOptions.plist')
    shutil.copytree(work / 'logs', recovery / 'logs')
    write_json(recovery / 'manifest.json', {
        'schema': 1, 'kind': 'release', 'source_revision': config['source_revision'],
        'tag': config['tag'], 'version': config['RELEASE_VERSION'], 'build': config['RELEASE_BUILD'],
        'package': package.name, 'symbols': inventory,
        'files': {str(p.relative_to(recovery)): {'sha256': digest(p), 'bytes': p.stat().st_size}
                  for p in sorted(recovery.rglob('*')) if p.is_file() and p.name != 'manifest.json'},
        'rebuild_limit': 'Rebuild source with the recorded toolchain/settings/dependencies. Signing timestamps '
                         'and notarization can change bytes; the preserved package is the exact download.',
    })
    verify(recovery)
    tag = config['tag']
    # Tags reserve build numbers and never move to another revision.
    existing = subprocess.run(['git', 'rev-parse', '--verify', f'refs/tags/{tag}^{{commit}}'],
                              cwd=project, text=True, capture_output=True)
    if existing.returncode == 0:
        if existing.stdout.strip() != config['source_revision']:
            raise ValueError('Release tag already points to another source revision.')
    else:
        run('git', 'tag', '-a', tag, config['source_revision'], '-m',
            f"CornerWheel {config['RELEASE_VERSION']} build {config['RELEASE_BUILD']}", cwd=project)


def verify(recovery):
    recovery = recovery.resolve()
    manifest = json.loads((recovery / 'manifest.json').read_text())
    if manifest.get('schema') != 1 or not manifest.get('files'):
        raise ValueError('Invalid or empty release manifest.')
    for name, expected in manifest['files'].items():
        path = recovery / name
        if path.resolve() != path.absolute() or not path.resolve().is_relative_to(recovery.resolve()):
            raise ValueError('Unsafe manifest path: ' + name)
        if not path.is_file() or path.stat().st_size != expected['bytes'] or digest(path) != expected['sha256']:
            raise ValueError('Missing or altered release artifact: ' + name)
    actual = {str(p.relative_to(recovery)) for p in recovery.rglob('*') if p.is_file()}
    if actual != set(manifest['files']) | {'manifest.json'}:
        raise ValueError('Release directory includes files not covered by the manifest.')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['check', 'snapshot', 'seal', 'verify'])
    parser.add_argument('path', type=Path)
    parser.add_argument('--project', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--package', type=Path)
    args = parser.parse_args()
    try:
        if args.action == 'check': print(clean_revision(args.path))
        elif args.action == 'snapshot': print(snapshot(args.project, args.path.resolve()))
        elif args.action == 'seal': seal(args.project, args.path.resolve(), args.package)
        else: verify(args.path.resolve()); print('All release artifact checksums match.')
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
