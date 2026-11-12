# Release readiness and roadmap

CornerWheel remains a focused native macOS window switcher. The maintainer approved releasing the current icon/title cards: one upright rectangular primary card and up to two partly visible neighbors along the corner arc. Actual window-content previews are planned as separate future work, not a blocker for this release. No item below is a completed manual validation unless a release record explicitly says so.

## Publication and release acceptance


- **Complete live macOS verification.** Run and record the [manual checklist](Docs/ManualTestChecklist.md), especially permission loss, exact-window activation, same-app windows, minimized windows, display changes, Spaces/full screen and repeated opening/scrolling/dismissal. Automated tests do not establish these cross-application behaviors or idle performance.
- **Prepare and verify public artifacts.** Complete the signing/notarization prerequisites and checks in [ReleasePreparation.md](Docs/ReleasePreparation.md). Development build success does not make an artifact signed, notarized or ready for distribution. Confirm updater/feed ownership and delivery if enabling the existing updater in a release.
- **Finish the public presentation.** Capture a genuine, privacy-reviewed screenshot or short recording of the actual build. Do not use the separate website's simulated demo as evidence of native behavior. Reconcile the linked hosted privacy/terms pages with the approved license and actual release behavior. GitHub private vulnerability reporting is enabled; keep its instructions in [SECURITY.md](SECURITY.md) current.

## Worthwhile follow-up work

- **Real window-content previews:** scope a capture and permission implementation separately, with approximately 3–4 upright rectangular previews along a quarter-circle arc. It must preserve individual windows, observed MRU ordering, scrolling and exact-window activation, with an explicit local cache lifetime and permission-denial/revocation behavior. Review that implementation and update privacy documentation before advertising content previews. The current icon/title-card release does not need Screen Recording permission.
- Investigate documented Accessibility-provider differences using reproducible cases: timed-out enumeration, windows that do not expose standard roles, delayed title changes and focus verification across Spaces. Avoid workarounds that activate an unrelated window.
- Maintain focused tests for ordering, selection, scroll accumulation, filtering and lifecycle cancellation as behavior changes. Keep desktop tests separate from deterministic unit tests.
- Record idle CPU, memory and icon-cache behavior on representative hardware and display configurations. Existing historical component measurements are not evidence of current end-to-end performance or superiority over other apps.
- Reconcile legacy internal naming such as `previewSlots` with the approved product behavior when doing the future preview work. Avoid presenting an unused preference as an available feature.
- Keep the owner-approved MIT license, release records, dependency pinning and third-party notices current. Preserve Sparkle's bundled notices and treat separate website assets according to their own provenance. Verify the existing updater with each release without adding new update infrastructure.

## Out of scope

- A Dock replacement, permanent launcher, additional menu-bar presence or broad productivity suite. The current status menu is existing behavior.
- Accounts, subscriptions, advertising, paywalls, payment integrations or donation accounts.
- Analytics, hosted activity history, cloud processing or AI features.
- Electron, a web replacement for the native UI, private Apple APIs, a grid, a full circular wheel or rotated preview cards.
- A broad refactor, a new dependency stack, an auto-updater replacement, or publishing/changing repository visibility as part of local preparation.
