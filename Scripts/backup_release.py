#!/usr/bin/env python3
"""Back up a sealed recovery directory, verify remote bytes, then allow staging."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from xml.etree.ElementTree import ParseError
from check_update_host import read_feed, validate_item
from release_record import digest, run, verify, write_json

def backup_repository():
    """Require an explicit private destination; never infer it from public origin."""
    repository = os.environ.get('CORNERWHEEL_BACKUP_REPOSITORY', '')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Set CORNERWHEEL_BACKUP_REPOSITORY to an approved private owner/repo.')
    if repository.split('/')[1] in ('.', '..'):
        raise ValueError('Backup repository name must not be a path component.')
    return repository


def backup(recovery, project):
    manifest = verify(recovery)
    destination = backup_repository()
    # Match the explicit Git push host even when GH_HOST selects an enterprise host.
    github_repository = f'github.com/{destination}'
    repository = json.loads(run('gh', 'repo', 'view', github_repository, '--json', 'isPrivate,nameWithOwner'))
    if not repository['isPrivate'] or repository['nameWithOwner'].lower() != destination.lower():
        raise ValueError('Release recovery archives require the configured private repository.')
    tag = manifest['tag']
    revision = manifest['source_revision']
    if run('git', 'rev-parse', f'refs/tags/{tag}^{{commit}}', cwd=project) != revision:
        raise ValueError('Local tag does not match the archived source revision.')
    # Explicit destination: do not follow a changed origin into a different account.
    remote = f'https://github.com/{destination}.git'
    run('git', 'push', remote, f'refs/tags/{tag}', cwd=project)
    with tempfile.TemporaryDirectory(prefix='cornerwheel-backup-') as temp:
        temp = Path(temp)
        package = temp / f'{tag}-recovery.zip'
        run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', recovery, package)
        # Save the ZIP once: retries must use identical bytes, including ZIP timestamps.
        saved = recovery.parent / package.name
        if saved.exists():
            # A previously generated backup must contain this exact manifest and files.
            old = temp / 'old'
            run('ditto', '-x', '-k', saved, old)
            verify(old / 'recovery')
            if digest(old / 'recovery/manifest.json') != digest(recovery / 'manifest.json'):
                raise ValueError('Existing recovery ZIP describes a different release.')
        else:
            shutil.copy2(package, saved)
        check = subprocess.run(['gh', 'release', 'view', tag, '--repo', github_repository,
                                '--json', 'isDraft,assets'], capture_output=True, text=True)
        if check.returncode:
            notes = temp / 'notes.txt'
            notes.write_text(f"Private recovery archive for {tag}.\nSource: {revision}\n"
                             'Contains exact package, source, matching symbols and build records.\n'
                             'This backup does not publish the app or update feed.\n')
            run('gh', 'release', 'create', tag, '--repo', github_repository, '--verify-tag',
                '--draft', '--title', tag + ' recovery', '--notes-file', notes)
            state = {'isDraft': True, 'assets': []}
        else:
            state = json.loads(check.stdout)
        names = {item['name'] for item in state['assets']}
        if saved.name not in names:
            if not state['isDraft']:
                raise ValueError('Published backup is missing its asset; refusing to modify it.')
            run('gh', 'release', 'upload', tag, saved, '--repo', github_repository)
        # Never use --clobber. A collision is verified, not overwritten.
        downloaded = temp / 'downloaded'
        downloaded.mkdir()
        run('gh', 'release', 'download', tag, '--repo', github_repository, '--pattern', saved.name,
            '--dir', downloaded)
        if digest(downloaded / saved.name) != digest(saved):
            raise ValueError('Remote release archive differs from the local sealed archive.')
        restored = temp / 'restored'
        run('ditto', '-x', '-k', downloaded / saved.name, restored)
        verify(restored / 'recovery')
        if state['isDraft']:
            run('gh', 'release', 'edit', tag, '--repo', github_repository, '--draft=false', '--latest=false')
        immutable = run('gh', 'api', '--hostname', 'github.com',
                        f'repos/{destination}/releases/tags/{tag}', '--jq', '.immutable')
        if immutable != 'true':
            raise ValueError('Remote backup is not immutable. Enable repository release immutability.')
        receipt = {'repository': destination, 'tag': tag, 'asset': saved.name,
                   'sha256': digest(saved), 'manifest_sha256': digest(recovery / 'manifest.json'),
                   'source_revision': revision, 'download_verified': True,
                   'url': f'https://github.com/{destination}/releases/tag/{tag}'}
        write_json(recovery.parent / 'backup-receipt.json', receipt)
        print(receipt['url'])
        return manifest


def stage(recovery, manifest):
    if manifest['kind'] != 'release':
        raise ValueError('Legacy preservation snapshots cannot be staged as new releases.')
    history = recovery.parent
    release_root = history.parent.parent
    if history.parent.name != 'history' or history.name != str(manifest['build']):
        raise ValueError('Staging requires Build/Releases/history/<build>/recovery.')
    update_files = list((history / 'updates').iterdir())
    if any(path.is_symlink() or not path.is_file() for path in update_files):
        raise ValueError('Update staging must contain only regular files, without symlinks.')
    # Publish only the current package, feed-referenced older packages and sealed
    # feed/notes. Never copy unrelated files or follow symlinks into public staging.
    feeds = {n for n in manifest['files'] if Path(n).name == n and n.endswith('.xml')}
    notes = {n for n in manifest['files'] if Path(n).name == n and n.endswith('.txt')}
    for name in {manifest['package']} | feeds | notes:
        if digest(history / 'updates' / name) != digest(recovery / name):
            raise ValueError('Staging content differs from the backed-up release: ' + name)
    archives = set()
    for feed in feeds:
        for item in read_feed((recovery / feed).read_bytes()):
            _, _, name, size = validate_item(item)
            archives.add(name)
            if (history / 'updates' / name).stat().st_size != size:
                raise ValueError('Staged archive size differs from the backed-up feed: ' + name)
    if not feeds or manifest['package'] not in archives:
        raise ValueError('Backed-up feed must reference this release package.')
    allowed = archives | feeds | notes
    if {path.name for path in update_files} != allowed:
        raise ValueError('Update staging contains unexpected files or is missing feed artifacts.')
    lock = release_root / '.stage.lock'
    lock.mkdir()
    try:
        staging = release_root / 'staging'
        candidate = Path(tempfile.mkdtemp(prefix='.stage-', dir=release_root))
        for name in sorted(allowed):
            shutil.copy2(history / 'updates' / name, candidate / name)
        if staging.exists():
            previous = history / 'previous-staging'
            if previous.exists():
                raise ValueError('Previous staging already preserved; review before restaging.')
            staging.rename(previous)
        candidate.rename(staging)
        print('Verified backup complete. Upload files are ready at ' + str(staging))
    finally:
        lock.rmdir()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('recovery', type=Path)
    parser.add_argument('--stage', action='store_true')
    parser.add_argument('--project', type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    try:
        recovery = args.recovery.resolve()
        manifest = backup(recovery, args.project.resolve())
        if args.stage: stage(recovery, manifest)
    except (OSError, ValueError, ParseError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Backup/staging stopped; local archives are preserved: {error}\n')


if __name__ == '__main__':
    main()
