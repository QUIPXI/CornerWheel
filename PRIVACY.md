# Privacy and local data

This describes the native app in this checkout, based on source inspection on November 12, 2026. It is not a network traffic audit or a statement about the retention policies of the website and update host. The separate website is not required to build or use window switching.

## Window information and card content

The current app **does not capture window contents or request Screen Recording permission**. Its rectangular cards show static application icons and window titles; this is the approved scope for the current release. Actual window-content previews are a separately scoped future feature; see [ROADMAP.md](ROADMAP.md). There is no captured-image cache to describe or verify in this version.

With Accessibility permission, `Sources/CornerWheel/Services/AccessibilityWindowStore.swift` reads each eligible window's role, subrole, title, position, size and minimized state. `WindowCatalog.swift` also obtains the owning application's process identifier, bundle identifier, name and hidden state. These values let the app distinguish individual windows, filter entries, label cards and select an exact window. Titles can contain sensitive document names even though the app does not read document contents.

The app keeps Accessibility references and random window identifiers in memory. Identifiers follow Accessibility object identity rather than title text. `Sources/CornerWheel/Core/MRUTracker.swift` keeps the observed focus order in memory; it does not write a timestamped activity history. Browsing and hovering do not change that order.

`WindowActivationService.swift` and `AccessibilityWindowStore.swift` use Accessibility to raise, focus, minimize, restore or request closure of the window the user selects. The target application owns any save confirmation. A failed activation can show the selected window's title in an on-screen error message.

## Temporary data and persistence

| Data | Storage and lifetime |
| --- | --- |
| Window metadata, Accessibility references and MRU order | Process memory. Catalog refreshes retire closed windows and exited processes; incomplete scans can retain references until a later successful scan. Closing the wheel clears its presentation records, but the catalog remains available between openings. Pausing or sleeping stops observation without immediately clearing all catalog data. Detected Accessibility loss clears the catalog; stopping or quitting clears runtime state. |
| Application icons | `ApplicationIconCache` in `Sources/CornerWheel/UI/OverlayPanelController.swift` keeps at most 64 entries, shared by windows from the same application. Least-recently-used entries are evicted; dismissal clears the cache and cancels pending presentation updates. These are application icons, not screenshots. |
| Preferences | `SettingsStore.swift` writes JSON to the `CornerWheel.preferences.v1` key in macOS `UserDefaults`: enabled state, chosen corner/display, detection area, size/timing/scroll options, minimized-window setting, excluded application bundle IDs, appearance and launch-at-login choice. A legacy slot-count value is also decoded and retained, although the current layout uses up to three slots. |
| Onboarding | `CornerWheelApp.swift` stores `CornerWheel.onboardingSeen` in `UserDefaults`. |
| Update settings and files | Sparkle stores updater preferences, such as automatic checks/downloads and last-check time, in the app's defaults. Update downloads can be written to its cache under the user's caches directory, ordinarily `~/Library/Caches/com.cornerwheel.CornerWheel/org.sparkle-project.Sparkle/`, including `PersistentDownloads`. These are update packages, not window data. |

The standard app defaults domain is `com.cornerwheel.CornerWheel`, normally backed by `~/Library/Preferences/com.cornerwheel.CornerWheel.plist`; macOS manages the actual storage. Preferences persist across restarts. **Reset to defaults** resets CornerWheel's settings and synchronizes launch-at-login registration, but does not remove onboarding, Sparkle preferences, system permissions, logs or all update files. Launch at login uses macOS `SMAppService`.

Sparkle cleans completed/removed download directories and attempts age-based cleanup of old cache entries during later operations. Its pinned 2.10.1 implementation uses a ten-day age threshold for that cleanup, not a guaranteed ten-day deletion deadline. CornerWheel does not implement its own cache-retention timer. See the upstream [download code](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Downloader/SPUDownloader.m) and [cache implementation](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Sparkle/SPULocalCacheDirectory.m).

No app source writes window titles, window images or focus history to files, databases or Keychain. Earlier development builds may have left licensing records in Keychain; the current native source neither reads nor deletes those records. This describes CornerWheel's own persistence, not macOS memory, diagnostics or backup behavior.

## Input and permissions

- **Accessibility:** required for window discovery and the user-selected window actions above. The system prompt is requested after an explicit button click. Permission is checked at launch, on app activation, wake/session activation, when opening the status menu or Settings, and through **Recheck permission**. Catalog scans also test trust before reading windows.
- **Denied or revoked Accessibility:** the wheel is blocked. Once revocation is observed, the coordinator dismisses the overlay, stops catalog observation and clears its window data. There is no continuous permission polling, so this is not an instantaneous-revocation guarantee; use **Recheck permission** or relaunch when testing recovery. macOS may require a restart after permission changes.
- **Screen Recording:** not requested or used by this implementation. Approval, denial or revocation does not enable real previews. A future capture implementation will need a new permission flow, data-lifetime review and manual tests before the privacy description changes.
- **Pointer/navigation input:** `CornerTriggerController.swift` installs local/global mouse movement, drag and mouse-button monitors to operate the corner trigger and dismissal. The panel handles scrolling and navigation keys for the wheel. The source does not record a typing or pointer history; it does not install a global keyboard logger. Disabling or blocking the wheel gates its behavior but does not remove every mouse monitor until the controller stops.

## Network activity

Window enumeration, sorting and activation use local macOS APIs. No application code connects window metadata or icons to an upload, analytics, crash-reporting, advertising, account or payment service.

The app already depends on **Sparkle 2.10.1** for updates. `AppUpdateController.swift` starts it only when the built app has a valid HTTPS feed URL and public verification key. An unconfigured development build leaves updates unavailable. Configured builds can fetch an appcast, release notes and update archives; automatic checks and downloads depend on the user's Sparkle settings and schedule. The existing release configuration refers to `updates.cornerwheel.com`. Hosting availability and server-side retention were not established by this source review.

Update hosts receive ordinary connection/request information, including the source IP address. Sparkle's default user agent contains the application name/version and Sparkle version. CornerWheel explicitly sets `sendsSystemProfile` to false, including when an older preference enabled it, and disables that option in `Info.plist`. It supplies no window information to the updater. Disabling optional system profiling does not suppress ordinary HTTP request metadata. See the [Sparkle updater API](https://sparkle-project.org/documentation/api-reference/Classes/SPUUpdater.html).

**Get Help**, **Privacy** and **Terms of Use** open existing `cornerwheel.com` links in the default browser. Those requests are separate from window processing and subject to the browser and site's behavior. **Support** opens a `mailto:` link in the user's mail client; CornerWheel does not send the email itself. Building from source also needs network access to resolve the pinned Swift package; that is a build-time dependency download, not app activity tracking.

## Logs and sharing diagnostics

CornerWheel uses macOS unified logging for Accessibility availability booleans and failed event-monitor installation. Debug builds also log the wheel's opening time and slot count. Its current logging statements do not include window titles or contents. Log retention is controlled by macOS.

Sparkle also writes update/installation diagnostics through macOS logging. Its errors can contain update URLs, local file paths and error details; do not assume dependency logs contain no identifying information. The app has no log-upload service. macOS may produce its own crash reports outside this code.

Before attaching diagnostics or screenshots to an issue, remove private window titles, document contents, usernames, personal paths, credentials and unrelated applications. Use disposable sample documents for demonstrations. A private vulnerability-reporting route is described only when verified in [SECURITY.md](SECURITY.md).
