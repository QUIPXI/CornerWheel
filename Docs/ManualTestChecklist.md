# CornerWheel native test checklist

Use a real Mac. Do not use a simulator. Record the macOS version, display arrangement, granted permissions, and app build for each test pass. Open the installed app from the same path used when granting permissions.

**Execution status:** the unchecked items below are procedures, not claims of passing results. Keep observations in a separate dated verification record; partial checks do not mark an entire checklist item complete. Preserve a separate dated record with the source revision (and whether the tree was dirty), app version/build, Xcode version, hardware, macOS version, display layout/scaling, signing type, install path, each result and any reproducible failure.

**Approved release scope:** these regression checks describe static app-icon/title window cards, up to three resting entries, and the existing status menu. Actual window-content previews are separate future work, not an acceptance requirement for this release. Screen Recording approval, denial and revocation are therefore **not applicable to the current code**, not passed. Before a future real-preview release, add and perform those permission checks, verify local capture/cache lifetime and confirm the intended 3–4 upright previews; see [the roadmap](../ROADMAP.md).

## Priority smoke pass for the current build

Use the newly built Debug app for source validation; the previously installed app is not evidence that this checkout works. Record the exact app path and source revision before testing. Keep other CornerWheel copies closed, record any settings changed, and restore them after the pass. Use only disposable sample windows for minimize/close tests.

1. Launch the selected build and inspect Settings and permission status. Confirm denied access leaves the wheel blocked; if access is granted, verify the shown cards remain static icons/titles and no Screen Recording prompt appears. Record any permission transition that cannot be performed.
2. Open at least two neutral test windows in one app. Hover at the configured corner, browse by scroll and keyboard, activate each exact window and reopen to check MRU. Check one fully visible card, clipped neighbors, Escape, pointer-leave dismissal and direct return to the corner.
3. Right-click or Control-click both the primary card and a neighbor. Check menu tracking beyond the wheel's bounds, Escape, Show Window, Minimize/Restore and Close Window. Use a disposable unsaved document to check the owning app's save confirmation; cancel it to preserve the document.
4. Exercise a rapid scroll followed by a card/context-menu click. During the brief card animation, context-menu clicks should be ignored; after it settles, the menu must target the visible card clicked. Confirm normal left-click activation remains unchanged. Repeat opening, browsing and dismissal; check no stuck menu or overlay remains.
5. Revoke/regrant Accessibility and verify dismissal/recovery when feasible. Leave multiple displays, display changes, other Spaces/full screen, oldest macOS/Intel, sustained resource use and signed-release installation unchecked until those environments or procedures are actually exercised.

Complete the detailed sections below for release acceptance; this priority pass does not substitute for the remaining checks.

## First run and permissions

- [ ] On a fresh user account with no saved activation and no internet connection, launch CornerWheel. Confirm Settings opens directly with no purchase, licence-key or account prompt. After Accessibility is granted, confirm window switching works offline.
- [ ] Upgrade a local build that previously had activation data. Confirm existing preferences and Accessibility behavior are retained, no payment-provider requests occur and no activation screen appears. The app should leave the old Keychain item untouched.
- [ ] Open Privacy, Terms and Third-party Notices from Settings. Confirm the web links point to CornerWheel and the complete bundled notices open locally.
- [ ] First-run text explains that Accessibility enables window discovery and user-selected show, minimize, restore and close actions, with save confirmations handled by the window’s app. Check static app icon and Hot Corner explanations, and confirm there is no Screen Recording request.
- [ ] Deny Accessibility. The app shows that it is needed and does not present the switcher.
- [ ] Grant Accessibility through a deliberate user action, recheck, and confirm that the gallery becomes available.
- [ ] Revoke Accessibility while CornerWheel runs, then restore it. Confirm clear status and recovery.
- [ ] Revoke Accessibility with the wheel visible and with it closed. Exercise Recheck permission, app switching and relaunch; record when the change is detected. Confirm the visible wheel disappears and window metadata is cleared after detection, and no window action succeeds while permission is denied.
- [ ] Close Settings. The menu-bar app continues running. Pause and resume it from the status menu.
- [ ] Choose Get Help from the status menu and from the bottom of Settings. Confirm each opens the CornerWheel setup and troubleshooting guide in the default browser, and the status menu closes normally.
- [ ] With another app active, choose Settings once from the status menu. Confirm Settings appears in front and accepts keyboard input. Repeat after closing Settings, covering it with another app, minimizing it, and hiding CornerWheel. Each request should reuse the same Settings window and restore it with one selection.
- [ ] Leave Settings on another Space, switch Spaces, and choose Settings once. Confirm it appears on the current Space; also check opening over a fullscreen app. After opening Settings, switch apps normally and confirm Settings does not keep returning to the front.

## Window content and identity

- [ ] Open normal windows in Finder, Safari, Preview, TextEdit, and one other available app. Confirm each card shows a fixed app icon and one label under it: the distinct window title or, when it repeats the app name, the app name. Confirm there is no count badge, top title, or bottom caption, and no Screen Recording request.
- [ ] Open at least three windows from one app, including repeated or empty titles if possible. Confirm they appear as separate cards and each click focuses the intended window.
- [ ] Reopen the gallery after focusing several windows in different orders. Confirm MRU order follows actual focus changes and stays fixed while a browsing session is open.
- [ ] Click the already-active window's preview. Confirm the gallery simply closes.
- [ ] At both corners, right-click and Control-click the main card and each partially visible neighbor. Confirm the native menu offers Show Window, Minimize Window (Restore Window for minimized windows), and Close Window. Each action must affect the clicked window, including when multiple windows have identical titles. Left-click should still switch immediately.
- [ ] Move through a window's context menu beyond the wheel's bounds and wait longer than the normal dismissal delay. Confirm the wheel stays open. Escape should cancel only the menu; moving away or clicking empty space afterward should dismiss the wheel normally. Revoke permission, change displays, or disable CornerWheel during menu tracking and confirm safe dismissal without a delayed action.
- [ ] Minimize a window from its menu, then enable minimized windows and restore it. Close a saved test window and confirm it disappears; close an unsaved test document and confirm the owning app's normal save prompt appears. Check a window with disabled close/minimize controls and an externally closed target; failures should remain brief and responsive. Use VoiceOver's named minimize/restore and close actions as well.
- [ ] With the normal Dock minimize animation enabled, minimize windows from several apps through the wheel. Successful minimization must close the wheel without a failure warning, including when the app publishes its minimized state after the request returns.
- [ ] Change a source window's contents, reopen the gallery, and confirm the card stays static while its title updates when available.
- [ ] Test minimized, hidden, protected, and inaccessible windows. Confirm no window is brought forward merely to draw a card.
- [ ] Close a window while the gallery is open. Confirm it disappears safely and selection remains useful.
- [ ] Select a window from an unresponsive app. Confirm the app stays responsive and reports activation failure if it cannot verify the target.
- [ ] Exclude an application, then confirm its windows are absent.

## Corner carousel interaction

- [ ] With no eligible windows (including when all apps are excluded or all windows are minimized with minimized windows disabled), open the wheel at either corner. Confirm it stays visible with “No apps to switch between”; scrolling, arrows, and Enter do nothing, while Escape, clicking empty space, and moving away still dismiss it. Close the last window while browsing and confirm the same message appears. Open an eligible window while the message is showing and confirm it is replaced by a normal card.
- [ ] With 1, 2, 3, 4, and 10–20 or more eligible windows, confirm there is one fully visible primary preview and at most two unique neighboring previews.
- [ ] With three or more windows, confirm the neighbors are half visible at the bottom and side screen edges, the orbit is centered on the physical corner, and the primary remains fully readable without overlap.
- [ ] Move from the corner to every card, including across gaps, without premature dismissal.
- [ ] At the default 32-point detection area, pause about 24 points inward from both edges at each configured bottom corner and confirm the wheel opens before touching either edge. Stay more than 32 points from either edge and confirm it does not open.
- [ ] In Settings → Behavior, increase Detection area to 160 points. At both corners, pause 120 points inward from each edge and confirm the wheel opens and stays visible while moving inside the detection area. Decrease to 16 points and confirm the same position no longer triggers it, while a point 8 points from each edge does. Check the minimum, maximum, and displayed value with keyboard and VoiceOver.
- [ ] Relaunch and confirm the chosen detection area persists. Reset to defaults and confirm it returns to 32 points. Updating from a version without this setting should retain all existing settings and use 32 points.
- [ ] Each of the four Settings sliders has no default marker or row of tick marks. Hover to see its default: Detection area 32 pt, Preview size 100%, Hover delay 200 ms, and Scroll sensitivity 1.0×. Release near the default value to snap to it; dragging through it should remain smooth. Release farther away and confirm the chosen value is retained. Confirm arrow keys and VoiceOver can move away from the default without getting stuck.
- [ ] Confirm the pointer must dwell before opening. Leave the configured detection area during dwell and confirm cancellation.
- [ ] Leave the full interaction region and confirm dismissal after a short grace period.
- [ ] At both corners, click empty space near the physical corner and in the gaps between cards. Confirm the wheel dismisses immediately, leaving underlying controls available for the next click. Repeat with left, right, and middle clicks. Left-clicking a visible card should still activate that window, and scrolling in the gaps should still browse the wheel.
- [ ] Dismiss with an empty-area click or Escape, then move outside the small detection square while staying near the cards and return to the corner. Confirm the wheel remains hidden. Leave the full interaction area and return to the corner; confirm the normal hover delay opens it again. Repeat with the detection area set to 160 points.
- [ ] Dismiss with an outside click or by moving away. Return directly to the corner and confirm normal opening; an extra trip outside the interaction area should not be needed. The menu's manual Show action should still work after dismissal.
- [ ] Confirm an active mouse drag through the corner does not open the gallery.
- [ ] While Settings is open, confirm the corner trigger opens the wheel and scrolling and selection still work. Closing the wheel should leave Settings open.
- [ ] While the status menu is open, confirm the corner trigger is suspended and the closed app shows no permanent launcher or widget.
- [ ] A mouse-wheel step advances one window and wraps from the last window to the first, and vice versa. Rapid scrolling stays responsive without duplicate resting entries or a card jumping across the primary preview.
- [ ] A short trackpad gesture moves a controlled number of windows. Check momentum, sensitivity, and reversed direction.
- [ ] While scrolling over the gallery, confirm the underlying webpage or document does not scroll.
- [ ] Use arrow keys, Enter, Escape, and VoiceOver. Confirm selection, focus indication, preview labels, and exact activation.
- [ ] Use keyboard navigation to reach CornerWheel's status menu and choose **Show Window Wheel**. Confirm the wheel stays open with the pointer away, arrows browse, Return selects and Escape closes it.

## Displays and lifecycle

- [ ] Check both bottom corners and confirm the right-hand orbit mirrors the left-hand orbit.
- [ ] Check main-display-only and all-display settings. On each display, the orbit centers on that display's physical corner, its two neighbors clip at the screen edges, and the primary preview fits within the usable area.
- [ ] Check a side or auto-hiding Dock, portrait orientation, mixed Retina scaling, negative display origins, and displays arranged vertically where available.
- [ ] Disconnect or reconnect a display while the gallery is open; confirm safe dismissal and a correct next opening.
- [ ] Test windows on another display, another Space, and in fullscreen modes where available. Record any API-specific limits precisely.
- [ ] Sleep and wake the Mac, switch user/session activity, launch and quit target apps, then confirm the trigger and menu still work without duplicate actions.
- [ ] Enable Reduce Motion and Reduce Transparency. Confirm readable, accessible fallback presentation.
- [ ] Repeat opening, browsing, and closing many times. Inspect idle CPU, memory growth, and opening latency.

## Resource use, updates and public evidence

- [ ] Measure a baseline after launch and after a fixed idle interval with the wheel closed. Record the sampling tool, duration, CPU and memory values; repeat after at least 100 open/scroll/dismiss cycles with the same test windows. Record observations without assuming a performance target or claiming improvement from incomparable samples.
- [ ] Check the icon cache during a long browsing session and after dismissal using a local debug inspection or Instruments. It should be limited to 64 application entries and cleared on dismissal; repeated sessions should not retain old presentation items. No captured-preview cache exists in this implementation. Record unexplained memory growth separately from the bounded icon cache.
- [ ] Check an unconfigured development build: update controls should state that updates are unavailable. For a configured signed release, test manual checking, automatic-check/download settings, offline failure and recovery using the existing release process. Confirm no window data appears in requests or submitted diagnostics; source inspection alone is not a traffic test.
- [ ] Confirm permission denial and app switching remain usable offline. Review any collected Console logs before sharing them; Sparkle errors can include URLs and local file paths.
- [ ] Prepare disposable windows with neutral titles/content, hide unrelated applications and notifications, and capture the actual native build at both configured corners. Include scrolling and exact-window selection in a short recording if possible. Inspect every frame for private titles, documents, account names and identifying desktop details before saving it as a public asset.
- [ ] Label screenshots with the tested build and current behavior. Do not present an illustration, simulated website demo or static icon card as a screenshot of real window-content previews. If capture is unavailable, keep this item unchecked and record the missing capture instead.
- [ ] Before public distribution, record signature verification, notarization/stapling, archive contents and installation/launch results on a separate Mac or clean user account. Do not treat a local unsigned/ad-hoc build as that result.
