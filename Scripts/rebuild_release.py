#!/usr/bin/env python3
"""Rebuild a sealed release with its original inputs; never publishes or installs."""
import argparse
import json
from pathlib import Path
import subprocess
import tarfile
from release_record import run, verify, write_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('recovery', type=Path)
    parser.add_argument('output', type=Path, help='New, empty build directory')
    parser.add_argument('--unsigned', action='store_true', help='Validate compilation without signing credentials')
    args = parser.parse_args()
    try:
        recovery, output = args.recovery.resolve(), args.output.resolve()
        manifest = verify(recovery)
        if manifest['kind'] != 'release':
            raise ValueError('Legacy records have no verified original source revision to rebuild.')
        toolchain = json.loads((recovery / 'toolchain.json').read_text())
        current = {'xcode': run('xcodebuild', '-version'), 'swift': run('xcrun', 'swiftc', '--version'),
                   'sdk': run('xcrun', '--sdk', 'macosx', '--show-sdk-version'),
                   'sdk_build': run('xcrun', '--sdk', 'macosx', '--show-sdk-build-version'),
                   'architecture': run('uname', '-m')}
        for key, value in current.items():
            if value != toolchain[key]: raise ValueError('Recorded toolchain does not match: ' + key)
        output.mkdir(parents=True, exist_ok=False)
        source = output / 'source'
        source.mkdir()
        with tarfile.open(recovery / 'source.tar.gz') as archive:
            archive.extractall(source, filter='data')
        # Retain dependency checkout history and the exact downloaded binary artifacts.
        run('ditto', '-x', '-k', recovery / 'SourcePackages.zip', output / 'DerivedData')
        command = json.loads((recovery / 'logs/archive-command.json').read_text())
        project_index = command.index('-project') + 1
        original_root = str(Path(command[project_index]).parent.parent)
        command = [value.replace(original_root + '/', str(output) + '/') for value in command]
        if args.unsigned:
            command = [value for value in command if not value.startswith(
                ('CODE_SIGN_IDENTITY=', 'DEVELOPMENT_TEAM=', 'CODE_SIGNING_ALLOWED=', 'CODE_SIGNING_REQUIRED='))]
            command[1:1] = ['CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO']
        write_json(output / 'rebuild-command.json', command)
        with (output / 'rebuild.log').open('w') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        print('Rebuilt archive: ' + str(output / 'CornerWheel.xcarchive'))
        print('Use the preserved download for exact original bytes and its original dSYMs for crash diagnosis.')
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
