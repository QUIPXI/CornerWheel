# Contributing to CornerWheel

CornerWheel is a small native macOS window switcher. Keep changes focused and preserve the existing corner interaction, settings, translucent appearance and per-window identity. See [ROADMAP.md](ROADMAP.md) before proposing a larger change: actual window-content previews remain incomplete, and release preparation does not replace the current UI.

## Set up and validate

Use macOS 14 or later and full Xcode with a macOS SDK. Xcode 27.0 / Swift 6.4 is the locally checked toolchain; the project uses Swift 5 language mode. The current binary distribution targets Apple silicon. Python 3.11.8 or later is needed for the release-tool tests and helpers. No Apple Developer account, payment service, website checkout or private release configuration is required.

From the checkout root:

```sh
xcodebuild -project CornerWheel.xcodeproj -scheme CornerWheel \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath Build/DerivedData \
  -onlyUsePackageVersionsFromResolvedFile build

xcodebuild -project CornerWheel.xcodeproj -scheme CornerWheel \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath Build/DerivedData \
  -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO test

python3 -m unittest discover -s Tests/ReleaseTools -v
git diff --check
```

The app is at `Build/DerivedData/Build/Products/Debug/CornerWheel.app`. Build/test uses ad-hoc signing; the unit-test host avoids starting pointer monitoring or window discovery on your desktop. XCTest covers pure layout, MRU ordering, scrolling, filtering, state transitions and permission/update gates. It does not establish live interaction with arbitrary applications.

The shared scheme and lockfile are committed. Keep Sparkle pinned unless the change deliberately updates it and its notices. XcodeGen 2.45.3 or later is optional: after changing `project.yml` or adding/removing source files, run `xcodegen generate --spec project.yml` and review the project/scheme diff. Preserve the macOS 14.0 deployment target.

The GitHub Actions workflow builds and tests without release credentials. Hosted CI results only exist after the workflow runs; a local pass is not a hosted-CI result. For manual changes use [Docs/ManualTestChecklist.md](Docs/ManualTestChecklist.md), recording only checks you actually perform.

## Architecture map

| Responsibility | Files |
| --- | --- |
| App lifecycle, existing status menu and Settings presentation | `Sources/CornerWheel/App/CornerWheelApp.swift` |
| Preference persistence and login item | `Sources/CornerWheel/App/SettingsStore.swift` |
| Activation/dismissal gates and session orchestration | `Sources/CornerWheel/App/CornerWheelCoordinator.swift`, `Sources/CornerWheel/App/CornerTriggerController.swift` |
| Display coordinates, arc placement, scroll/selection and recent order | `Sources/CornerWheel/Core/DisplayGeometry.swift`, `ArcLayoutEngine.swift`, `CarouselController.swift`, `MRUTracker.swift` |
| Window identity, Accessibility discovery and actions | `Sources/CornerWheel/Services/WindowModels.swift`, `AccessibilityWindowStore.swift`, `WindowCatalog.swift`, `WindowActivationService.swift` |
| Permissions and existing Sparkle updates | `Sources/CornerWheel/Services/PermissionManager.swift`, `AppUpdateController.swift` |
| AppKit panel, SwiftUI cards, Settings and sliders | `Sources/CornerWheel/UI/OverlayPanelController.swift`, `OverlayView.swift`, `SettingsView.swift`, `DefaultSlider.swift` |
| Native tests / release-tool tests | `Tests/CornerWheelTests/`, `Tests/ReleaseTools/test_release_record.py` |
| Build metadata, entitlements and notices | `project.yml`, `Resources/Info.plist`, `Resources/Debug.entitlements`, `Resources/ThirdPartyNotices.txt` |

The website is maintained separately and is not needed to build the native app. This source tree contains the native app and its public contributor documentation.

## Code and pull requests

- Follow nearby Swift formatting (four spaces) and naming. Keep AppKit/SwiftUI state on the main actor and Accessibility work within its existing isolation boundary.
- Keep window identity independent of titles and application identity. Browsing must not change observed MRU order. Revalidate an exact window before acting on it.
- Use public macOS APIs. Avoid new dependencies, private APIs, global keyboard recording, analytics and unrelated UI changes.
- Add a focused regression test for changed logic when practical; avoid tests that manipulate arbitrary user applications. Documentation-only changes do not need new tests.
- Explain the problem, user-visible result and validation. Distinguish automated passes, manual observations and checks not run. For UI changes use disposable sample windows and remove private content from media.
- Keep credentials, build output, personal release settings and logs out of commits. Inspect `git diff` and consult [PRIVACY.md](PRIVACY.md) before sharing diagnostics.
- Preserve third-party notices. Contributions to project-owned code are under the repository's [MIT license](LICENSE); only contribute material you are authorized to share and identify external sources/assets.

No formatting migration, contributor agreement or large test framework is required. Use the issue and PR templates when available. Handle sensitive findings according to [SECURITY.md](SECURITY.md), not a public bug report.

## Release work

Contributors do not need the maintainer's signing identity, update private key, notarization profile or recovery repository. See [Docs/ReleasePreparation.md](Docs/ReleasePreparation.md) for the separate release path. Do not run upload, backup, signing, tagging or notarization commands as a routine build check.
