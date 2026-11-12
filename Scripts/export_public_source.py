#!/usr/bin/env python3
"""Prepare a reviewed source-only copy; never change Git or contact a remote."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tempfile
from urllib.parse import unquote, urlsplit


# Exact paths are intentional: adding source/assets requires a review of this list.
PUBLIC_FILES = tuple("""
.gitignore
.github/ISSUE_TEMPLATE/bug_report.md
.github/ISSUE_TEMPLATE/feature_request.md
.github/PULL_REQUEST_TEMPLATE.md
.github/workflows/ci.yml
CONTRIBUTING.md
LICENSE
PRIVACY.md
README.md
ROADMAP.md
SECURITY.md
THIRD_PARTY_NOTICES.md
project.yml
CornerWheel.xcodeproj/project.pbxproj
CornerWheel.xcodeproj/project.xcworkspace/contents.xcworkspacedata
CornerWheel.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
CornerWheel.xcodeproj/xcshareddata/xcschemes/CornerWheel.xcscheme
Docs/ManualTestChecklist.md
Docs/PublicSourcePreparation.md
Docs/ReleasePreparation.md
Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-16.png
Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-32.png
Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-64.png
Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-128.png
Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png
Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-512.png
Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
Resources/Assets.xcassets/AppIcon.appiconset/Contents.json
Resources/Assets.xcassets/Contents.json
Resources/Debug.entitlements
Resources/Info.plist
Resources/ThirdPartyNotices.txt
Scripts/backup_release.py
Scripts/benchmark_performance.py
Scripts/build_update.sh
Scripts/check_update_host.py
Scripts/export_public_source.py
Scripts/make_app_icon.swift
Scripts/prepare_release.sh
Scripts/rebuild_release.py
Scripts/release.env
Scripts/release_record.py
Sources/CornerWheel/App/CornerTriggerController.swift
Sources/CornerWheel/App/CornerWheelApp.swift
Sources/CornerWheel/App/CornerWheelCoordinator.swift
Sources/CornerWheel/App/SettingsStore.swift
Sources/CornerWheel/Core/ArcLayoutEngine.swift
Sources/CornerWheel/Core/CarouselController.swift
Sources/CornerWheel/Core/DisplayGeometry.swift
Sources/CornerWheel/Core/MRUTracker.swift
Sources/CornerWheel/Services/AccessibilityWindowStore.swift
Sources/CornerWheel/Services/AppUpdateController.swift
Sources/CornerWheel/Services/PermissionManager.swift
Sources/CornerWheel/Services/WindowActivationService.swift
Sources/CornerWheel/Services/WindowCatalog.swift
Sources/CornerWheel/Services/WindowModels.swift
Sources/CornerWheel/UI/AboutCornerWheelView.swift
Sources/CornerWheel/UI/DefaultSlider.swift
Sources/CornerWheel/UI/OverlayPanelController.swift
Sources/CornerWheel/UI/OverlayView.swift
Sources/CornerWheel/UI/SettingsView.swift
Tests/CornerWheelTests/AXWindowEligibilityTests.swift
Tests/CornerWheelTests/ArcLayoutEngineTests.swift
Tests/CornerWheelTests/CarouselAndMRUTests.swift
Tests/CornerWheelTests/CoordinatorLifecycleTests.swift
Tests/CornerWheelTests/OverlayOptimizationTests.swift
Tests/CornerWheelTests/SettingsAndTriggerTests.swift
Tests/CornerWheelTests/UpdateConfigurationTests.swift
Tests/Performance/CompareImages.swift
Tests/Performance/PerformanceHarness.swift
Tests/ReleaseTools/test_export_public_source.py
Tests/ReleaseTools/test_release_record.py
""".split())

STRICT_ROOTS = ("Sources", "Resources", "Tests", "Scripts",
                "CornerWheel.xcodeproj", ".github")
EXCLUDED_FILES = {"Scripts/backup_project.sh", "Scripts/release.local.env"}
GENERATED_DIRECTORIES = {"__pycache__", "xcuserdata"}
GENERATED_PATHS = {"CornerWheel.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration"}
START = "<!-- public-source:exclude:start -->"
END = "<!-- public-source:exclude:end -->"


class ExportError(ValueError):
    pass


def relative_path(value):
    path = PurePosixPath(value)
    if (not value or path.is_absolute() or "\\" in value
            or any(part in {"..", ".", ".git"} for part in value.split("/"))):
        raise ExportError(f"Unsafe source path: {value!r}")
    return path


def assert_no_symlinks(root, relative):
    current = root
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            raise ExportError(f"Symlink is not an approved input/output: {relative}")


def validate_layout(root):
    allowed = set(PUBLIC_FILES)
    if len(allowed) != len(PUBLIC_FILES):
        raise ExportError("The source allowlist contains duplicate paths.")
    for path in allowed:
        relative_path(path)
    for folder in STRICT_ROOTS:
        start = root / folder
        if not start.is_dir() or start.is_symlink():
            raise ExportError(f"Missing or symlinked source directory: {folder}")
        for current, directories, files in os.walk(start, followlinks=False):
            for name in list(directories):
                path = Path(current) / name
                relative = path.relative_to(root).as_posix()
                if path.is_symlink():
                    raise ExportError(f"Symlink in source layout: {relative}")
                if name in GENERATED_DIRECTORIES or relative in GENERATED_PATHS:
                    directories.remove(name)
                elif not any(p.startswith(relative + "/") for p in allowed | EXCLUDED_FILES):
                    raise ExportError(f"Unreviewed source directory: {relative}")
            for name in files:
                path = Path(current) / name
                relative = path.relative_to(root).as_posix()
                if path.is_symlink():
                    raise ExportError(f"Symlink in source layout: {relative}")
                if name == ".DS_Store" or relative in EXCLUDED_FILES:
                    continue
                if relative not in allowed:
                    raise ExportError(f"Unreviewed source file: {relative}; update the allowlist deliberately.")


def strip_private_blocks(text):
    lines = []
    inside = False
    for line in text.splitlines(keepends=True):
        if line.strip() == START:
            if inside:
                raise ExportError("Nested public-source exclusion markers.")
            inside = True
        elif line.strip() == END:
            if not inside:
                raise ExportError("Unmatched public-source exclusion end marker.")
            inside = False
        elif START in line or END in line:
            raise ExportError("Public-source exclusion markers must occupy their own lines.")
        elif not inside:
            lines.append(line)
    if inside:
        raise ExportError("Unclosed public-source exclusion marker.")
    return "".join(lines)


def replace_reviewed(text, before, after):
    """Allow original or already-projected input, but fail on ambiguous edits."""
    count = text.count(before)
    if count == 1:
        return text.replace(before, after, 1)
    if count == 0 and after and text.count(after) == 1:
        return text
    raise ExportError("A reviewed public projection changed; review the source and projection together.")


def public_content(path, data):
    if path.endswith(".md"):
        text = strip_private_blocks(data.decode("utf-8"))
        if path == "CONTRIBUTING.md":
            text = replace_reviewed(text,
                "`Website/` is an ignored, separate repository and is not needed to build the native app. Existing `Docs/` owner/release audits are dated records and can reference private evidence; they are not all current contributor instructions.",
                "The website is maintained separately and is not needed to build the native app. This source tree contains the native app and its public contributor documentation.")
        elif path == "SECURITY.md":
            text = replace_reviewed(text,
                "[Docs/PublicationAudit.md](Docs/PublicationAudit.md) records the scope and limitations of the local publication scan. It is not a guarantee that the repository contains no secrets or vulnerabilities.",
                "Source exports use the reviewed allowlist in `Scripts/export_public_source.py`. An export or secret scan is not a guarantee that the repository contains no secrets or vulnerabilities.")
        elif path == "Docs/ReleasePreparation.md":
            text = replace_reviewed(text,
                "Resolve the [publication audit](PublicationAudit.md), product limitations and manual acceptance checklist before distributing a new build.",
                "Review the [roadmap](../ROADMAP.md), source-publication checks and manual acceptance checklist before distributing a new build.")
            text = replace_reviewed(text,
                "Existing machine-specific settings were preserved in the ignored local file during release preparation; review its old version/build before any future release.",
                "Review any existing local file's version/build before a future release.")
            row = "| `backup_project.sh` | Legacy owner-specific helper that pushes all branches and tags to the two named private native/website repositories. It is not a contributor build step; it will refuse those destinations if made public. |\n"
            if row in text:
                text = text.replace(row, "", 1)
            elif "backup_project.sh` |" in text:
                raise ExportError("The owner-specific backup helper description changed; review it.")
            text = replace_reviewed(text,
                "After an explicitly authorized preparation, follow [Updates](Updates.md) for uploading the exact final ZIP first and the feed last. Verify hosted bytes and complete the real two-version update test on a separate test account/Mac. [Release recovery](ReleaseRecovery.md) explains retention and rebuilding. No signing, notarization, tag creation, upload, installation or public release is performed merely by adding this guide or CI.",
                "After an explicitly authorized preparation, upload the verified final ZIP and release notes to the configured HTTPS host first, then publish the signed feed. Verify the hosted bytes with `Scripts/check_update_host.py` and complete a real two-version update test on a separate test account/Mac. Retain recovery archives privately; `Scripts/rebuild_release.py --help` describes the separate rebuild tool. Never attach a recovery archive to a public release. No signing, notarization, tag creation, upload, installation or public release is performed merely by adding this guide or CI.")
        # The omitted owner-only helper is not a public CI/build dependency.
        text = text.replace(" Scripts/backup_project.sh", "")
        return text.encode("utf-8")
    if path == ".github/workflows/ci.yml":
        return data.replace(b" Scripts/backup_project.sh", b"")
    if path == "Scripts/prepare_release.sh":
        return data.replace(b"See Docs/Updates.md for one-time setup and publishing instructions.",
                            b"See Docs/ReleasePreparation.md for setup and publishing instructions.")
    return data


def validate_links(contents):
    for name, data in contents.items():
        if not name.endswith(".md"):
            continue
        for match in re.finditer(r"\]\((?:<([^>]+)>|([^\s)]+))\)", data.decode("utf-8")):
            link = match.group(1) or match.group(2)
            parsed = urlsplit(link)
            if parsed.scheme or parsed.netloc or not parsed.path:
                continue
            link_path = unquote(parsed.path)
            if link_path.startswith("/"):
                raise ExportError(f"Absolute local Markdown link in {name}.")
            parts = list(PurePosixPath(name).parent.parts)
            for part in link_path.split("/"):
                if part == "..":
                    if not parts:
                        raise ExportError(f"Markdown link leaves source tree in {name}.")
                    parts.pop()
                elif part not in {"", "."}:
                    parts.append(part)
            target = "/".join(parts)
            if target not in contents and not any(p.startswith(target + "/") for p in contents):
                raise ExportError(f"Broken public Markdown link in {name}: {link}")


def prepare_contents(root):
    validate_layout(root)
    contents, records, modes = {}, [], {}
    for name in sorted(PUBLIC_FILES):
        relative = relative_path(name)
        assert_no_symlinks(root, relative)
        path = root / relative
        if not path.is_file():
            raise ExportError(f"Missing approved source file: {name}")
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as source:
            source_stat = os.fstat(source.fileno())
            if not stat.S_ISREG(source_stat.st_mode):
                raise ExportError(f"Not a regular source file: {name}")
            original = source.read()
        exported = public_content(name, original)
        contents[name] = exported
        modes[name] = 0o755 if source_stat.st_mode & stat.S_IXUSR else 0o644
        records.append({"path": name, "source_sha256": hashlib.sha256(original).hexdigest(),
                        "export_sha256": hashlib.sha256(exported).hexdigest(),
                        "projected": original != exported})
    validate_links(contents)
    return contents, records, modes


def export_source(root, name):
    root = Path(root).resolve(strict=True)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name) or ".." in name:
        raise ExportError("Export name must be a simple directory name, without traversal or separators.")
    base_relative = PurePosixPath("Build/PublicSource")
    assert_no_symlinks(root, base_relative)
    base = root / base_relative
    target = base / name
    report = base / (name + ".review.json")
    if target.exists() or target.is_symlink() or report.exists() or report.is_symlink():
        raise ExportError("Export or review report already exists; choose a new name. Nothing was overwritten.")
    contents, records, modes = prepare_contents(root)
    base.mkdir(parents=True, exist_ok=True)
    assert_no_symlinks(root, base_relative)
    temporary = Path(tempfile.mkdtemp(prefix=".source-export-", dir=base))
    try:
        for path, data in contents.items():
            destination = temporary / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            destination.chmod(modes[path])
        # mkdir is exclusive, so a concurrent invocation cannot replace an export.
        target.mkdir()
        for item in temporary.iterdir():
            item.rename(target / item.name)
        report_data = {"format": 1, "file_count": len(records), "files": records,
                       "notes": ["No Git history or metadata is included.",
                                 "This is a local copy, not a published or signed release.",
                                 "Review this report outside the public source directory."]}
        with report.open("x") as stream:
            json.dump(report_data, stream, indent=2, sort_keys=True)
            stream.write("\n")
    finally:
        shutil.rmtree(temporary)
    return target, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", default="source-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
                        help="New directory name under ignored Build/PublicSource (default: UTC timestamp).")
    args = parser.parse_args()
    try:
        target, report = export_source(Path(__file__).resolve().parents[1], args.name)
    except (ExportError, OSError, UnicodeError) as error:
        parser.exit(1, f"Public source export failed: {error}\n")
    print(f"Prepared {target}")
    print(f"Review manifest: {report}")
    print("No repository, commit, tag, remote, visibility, signing, or release was changed.")


if __name__ == "__main__":
    main()
