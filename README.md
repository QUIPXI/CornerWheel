# CornerWheel

**Your windows, one corner away.**

CornerWheel is a free, native macOS window switcher built with Swift, AppKit and SwiftUI. Hover at a configured bottom screen corner to open a translucent quarter-circle of upright window cards, browse with the mouse wheel or trackpad, and click a card to bring its window forward. Each eligible window is a separate entry, including multiple windows from one app. There are no accounts, subscriptions, advertisements or paywalls in the native app.

> **Release scope:** this release uses application icons and window titles in upright cards, with one full card and up to two partly visible neighbors. The maintainer approved releasing this existing presentation. Actual window-content previews are a separately scoped future feature; this checkout does not provide them. See [release readiness and roadmap](ROADMAP.md).

## Implemented behavior

- Bottom-left or bottom-right corner activation, on the main display or all displays.
- Per-window identity and observed most-recently-used ordering, frozen while browsing.
- Continuous wheel/trackpad browsing; upright rectangular cards along a quarter-circle arc.
- Click to activate the selected window, with Accessibility validation and an error when the operation cannot be completed.
- Right-click or Control-click a card for **Show Window**, **Minimize Window** / **Restore Window**, and **Close Window**. The target app handles save confirmations. VoiceOver exposes minimize/restore and close actions.
- Pointer-leave dismissal with the existing grace period; Escape and empty-area dismissal. After dismissal with the pointer still inside, re-entry protection keeps the wheel hidden until it leaves the interaction area and returns; an outside dismissal permits a direct return.
- Configurable detection area, card size, hover delay, scroll direction/sensitivity, excluded apps, minimized windows, appearance and launch at login.
- Existing menu-bar controls and optional Sparkle updates. CornerWheel has no Dock icon and does not replace or reconfigure the Dock.

## Requirements

- **macOS 14.0 or later**, as declared by the app target and release feed.
- The existing distributed ZIP is **Apple silicon (arm64)**. Intel source builds and execution have not been verified for this preparation.
- **Accessibility permission** for window discovery and user-selected actions. Screen Recording is neither requested nor used by the current implementation.
- To build: full **Xcode** with a macOS SDK, Git, and network access for the pinned Swift package. This preparation uses Xcode 27.0 / Swift 6.4 in the project's Swift 5 language mode. Older Xcode versions have not been validated here.
- **Python 3.11.8 or later** for release-tool tests and helpers. **XcodeGen 2.45.3 or later** is needed only to regenerate the checked-in project after changing `project.yml` or its source list.

Sparkle **2.10.1** is the only Swift package. Its exact version is declared in `project.yml` and recorded in `CornerWheel.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. Keep the lockfile committed.

## Install the release

Download [CornerWheel 1.1 build 7 for Apple silicon](https://updates.cornerwheel.com/CornerWheel-1.1-7-arm64.zip), requiring **macOS 14.0 or later**. The app is signed with Developer ID and notarized by Apple. This release was built from [source commit 01fed513](https://github.com/QUIPXI/CornerWheel/commit/01fed513996238a209764ba0c4a5881d72ecd90b); the app's existing updater uses the [update feed](https://updates.cornerwheel.com/appcast.xml). Fresh-account installation and a real two-version Sparkle update have not been verified for this release.


Download and expand the ZIP, move `CornerWheel.app` to Applications, and open it. Follow Settings to approve Accessibility, then return and recheck permission. macOS may require an app restart. If macOS rejects the app, use the troubleshooting guidance below; do not disable security protections.

There is no documented Homebrew package or App Store installation route. Build from source to inspect or modify the app.

## Build from a checkout

Clone the [public source repository](https://github.com/QUIPXI/CornerWheel), then enter the checkout's root directory:

```sh
git clone https://github.com/QUIPXI/CornerWheel.git
cd CornerWheel
```

The shared `CornerWheel` scheme and Xcode project are already included; do not regenerate them just to build:

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
```

The development app is `Build/DerivedData/Build/Products/Debug/CornerWheel.app`. Open that app to try it, or run the `CornerWheel` scheme in Xcode. These builds use ad-hoc signing and an empty development team; no Apple Developer account or release credentials are required. They are **development builds, not notarized public releases**. Debug builds leave the update feed empty.

Use one app copy for manual testing. Replacing an ad-hoc build can require a new Accessibility grant because its signing identity changes. The optional `Scripts/build_update.sh` maintainer flow installs to a fixed local path with a persistent identity; see [release preparation](Docs/ReleasePreparation.md) before using it. It is not needed for contribution builds and does not notarize or publish.

If the project needs regeneration:

```sh
xcodegen generate --spec project.yml
```

Review the generated changes and run the build/tests again. Do not change the minimum macOS version or dependency pins merely to regenerate.

## Use and configure

First launch opens Settings and permission setup. Use the existing menu-bar menu to enable/disable CornerWheel, show the wheel for keyboard navigation, open Settings, check for configured updates, or quit.

The default trigger is **bottom-left**, **main display**, **32 points** inward from both edges, with a **0.2 second** hover delay. Move into that area, scroll to browse, then click the desired card. Move away to dismiss. The wheel also works while Settings is open, allowing immediate adjustment. Detection area ranges from 16–160 points. The UI's **Preview size** setting changes the current icon cards; it does not enable content capture.

Minimized windows are excluded by default; enable **Include minimized windows** to include them. Launch at login is off by default. Release a slider near its default to snap back; keyboard adjustments remain precise. Excluded apps are omitted from the window catalog. **Get Help** opens the existing online setup guide in your browser.

## Permissions and privacy

Accessibility lets CornerWheel identify individual windows and, when you choose an action, show, minimize, restore or close them. Prompts follow an explicit Settings action. Without permission, the wheel is blocked; when revocation is detected, its window data is cleared.

There is no window-content capture or screenshot cache. Window metadata and focus order stay in process memory; preferences persist locally. The app's source does not upload window data or add analytics. Configured Sparkle builds make update requests, and Help/Privacy/Terms links open a browser. See [PRIVACY.md](PRIVACY.md) for cache lifetimes, logs, persistence, network requests and permission recovery.

## Troubleshooting and limits

- **Wheel does not open:** check that CornerWheel is enabled, the corner/display selection is correct, and Accessibility is granted in System Settings. Use the app's permission-settings button, then **Recheck permission** or restart the same app copy.
- **No entry for a window:** check exclusions and the minimized-window setting. Some applications do not expose usable Accessibility windows. The app filters non-actionable elements; it cannot guarantee every app's cooperation.
- **Wrong Space or activation error:** public APIs and app-specific Accessibility behavior limit cross-Space/full-screen discovery and exact activation. Report the app, macOS version and steps with private titles removed. See [manual acceptance checks](Docs/ManualTestChecklist.md).
- **Corner conflicts:** macOS Hot Corners and the Dock retain their behavior. Choose another corner if needed.
- **Updates unavailable in Debug:** expected; no feed is configured. Release updates require the existing Sparkle signing and hosting setup.
- **Xcode cannot resolve Sparkle:** confirm GitHub access and Xcode's selected developer directory, then retry the locked build. Do not discard the lockfile or disable verification to work around a download failure.
- **macOS refuses a downloaded app:** obtain a verified release from the maintainer and report the exact message. Do not bypass Gatekeeper or remove quarantine as an installation step.

This release uses icon/title cards; real content previews are planned separately. The retained legacy three/four-slot preference does not change the current three-slot maximum. macOS 14, Intel, multiple displays, Spaces, full-screen behavior and permission changes still need the manual evidence described in the checklist. The app is not configured for Mac App Store sandbox distribution.

## Contribute and release

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, architecture, tests and pull-request expectations; [SECURITY.md](SECURITY.md) for security-reporting status; and [ROADMAP.md](ROADMAP.md) for release blockers and scope.

[ReleasePreparation.md](Docs/ReleasePreparation.md) separates contributor builds from signed/notarized releases. No new screenshot or demo is claimed; capture requirements are in the manual checklist.


## License

CornerWheel project code and its project-generated icon are licensed under **MIT**; see the complete [LICENSE](LICENSE). The maintainer selected MIT during this preparation to allow broad reuse, including proprietary derivatives, with preservation of the license notice. This supersedes the earlier closed-source positioning for the project-owned material in this checkout.

Sparkle and its bundled components retain their own licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the complete [bundled notices](Resources/ThirdPartyNotices.txt). The separate website and previously distributed binaries are not relicensed by changing this native checkout.
