import importlib.util
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[2] / 'Scripts'
sys.path.insert(0, str(SCRIPTS))
import release_record as record
import backup_release


class ReleaseRecordTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()

    def tearDown(self):
        self.temp.cleanup()

    def make_manifest(self):
        artifact = self.root / 'package.zip'
        artifact.write_bytes(b'exact shipped bytes')
        record.write_json(self.root / 'manifest.json', {
            'schema': 1, 'kind': 'release', 'package': artifact.name,
            'files': {artifact.name: {'sha256': record.digest(artifact), 'bytes': artifact.stat().st_size}}})
        return artifact

    def test_valid_record(self):
        self.make_manifest()
        self.assertEqual(record.verify(self.root)['kind'], 'release')

    def test_macos_temporary_directory_alias_accepted(self):
        self.make_manifest()
        alias = self.root / 'directory-link'
        alias.symlink_to(self.root, target_is_directory=True)
        self.assertEqual(record.verify(alias)['kind'], 'release')

    def test_corrupted_package_rejected(self):
        artifact = self.make_manifest()
        artifact.write_bytes(b'wrong shipped bytes')
        with self.assertRaisesRegex(ValueError, 'altered'): record.verify(self.root)

    def test_missing_artifact_rejected(self):
        self.make_manifest().unlink()
        with self.assertRaisesRegex(ValueError, 'Missing'): record.verify(self.root)

    def test_unrecorded_artifact_rejected(self):
        self.make_manifest()
        (self.root / 'extra.txt').write_text('not backed up')
        with self.assertRaisesRegex(ValueError, 'not covered'): record.verify(self.root)

    def test_path_escape_rejected(self):
        self.make_manifest()
        manifest = json.loads((self.root / 'manifest.json').read_text())
        manifest['files']['../escape'] = {'bytes': 0, 'sha256': ''}
        record.write_json(self.root / 'manifest.json', manifest)
        with self.assertRaisesRegex(ValueError, 'Unsafe'): record.verify(self.root)

    def test_symlink_rejected(self):
        artifact = self.make_manifest()
        (self.root / 'alias.zip').symlink_to(artifact)
        manifest = json.loads((self.root / 'manifest.json').read_text())
        manifest['files']['alias.zip'] = manifest['files']['package.zip']
        record.write_json(self.root / 'manifest.json', manifest)
        with self.assertRaisesRegex(ValueError, 'Unsafe'): record.verify(self.root)

    def test_dirty_and_untracked_sources_rejected(self):
        def git(*args):
            return subprocess.check_output(['git', *args], cwd=self.root, stderr=subprocess.DEVNULL, text=True).strip()
        git('init', '-b', 'main')
        for name in ('project.yml', 'LICENSE', 'Resources/Info.plist', 'Resources/ThirdPartyNotices.txt',
                     'CornerWheel.xcodeproj/project.pbxproj', str(record.LOCKFILE)):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('tracked')
        git('add', '.')
        git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-m', 'fixture')
        self.assertEqual(record.clean_revision(self.root), git('rev-parse', 'HEAD'))
        (self.root / 'new.swift').write_text('untracked')
        with self.assertRaisesRegex(ValueError, 'Commit all'): record.clean_revision(self.root)
        (self.root / 'new.swift').unlink()
        (self.root / 'project.yml').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'Commit all'): record.clean_revision(self.root)

    def test_mismatched_symbols_rejected(self):
        app = self.root / 'CornerWheel.app'
        binary = app / 'Contents/MacOS/CornerWheel'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(bytes.fromhex('cffaedfe'))
        symbols = self.root / 'dSYMs'
        dwarf = symbols / 'CornerWheel.app.dSYM/Contents/Resources/DWARF/CornerWheel'
        dwarf.parent.mkdir(parents=True)
        dwarf.write_bytes(b'symbols')
        with patch.object(record, 'uuids', side_effect=[{'arm64': 'AAA'}, {'arm64': 'BBB'}]):
            with self.assertRaisesRegex(ValueError, 'Missing matching dSYM'):
                record.symbol_inventory(app, symbols)
        with patch.object(record, 'uuids', return_value={'arm64': 'AAA'}):
            self.assertEqual(len(record.symbol_inventory(app, symbols)), 1)

    def test_missing_symbols_rejected(self):
        app = self.root / 'CornerWheel.app'
        binary = app / 'Contents/MacOS/CornerWheel'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(bytes.fromhex('cffaedfe'))
        with patch.object(record, 'uuids', return_value={'arm64': 'AAA'}):
            with self.assertRaisesRegex(ValueError, 'Missing matching dSYM'):
                record.symbol_inventory(app, self.root / 'missing')

    def test_altered_staging_rejected(self):
        history = self.root / 'history/4'
        recovery = history / 'recovery'
        recovery.mkdir(parents=True)
        updates = history / 'updates'
        updates.mkdir()
        (recovery / 'app.zip').write_bytes(b'original')
        (updates / 'app.zip').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'differs'):
            backup_release.stage(recovery, {'kind': 'release', 'build': '4', 'package': 'app.zip', 'files': {}})
        self.assertFalse((self.root / 'staging').exists())

    def test_legacy_cannot_be_staged(self):
        with self.assertRaisesRegex(ValueError, 'Legacy'):
            backup_release.stage(self.root, {'kind': 'legacy-preservation'})

    def test_failed_backup_cannot_stage(self):
        with patch.object(sys, 'argv', ['backup_release.py', str(self.root), '--stage']), \
                patch.object(backup_release, 'backup', side_effect=ValueError('upload failed')), \
                patch.object(backup_release, 'stage') as stage:
            with self.assertRaises(SystemExit): backup_release.main()
            stage.assert_not_called()

    def test_backup_destination_must_be_explicit(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, 'CORNERWHEEL_BACKUP_REPOSITORY'):
                backup_release.backup_repository()

    def test_backup_destination_rejects_urls_and_paths(self):
        for destination in ('https://github.com/owner/repo', 'owner/repo/extra',
                            'owner/..', 'owner/.', '-owner/repo'):
            with self.subTest(destination=destination), patch.dict(
                    os.environ, {'CORNERWHEEL_BACKUP_REPOSITORY': destination}):
                with self.assertRaises(ValueError): backup_release.backup_repository()

    def test_public_backup_destination_rejected_before_push(self):
        with patch.dict(os.environ, {'CORNERWHEEL_BACKUP_REPOSITORY': 'owner/recovery',
                                    'GH_HOST': 'enterprise.example.invalid'}), \
                patch.object(backup_release, 'verify', return_value={}), \
                patch.object(backup_release, 'run', return_value=json.dumps({
                    'isPrivate': False, 'nameWithOwner': 'owner/recovery'})) as run:
            with self.assertRaisesRegex(ValueError, 'private repository'):
                backup_release.backup(self.root, self.root)
            run.assert_called_once_with('gh', 'repo', 'view', 'github.com/owner/recovery',
                                        '--json', 'isPrivate,nameWithOwner')

    def make_staging_fixture(self):
        history = self.root / 'history/4'
        recovery = history / 'recovery'
        updates = history / 'updates'
        recovery.mkdir(parents=True)
        updates.mkdir()
        signature = base64.b64encode(bytes(64)).decode()
        feed = ['<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>']
        for build, name in ((3, 'old.zip'), (4, 'app.zip')):
            payload = b'PK\x03\x04' + name.encode()
            (updates / name).write_bytes(payload)
            if build == 4: (recovery / name).write_bytes(payload)
            feed.append(f'<item><sparkle:version>{build}</sparkle:version>'
                        '<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>'
                        '<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>'
                        f'<enclosure url="https://example.invalid/{name}" length="{len(payload)}" '
                        f'sparkle:edSignature="{signature}" /></item>')
        feed.append('</channel></rss>')
        for directory in (recovery, updates):
            (directory / 'appcast.xml').write_text(''.join(feed))
            (directory / 'app.txt').write_text('Public release notes.')
        manifest = {'kind': 'release', 'build': '4', 'package': 'app.zip',
                    'files': {name: {} for name in ('app.zip', 'appcast.xml', 'app.txt')}}
        return recovery, updates, manifest

    def test_staging_retains_only_feed_artifacts_and_sealed_notes(self):
        recovery, _, manifest = self.make_staging_fixture()
        backup_release.stage(recovery, manifest)
        staged = self.root / 'staging'
        self.assertEqual({p.name for p in staged.iterdir()},
                         {'old.zip', 'app.zip', 'appcast.xml', 'app.txt'})

    def test_unreferenced_private_archive_cannot_enter_public_staging(self):
        recovery, updates, manifest = self.make_staging_fixture()
        (updates / 'private-recovery.zip').write_bytes(b'synthetic private fixture')
        with self.assertRaisesRegex(ValueError, 'unexpected files'):
            backup_release.stage(recovery, manifest)
        self.assertFalse((self.root / 'staging').exists())

    def test_staging_rejects_symlink_even_when_bytes_match(self):
        recovery, updates, manifest = self.make_staging_fixture()
        (updates / 'app.zip').unlink()
        (updates / 'app.zip').symlink_to(recovery / 'app.zip')
        with self.assertRaisesRegex(ValueError, 'symlinks'):
            backup_release.stage(recovery, manifest)
        self.assertFalse((self.root / 'staging').exists())

    def test_changed_notes_cannot_enter_public_staging(self):
        recovery, updates, manifest = self.make_staging_fixture()
        (updates / 'app.txt').write_text('Unsealed private notes.')
        with self.assertRaisesRegex(ValueError, 'differs'):
            backup_release.stage(recovery, manifest)
        self.assertFalse((self.root / 'staging').exists())


if __name__ == '__main__': unittest.main()
