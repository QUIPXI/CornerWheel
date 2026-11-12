#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
installed_app="$project_dir/Build/CornerWheel.app"
staged_app="$project_dir/Build/.CornerWheel.staged.app"
derived_data="${CORNERWHEEL_DERIVED_DATA:-/private/tmp/CornerWheelUpdateDerivedData}"
signing_identity="${CORNERWHEEL_SIGNING_IDENTITY:-CornerWheel Local Development}"

# Self-signed local identities have no Apple team for library validation of
# Sparkle. Keep their relaxed entitlement confined to Debug; Apple identities
# can use the hardened Release configuration. Both installed variants use
# optimized Swift code; ordinary Xcode Debug builds remain easy to debug.
# This script never distributes.
case "$signing_identity" in
    "Apple Development:"*|"Developer ID Application:"*) configuration=Release ;;
    *) configuration=Debug ;;
esac

archive_backup() {
    local backup_bundle="$1"
    local backup_archive="$project_dir/Build/Backups/$(basename "$backup_bundle").zip"
    mkdir -p "$project_dir/Build/Backups"
    if ditto -c -k --sequesterRsrc --keepParent "$backup_bundle" "$backup_archive" &&
       unzip -tqq "$backup_archive"; then
        rm -rf "$backup_bundle"
    else
        echo "Could not archive $backup_bundle; leaving it in place." >&2
    fi
}

# A code-hash (ad hoc) signature makes every build a new app to macOS privacy
# permissions. Refuse to replace the working installation without a persistent
# certificate-backed signing identity.
identities="$(security find-identity -v -p codesigning)"
if [[ "$identities" != *"\"$signing_identity\""* ]]; then
    echo "No valid code-signing identity named '$signing_identity' is available." >&2
    echo "The installed CornerWheel.app was not changed." >&2
    exit 1
fi

xcodebuild -quiet \
    -project "$project_dir/CornerWheel.xcodeproj" \
    -scheme CornerWheel \
    -configuration "$configuration" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    CODE_SIGN_IDENTITY="$signing_identity" \
    CODE_SIGNING_REQUIRED=YES \
    SWIFT_OPTIMIZATION_LEVEL=-O \
    SWIFT_COMPILATION_MODE=wholemodule \
    ENABLE_DEBUG_DYLIB=NO \
    build

source_app="$derived_data/Build/Products/$configuration/CornerWheel.app"
mkdir -p "$project_dir/Build"
rm -rf "$staged_app"
ditto "$source_app" "$staged_app"
# Xcode signs the embedded framework and app. Preserve its signing and Debug
# entitlements when staging rather than re-signing only the outer app bundle.
codesign --verify --deep --strict "$staged_app"
if ! cmp -s "$project_dir/Resources/ThirdPartyNotices.txt" "$staged_app/Contents/Resources/ThirdPartyNotices.txt"; then
    echo "The staged app is missing the complete third-party notices. The installed app was not changed." >&2
    exit 1
fi

new_requirement="$(codesign -dr - "$staged_app" 2>&1 | sed -n -e 's/^designated => //p' -e 's/^# designated => //p')"
if [[ -z "$new_requirement" || "$new_requirement" == cdhash* ]]; then
    echo "The staged app has no stable designated requirement." >&2
    exit 1
fi

if [[ -d "$installed_app" ]]; then
    old_requirement="$(codesign -dr - "$installed_app" 2>&1 | sed -n -e 's/^designated => //p' -e 's/^# designated => //p')"
    if [[ "$old_requirement" != cdhash* && "$old_requirement" != "$new_requirement" ]]; then
        echo "Signing identity changed; refusing to replace the installed app." >&2
        exit 1
    fi
fi

if command -v pgrep >/dev/null; then
    while IFS= read -r pid; do
        executable="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
        if [[ "$executable" == "$installed_app/Contents/MacOS/CornerWheel" ]]; then
            kill -TERM "$pid"
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                if ! kill -0 "$pid" 2>/dev/null; then break; fi
                sleep 0.2
            done
            if kill -0 "$pid" 2>/dev/null; then
                echo "CornerWheel did not exit; the installed app was not changed." >&2
                exit 1
            fi
        fi
    done < <(pgrep -x CornerWheel || true)
fi

backup_app=""
if [[ -d "$installed_app" ]]; then
    backup_app="$project_dir/Build/CornerWheel.$(date +%Y%m%d%H%M%S).backup"
    mv "$installed_app" "$backup_app"
fi
mv "$staged_app" "$installed_app"

launched=false
launched_pid=""
if codesign --verify --deep --strict "$installed_app" && open -a "$installed_app"; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        while IFS= read -r pid; do
            executable="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
            if [[ "$executable" == "$installed_app/Contents/MacOS/CornerWheel" ]]; then
                launched=true
                launched_pid="$pid"
                break
            fi
        done < <(pgrep -x CornerWheel || true)
        if [[ "$launched" == true ]]; then break; fi
        sleep 0.2
    done
fi
if [[ "$launched" == true ]]; then
    # A signing or loader failure can briefly create a process before it exits.
    sleep 3
    executable="$(ps -p "$launched_pid" -o comm= 2>/dev/null || true)"
    if [[ "$executable" != "$installed_app/Contents/MacOS/CornerWheel" ]]; then
        launched=false
    fi
fi
if [[ "$launched" != true ]]; then
    failed_app="$project_dir/Build/CornerWheel.$(date +%Y%m%d%H%M%S).failed.backup"
    mv "$installed_app" "$failed_app"
    if [[ -n "$backup_app" ]]; then
        mv "$backup_app" "$installed_app"
        open -a "$installed_app"
    fi
    archive_backup "$failed_app"
    echo "Update failed; the previous app was restored." >&2
    exit 1
fi

if [[ -n "$backup_app" ]]; then archive_backup "$backup_app"; fi

echo "Updated $installed_app"
echo "Local optimized $configuration build; not a notarized distribution release."
echo "Designated requirement: $new_requirement"
