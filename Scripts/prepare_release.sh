#!/bin/bash
# Prepare a signed, notarized Sparkle release. Never installs or publishes it.
set -euo pipefail
umask 077

usage() {
    cat <<'USAGE'
Usage: ./Scripts/prepare_release.sh --check | --prepare | --release

Required environment:
  CORNERWHEEL_RELEASE_VERSION       User-visible version, e.g. 1.1
  CORNERWHEEL_RELEASE_BUILD         Increasing positive integer, e.g. 2
  CORNERWHEEL_DEVELOPMENT_TEAM      Apple Developer Team ID
  CORNERWHEEL_SIGNING_IDENTITY      Exact Developer ID Application identity name
  CORNERWHEEL_NOTARY_PROFILE        Existing notarytool Keychain profile name
  CORNERWHEEL_UPDATE_FEED_URL       Public HTTPS URL ending in .xml
  CORNERWHEEL_DOWNLOAD_URL_PREFIX   Public HTTPS download directory, trailing /
  CORNERWHEEL_UPDATE_PUBLIC_KEY     Sparkle Ed25519 public key (base64)
  CORNERWHEEL_SPARKLE_BIN           Matching Sparkle 2.10.1 bin directory

Optional:
  CORNERWHEEL_SPARKLE_ACCOUNT       Sparkle Keychain account (default: CornerWheel)
  CORNERWHEEL_RELEASE_NOTES         Plain-text release notes file
  CORNERWHEEL_PREVIOUS_BUILD        Highest previously published build, if this
                                   machine has no complete release history
  CORNERWHEEL_BACKUP_REPOSITORY     Explicit private owner/repo for --release

--check validates local inputs and existing signing identities/keys, but does not
build or contact Apple. --prepare archives, exports, notarizes and seals files
locally under Build/Releases/history/ without a GitHub upload or staging.
Successful preparation also reserves the build with a local annotated Git tag.
--release also backs up to private GitHub and stages the verified files.
Staging requires a verified private GitHub backup.
It does not publish the update feed or replace the installed app.
See Docs/ReleasePreparation.md for setup and publishing instructions.
USAGE
}

case "${1:-}" in
    --check|--prepare|--release) mode="$1" ;;
    -h|--help|"") usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
release_root="$project_dir/Build/Releases"
export CORNERWHEEL_RELEASE_ROOT="$release_root"
export CORNERWHEEL_RELEASE_HELPERS="$script_dir"
export CORNERWHEEL_PROJECT_DIR="$project_dir"
export CORNERWHEEL_SPARKLE_ACCOUNT="${CORNERWHEEL_SPARKLE_ACCOUNT:-CornerWheel}"

for command_name in python3 xcodebuild xcrun security codesign ditto git; do
    command -v "$command_name" >/dev/null || { echo "Missing tool: $command_name" >&2; exit 1; }
done
if [[ "$mode" == --release ]]; then
    command -v gh >/dev/null || { echo "Missing tool: gh" >&2; exit 1; }
    [[ -n "${CORNERWHEEL_BACKUP_REPOSITORY:-}" ]] || {
        echo "Set CORNERWHEEL_BACKUP_REPOSITORY to an approved private owner/repo." >&2; exit 1;
    }
fi
python3 - <<'PY'
import sys, tarfile
if sys.version_info < (3, 11, 8) or not hasattr(tarfile, 'data_filter'):
    sys.exit('Release tools require Python 3.11.8 or later with tarfile data-filter support.')
PY
if [[ "$mode" == --release ]]; then
    python3 - "$script_dir" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from backup_release import backup_repository
try:
    backup_repository()
except ValueError as error:
    sys.exit(str(error))
PY
fi
python3 "$script_dir/release_record.py" check "$project_dir"

# Fail before building if configuration is incomplete or a build number repeats.
python3 - <<'PY'
import base64, os, pathlib, plistlib, re, subprocess, sys
sys.path.insert(0, os.environ['CORNERWHEEL_RELEASE_HELPERS'])
from check_update_host import filename_for, https_url, item_version, read_feed
required = ['RELEASE_VERSION', 'RELEASE_BUILD', 'DEVELOPMENT_TEAM', 'SIGNING_IDENTITY',
            'NOTARY_PROFILE', 'UPDATE_FEED_URL', 'DOWNLOAD_URL_PREFIX',
            'UPDATE_PUBLIC_KEY', 'SPARKLE_BIN']
missing = [f'CORNERWHEEL_{key}' for key in required if not os.environ.get(f'CORNERWHEEL_{key}')]
if missing:
    sys.exit('Missing release configuration:\n  ' + '\n  '.join(missing))
def value(key): return os.environ[f'CORNERWHEEL_{key}']
try:
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', value('RELEASE_VERSION')):
        raise ValueError('Release version must have two or three numeric components.')
    if not re.fullmatch(r'[1-9][0-9]*', value('RELEASE_BUILD')):
        raise ValueError('Release build must be a positive integer.')
    if not re.fullmatch(r'[A-Z0-9]{10}', value('DEVELOPMENT_TEAM')):
        raise ValueError('Development team must be a 10-character Apple Team ID.')
    identity = value('SIGNING_IDENTITY')
    if not identity.startswith('Developer ID Application: ') or not identity.endswith('(' + value('DEVELOPMENT_TEAM') + ')'):
        raise ValueError('Use the exact Developer ID Application identity for this Team ID.')
    key = value('UPDATE_PUBLIC_KEY')
    if len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError('Sparkle public key must decode to 32 bytes.')
    feed_name = filename_for(value('UPDATE_FEED_URL'))
    if not feed_name.endswith('.xml'):
        raise ValueError('Feed URL must end in .xml.')
    prefix = value('DOWNLOAD_URL_PREFIX')
    https_url(prefix)
    if not prefix.endswith('/'):
        raise ValueError('Download URL prefix must end in /.')
    for text in [value('UPDATE_FEED_URL'), prefix]:
        if '$' in text or '"' in text or "'" in text or '\\' in text:
            raise ValueError('Percent-encode special characters in update URLs.')
    for name in ['generate_keys', 'generate_appcast', 'sign_update']:
        if not os.access(pathlib.Path(value('SPARKLE_BIN')) / name, os.X_OK):
            raise ValueError('Sparkle bin directory must contain executable ' + name + '.')
    distribution = pathlib.Path(value('SPARKLE_BIN')).parent
    manifests = [distribution / 'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Resources/Info.plist',
                 distribution / 'Sparkle.framework/Resources/Info.plist']
    manifest = next((path for path in manifests if path.is_file()), None)
    if manifest is None or plistlib.loads(manifest.read_bytes()).get('CFBundleShortVersionString') != '2.10.1':
        raise ValueError('Use the bin directory from the pinned Sparkle 2.10.1 distribution.')
    notes = os.environ.get('CORNERWHEEL_RELEASE_NOTES')
    if notes and not pathlib.Path(notes).is_file():
        raise ValueError('Release notes file does not exist.')
    previous = os.environ.get('CORNERWHEEL_PREVIOUS_BUILD', '1')
    if not re.fullmatch(r'[0-9]+', previous):
        raise ValueError('Previous build must be a nonnegative integer.')
    previous = int(previous)
    tags = subprocess.check_output(['git', '-C', os.environ['CORNERWHEEL_PROJECT_DIR'],
                                    'tag', '--list', 'v*-build.*'], text=True)
    for tag in tags.splitlines():
        match = re.fullmatch(r'v[0-9.]+-build\.([1-9][0-9]*)', tag)
        if match: previous = max(previous, int(match.group(1)))
    root = pathlib.Path(os.environ['CORNERWHEEL_RELEASE_ROOT'])
    history = root / 'history'
    if history.exists():
        for directory in history.iterdir():
            if directory.name.isdigit(): previous = max(previous, int(directory.name))
    feed = root / 'staging' / feed_name
    if feed.exists():
        previous = max(previous, max(item_version(item) for item in read_feed(feed.read_bytes())))
    elif (root / 'staging').exists() and any((root / 'staging').iterdir()):
        raise ValueError('Existing staging uses a different feed; do not change its URL silently.')
    if int(value('RELEASE_BUILD')) <= previous:
        raise ValueError(f'Release build must be greater than previous build {previous}.')
except (ValueError, OSError) as error:
    sys.exit('Release configuration invalid: ' + str(error))
print('Release configuration is valid.')
PY

signing_identity="$CORNERWHEEL_SIGNING_IDENTITY"
identities="$(security find-identity -v -p codesigning)"
if [[ "$identities" != *"\"$signing_identity\""* ]]; then
    echo "The configured Developer ID Application identity is not available with a private key." >&2
    exit 1
fi
sparkle_bin="$CORNERWHEEL_SPARKLE_BIN"
# Lookup only: this never generates, exports, or replaces a key.
stored_public_key="$("$sparkle_bin/generate_keys" --account "$CORNERWHEEL_SPARKLE_ACCOUNT" -p)"
if [[ "$stored_public_key" != "$CORNERWHEEL_UPDATE_PUBLIC_KEY" ]]; then
    echo "The configured public key does not match the Sparkle Keychain account." >&2
    exit 1
fi
if [[ "$mode" == --check ]]; then
    echo "Preflight passed. Notarization credentials will be checked with Apple during --prepare or --release."
    exit 0
fi

mkdir -p "$release_root/history"
lock_dir="$release_root/.prepare.lock"
mkdir "$lock_dir" 2>/dev/null || { echo "Another release is preparing, or a stale .prepare.lock needs review." >&2; exit 1; }
work_dir=""
finish() {
    local status=$?
    rmdir "$lock_dir" 2>/dev/null || true
    if [[ $status -ne 0 && -n "$work_dir" ]]; then
        echo "Release stopped. Working files and logs remain at: $work_dir" >&2
    fi
}
trap finish EXIT
work_dir="$(mktemp -d "$release_root/.prepare.XXXXXX")"
mkdir -p "$work_dir/logs" "$work_dir/updates"
source_revision="$(python3 "$script_dir/release_record.py" snapshot "$work_dir")"
source_dir="$work_dir/source"
script_dir="$source_dir/Scripts"
export CORNERWHEEL_RELEASE_HELPERS="$script_dir"
if [[ -d "$release_root/staging" ]]; then
    ditto "$release_root/staging" "$work_dir/updates"
fi
feed_name="$(python3 -c 'import os,sys; sys.path.insert(0, os.environ["CORNERWHEEL_RELEASE_HELPERS"]); from check_update_host import filename_for; print(filename_for(os.environ["CORNERWHEEL_UPDATE_FEED_URL"]))')"
archive_name="CornerWheel-${CORNERWHEEL_RELEASE_VERSION}-${CORNERWHEEL_RELEASE_BUILD}-arm64.zip"
archive_path="$work_dir/CornerWheel.xcarchive"
export_path="$work_dir/export"
export CORNERWHEEL_EXPORT_OPTIONS="$work_dir/ExportOptions.plist"
python3 - <<'PY'
import os, plistlib
with open(os.environ['CORNERWHEEL_EXPORT_OPTIONS'], 'wb') as stream:
    plistlib.dump({'method': 'developer-id', 'destination': 'export',
                  'teamID': os.environ['CORNERWHEEL_DEVELOPMENT_TEAM'],
                  'signingStyle': 'manual',
                  'signingCertificate': os.environ['CORNERWHEEL_SIGNING_IDENTITY']}, stream)
PY

run_step() {
    local label="$1" log_name="$2"
    shift 2
    echo "$label"
    if ! "$@" >"$work_dir/logs/$log_name" 2>&1; then
        tail -n 50 "$work_dir/logs/$log_name" >&2
        return 1
    fi
}

build_arguments=(
    -project "$source_dir/CornerWheel.xcodeproj" -scheme CornerWheel
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$work_dir/DerivedData" -archivePath "$archive_path" \
    -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution \
    "DEVELOPMENT_TEAM=$CORNERWHEEL_DEVELOPMENT_TEAM" "CODE_SIGN_IDENTITY=$signing_identity" \
    CODE_SIGN_STYLE=Manual CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
    ENABLE_HARDENED_RUNTIME=YES ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    DEBUG_INFORMATION_FORMAT=dwarf-with-dsym GCC_GENERATE_DEBUGGING_SYMBOLS=YES \
    "CORNERWHEEL_SOURCE_REVISION=$source_revision" \
    "MARKETING_VERSION=$CORNERWHEEL_RELEASE_VERSION" "CURRENT_PROJECT_VERSION=$CORNERWHEEL_RELEASE_BUILD" \
    "CORNERWHEEL_UPDATE_FEED_URL=$CORNERWHEEL_UPDATE_FEED_URL" \
    "CORNERWHEEL_UPDATE_PUBLIC_KEY=$CORNERWHEEL_UPDATE_PUBLIC_KEY"
)
python3 - "$work_dir/logs/archive-command.json" "${build_arguments[@]}" <<'PY'
import json, sys
with open(sys.argv[1], 'w') as stream:
    json.dump(['xcodebuild', *sys.argv[2:], 'archive'], stream, indent=2)
PY
run_step "Recording effective build settings…" build-settings.json \
    xcodebuild "${build_arguments[@]}" -showBuildSettings -json
run_step "Archiving the committed Release source…" archive.log \
    xcodebuild "${build_arguments[@]}" archive
run_step "Exporting with Developer ID signing…" export.log \
    xcodebuild -exportArchive -archivePath "$archive_path" -exportPath "$export_path" \
    -exportOptionsPlist "$CORNERWHEEL_EXPORT_OPTIONS"
app_path="$export_path/CornerWheel.app"
export CORNERWHEEL_EXPORTED_APP="$app_path"
codesign --verify --deep --strict "$app_path"
python3 - <<'PY'
import os, pathlib, plistlib, subprocess, sys
app = pathlib.Path(os.environ['CORNERWHEEL_EXPORTED_APP'])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
expected = {'CFBundleIdentifier': 'com.cornerwheel.CornerWheel',
            'CFBundleShortVersionString': os.environ['CORNERWHEEL_RELEASE_VERSION'],
            'CFBundleVersion': os.environ['CORNERWHEEL_RELEASE_BUILD'],
            'SUFeedURL': os.environ['CORNERWHEEL_UPDATE_FEED_URL'],
            'SUPublicEDKey': os.environ['CORNERWHEEL_UPDATE_PUBLIC_KEY'],
            'SUVerifyUpdateBeforeExtraction': True}
for key, value in expected.items():
    if info.get(key) != value: sys.exit('Exported app has unexpected ' + key)
if any(key.startswith('CornerWheelLicense') for key in info):
    sys.exit('The free app must not contain legacy payment-provider license configuration.')
if not (app / 'Contents/Frameworks/Sparkle.framework').is_dir():
    sys.exit('Exported app is missing Sparkle.framework.')
notice = app / 'Contents/Resources/ThirdPartyNotices.txt'
source_notice = pathlib.Path(os.environ['CORNERWHEEL_RELEASE_HELPERS']).parent / 'Resources/ThirdPartyNotices.txt'
if not notice.is_file() or notice.read_bytes() != source_notice.read_bytes():
    sys.exit('Exported app must include the complete third-party notices from this source revision.')
license_file = app / 'Contents/Resources/LICENSE'
source_license = pathlib.Path(os.environ['CORNERWHEEL_RELEASE_HELPERS']).parent / 'LICENSE'
if not license_file.is_file() or license_file.read_bytes() != source_license.read_bytes():
    sys.exit('Exported app must include the project LICENSE from this source revision.')
details = subprocess.run(['codesign', '-dvv', str(app)], capture_output=True, check=True).stderr.decode()
if ('Authority=Developer ID Application:' not in details or
    'TeamIdentifier=' + os.environ['CORNERWHEEL_DEVELOPMENT_TEAM'] not in details or
    'runtime' not in details):
    sys.exit('Exported app must use the expected Developer ID team and hardened runtime.')
entitlement_data = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)],
                                capture_output=True, check=True).stdout
entitlements = plistlib.loads(entitlement_data) if entitlement_data.strip() else {}
for forbidden in ['com.apple.security.cs.disable-library-validation', 'com.apple.security.get-task-allow']:
    if entitlements.get(forbidden): sys.exit('Production app includes forbidden entitlement: ' + forbidden)
architectures = subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/CornerWheel')]).decode().split()
if architectures != ['arm64']: sys.exit('This release workflow requires an Apple silicon-only app.')
PY

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$work_dir/notarization.zip"
run_step "Submitting the signed app to Apple for notarization…" notarization.json \
    xcrun notarytool submit "$work_dir/notarization.zip" \
    --keychain-profile "$CORNERWHEEL_NOTARY_PROFILE" --wait --output-format json
python3 - "$work_dir/logs/notarization.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream: result = json.load(stream)
if result.get('status') != 'Accepted':
    sys.exit('Apple did not accept this release. Inspect notarization.json and use notarytool log for details.')
PY
run_step "Stapling Apple's notarization ticket…" staple.log xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
codesign --verify --deep --strict "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"
# Stapling changes the bundle: create the final archive only now.
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$work_dir/updates/$archive_name"
if [[ -n "${CORNERWHEEL_RELEASE_NOTES:-}" ]]; then
    cp "$CORNERWHEEL_RELEASE_NOTES" "$work_dir/updates/${archive_name%.zip}.txt"
fi
run_step "Generating signed update metadata…" appcast.log \
    "$sparkle_bin/generate_appcast" --account "$CORNERWHEEL_SPARKLE_ACCOUNT" \
    --download-url-prefix "$CORNERWHEEL_DOWNLOAD_URL_PREFIX" \
    --embed-release-notes --maximum-versions 0 --maximum-deltas 0 \
    -o "$work_dir/updates/$feed_name" "$work_dir/updates"
python3 "$script_dir/check_update_host.py" "$CORNERWHEEL_UPDATE_FEED_URL" \
    --local-directory "$work_dir/updates" --expected-build "$CORNERWHEEL_RELEASE_BUILD"
signature="$(python3 - "$work_dir/updates/$feed_name" <<'PY'
import os, sys
sys.path.insert(0, os.environ['CORNERWHEEL_RELEASE_HELPERS'])
from check_update_host import SPARKLE, item_version, read_feed
with open(sys.argv[1], 'rb') as stream: items = read_feed(stream.read())
item = next(item for item in items if item_version(item) == int(os.environ['CORNERWHEEL_RELEASE_BUILD']))
print(item.find('enclosure').get(SPARKLE + 'edSignature'))
PY
)"
"$sparkle_bin/sign_update" --account "$CORNERWHEEL_SPARKLE_ACCOUNT" --verify \
    "$work_dir/updates/$archive_name" "$signature"
python3 "$script_dir/release_record.py" seal "$work_dir" \
    --package "$work_dir/updates/$archive_name" --project "$project_dir"

history_path="$release_root/history/$CORNERWHEEL_RELEASE_BUILD"
[[ ! -e "$history_path" ]] || { echo "Build history already exists; refusing to overwrite it." >&2; exit 1; }
mv "$work_dir" "$history_path"
work_dir="$history_path"
if [[ "$mode" == --prepare ]]; then
    echo "Signed, notarized release sealed locally at: $history_path"
    echo "Private backup and staging remain pending. Nothing was uploaded to GitHub, published or installed."
    exit 0
fi
python3 "$history_path/source/Scripts/backup_release.py" "$history_path/recovery" \
    --project "$project_dir" --stage
echo "Release prepared at: $release_root/staging"
echo "Upload archives first and the feed last. Nothing was published or installed."
