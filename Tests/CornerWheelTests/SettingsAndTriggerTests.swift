import AppKit
import XCTest
@testable import CornerWheel

@MainActor
final class SettingsAndTriggerTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "CornerWheelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testPreferencesPersistAndResetToCentralDefaults() {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.preferences, .defaults)
        store.preferences.corner = .bottomRight
        store.preferences.activationDisplays = .all
        store.preferences.previewSlots = .three
        store.preferences.detectionAreaSize = 96
        store.preferences.hoverDelay = 0.35
        store.preferences.excludedBundleIdentifiers.insert("example.excluded")

        let loaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(loaded.preferences.corner, .bottomRight)
        XCTAssertEqual(loaded.preferences.activationDisplays, .all)
        XCTAssertEqual(loaded.preferences.previewSlots, .three)
        XCTAssertEqual(loaded.preferences.detectionAreaSize, 96)
        XCTAssertEqual(loaded.preferences.hoverDelay, 0.35)
        XCTAssertTrue(loaded.preferences.excludedBundleIdentifiers.contains("example.excluded"))

        // Resetting local values is tested without changing the machine's
        // ServiceManagement login-item registration.
        loaded.preferences = .defaults
        XCTAssertEqual(SettingsStore(defaults: defaults).preferences, .defaults)
    }

    func testLegacyPreferencesKeepCustomValuesAndDefaultDetectionArea() throws {
        let defaults = isolatedDefaults()
        var legacy = CornerWheelPreferences.defaults
        legacy.corner = .bottomRight
        legacy.activationDisplays = .all
        legacy.previewScale = 1.1
        legacy.hoverDelay = 0.4
        legacy.reverseScroll = true
        legacy.includeMinimized = true
        legacy.excludedBundleIdentifiers = ["example.excluded"]
        legacy.appearance = .dark
        legacy.launchAtLogin = true

        let encoded = try JSONEncoder().encode(legacy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "detectionAreaSize")
        defaults.set(try JSONSerialization.data(withJSONObject: object),
                     forKey: "CornerWheel.preferences.v1")

        let loaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(loaded.preferences, legacy)
        XCTAssertEqual(loaded.preferences.detectionAreaSize, 32)

        loaded.preferences.detectionAreaSize = 128
        let reloaded = SettingsStore(defaults: defaults)
        var expected = legacy
        expected.detectionAreaSize = 128
        XCTAssertEqual(reloaded.preferences, expected)
    }

    func testSavedDetectionAreaIsClampedWithoutDiscardingOtherPreferences() throws {
        let encoded = try JSONEncoder().encode(CornerWheelPreferences.defaults)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let sizes: [(Double, Double)] = [(-20, 16), (999, 160)]
        for (savedSize, expectedSize) in sizes {
            let defaults = isolatedDefaults()
            var object = original
            object["detectionAreaSize"] = savedSize
            object["corner"] = "bottomRight"
            object["hoverDelay"] = 0.4
            defaults.set(try JSONSerialization.data(withJSONObject: object),
                         forKey: "CornerWheel.preferences.v1")

            let loaded = SettingsStore(defaults: defaults)
            XCTAssertEqual(loaded.preferences.detectionAreaSize, expectedSize)
            XCTAssertEqual(loaded.preferences.corner, .bottomRight)
            XCTAssertEqual(loaded.preferences.hoverDelay, 0.4)
        }
    }

    func testNonfiniteDetectionAreaAssignmentsRemainPersistable() {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults)
        store.preferences.hoverDelay = 0.35
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            store.preferences.detectionAreaSize = invalid
            XCTAssertEqual(store.preferences.detectionAreaSize, 32)
            let loaded = SettingsStore(defaults: defaults)
            XCTAssertEqual(loaded.preferences.detectionAreaSize, 32)
            XCTAssertEqual(loaded.preferences.hoverDelay, 0.35)
        }
    }

    func testPermissionPauseAndPresentationStateTransitions() throws {
        let store = SettingsStore(defaults: isolatedDefaults())
        let trigger = CornerTriggerController(settings: store)
        trigger.setPermissionsGranted(false)
        XCTAssertEqual(trigger.state, .permissionBlocked)
        let screen = try XCTUnwrap(NSScreen.screens.first)
        trigger.showManually(on: screen)
        XCTAssertEqual(trigger.state, .permissionBlocked)

        trigger.setPermissionsGranted(true)
        XCTAssertEqual(trigger.state, .idle)
        trigger.showManually(on: screen)
        XCTAssertEqual(trigger.state, .presenting)
        trigger.didPresent()
        XCTAssertEqual(trigger.state, .browsing)
        trigger.beginActivation()
        XCTAssertEqual(trigger.state, .activating)
        trigger.dismiss()
        XCTAssertEqual(trigger.state, .idle)

        trigger.setSuspended(true)
        XCTAssertEqual(trigger.state, .disabled)
        trigger.showManually(on: screen)
        XCTAssertEqual(trigger.state, .disabled)
        trigger.setSuspended(false)
        XCTAssertEqual(trigger.state, .idle)
    }

    func testPrimaryScreenCornerUsesCurrentScreenSnapshot() throws {
        let store = SettingsStore(defaults: isolatedDefaults())
        store.preferences.corner = .bottomRight
        let trigger = CornerTriggerController(settings: store)
        trigger.setPermissionsGranted(true)
        let primary = try XCTUnwrap(NSScreen.screens.first)
        let bounds = primary.frame

        // Both coordinates are short of the edges, outside the old 12-point zone.
        let inside = NSPoint(x: bounds.maxX - 24, y: bounds.minY + 24)
        let outside = NSPoint(x: bounds.maxX - 33, y: bounds.minY + 24)
        let matched = try XCTUnwrap(trigger.triggerScreen(containing: inside))
        let screenNumber = NSDeviceDescriptionKey("NSScreenNumber")
        XCTAssertEqual((matched.deviceDescription[screenNumber] as? NSNumber)?.uint32Value,
                       (primary.deviceDescription[screenNumber] as? NSNumber)?.uint32Value)
        XCTAssertNil(trigger.triggerScreen(containing: outside))
        XCTAssertNil(trigger.triggerScreen(containing: NSPoint(x: inside.x, y: bounds.minY + 33)))
        XCTAssertNotNil(trigger.triggerScreen(containing: NSPoint(x: bounds.maxX - 1, y: bounds.minY + 1)))

        store.preferences.corner = .bottomLeft
        let leftInside = NSPoint(x: bounds.minX + 24, y: bounds.minY + 24)
        XCTAssertNotNil(trigger.triggerScreen(containing: leftInside))
        XCTAssertNil(trigger.triggerScreen(containing: NSPoint(x: bounds.minX + 33, y: leftInside.y)))
        XCTAssertNil(trigger.triggerScreen(containing: NSPoint(x: leftInside.x, y: bounds.minY + 33)))
        XCTAssertNotNil(trigger.triggerScreen(containing: NSPoint(x: bounds.minX + 1, y: bounds.minY + 1)))
        XCTAssertNil(trigger.triggerScreen(containing: inside))
    }

    func testManualOpeningRemainsAvailableToKeyboardWhilePointerIsAway() async throws {
        let store = SettingsStore(defaults: isolatedDefaults())
        let trigger = CornerTriggerController(settings: store)
        let screen = try XCTUnwrap(NSScreen.screens.first)
        trigger.setPermissionsGranted(true)
        trigger.interactionContains = { _ in false }
        trigger.showManually(on: screen)
        trigger.didPresent()
        trigger.handlePointer(.mouseMoved, at: NSPoint(x: screen.frame.midX, y: screen.frame.midY), pressedMouseButtons: 0)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(trigger.state, .browsing, "The keyboard-opened wheel must not close merely because the pointer is away")
        trigger.handlePointer(.leftMouseDown, at: NSPoint(x: screen.frame.midX, y: screen.frame.midY), pressedMouseButtons: 1)
        XCTAssertEqual(trigger.state, .idle, "An outside click still dismisses a manually opened wheel")
    }

    func testDetectionAreaChangesApplyImmediatelyAtBothCorners() throws {
        let store = SettingsStore(defaults: isolatedDefaults())
        let trigger = CornerTriggerController(settings: store)
        trigger.setPermissionsGranted(true)
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let bounds = screen.frame

        for corner in CornerChoice.allCases {
            store.preferences.corner = corner
            let x: (CGFloat) -> CGFloat = { inset in
                corner == .bottomLeft ? bounds.minX + inset : bounds.maxX - inset
            }
            let fartherInside = NSPoint(x: x(95), y: bounds.minY + 95)
            store.preferences.detectionAreaSize = 32
            XCTAssertNil(trigger.triggerScreen(containing: fartherInside))

            store.preferences.detectionAreaSize = 96
            XCTAssertNotNil(trigger.triggerScreen(containing: fartherInside))
            XCTAssertNil(trigger.triggerScreen(containing: NSPoint(x: x(97), y: fartherInside.y)))
            XCTAssertNil(trigger.triggerScreen(containing: NSPoint(x: fartherInside.x, y: bounds.minY + 97)))

            store.preferences.detectionAreaSize = 16
            XCTAssertNil(trigger.triggerScreen(containing: fartherInside))
            XCTAssertNotNil(trigger.triggerScreen(containing: NSPoint(x: x(15), y: bounds.minY + 15)))
            XCTAssertNil(trigger.triggerScreen(containing: NSPoint(x: x(17), y: bounds.minY + 15)))
        }
    }

    func testPointerGeometryCacheTracksPreferencesAndDisplayChanges() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let store = SettingsStore(defaults: isolatedDefaults())
        var availableScreens = [screen]
        var screenReads = 0
        let trigger = CornerTriggerController(settings: store, screens: {
            screenReads += 1
            return availableScreens
        })
        trigger.setPermissionsGranted(true)
        let left = NSPoint(x: screen.frame.minX + 20, y: screen.frame.minY + 20)
        let right = NSPoint(x: screen.frame.maxX - 20, y: screen.frame.minY + 20)
        for _ in 0..<1_000 { XCTAssertNotNil(trigger.triggerScreen(containing: left)) }
        XCTAssertEqual(screenReads, 1, "Pointer motion should reuse display geometry")

        store.preferences.hoverDelay = 0.4
        XCTAssertNotNil(trigger.triggerScreen(containing: left))
        XCTAssertEqual(screenReads, 1, "Unrelated settings do not invalidate geometry")
        store.preferences.corner = .bottomRight
        XCTAssertNil(trigger.triggerScreen(containing: left))
        XCTAssertNotNil(trigger.triggerScreen(containing: right))
        XCTAssertEqual(screenReads, 2)
        store.preferences.detectionAreaSize = 16
        XCTAssertNil(trigger.triggerScreen(containing: right))
        XCTAssertEqual(screenReads, 3)
        store.preferences.detectionAreaSize = 32
        store.preferences.activationDisplays = .all
        XCTAssertNotNil(trigger.triggerScreen(containing: right))
        XCTAssertEqual(screenReads, 4)

        availableScreens = []
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertNil(trigger.triggerScreen(containing: right), "Removed displays must not retain trigger zones")
        XCTAssertEqual(screenReads, 5)
        availableScreens = [screen]
        trigger.setSuspended(true)
        trigger.setSuspended(false)
        XCTAssertNotNil(trigger.triggerScreen(containing: right), "Wake/resume refreshes the screen snapshot")
        XCTAssertEqual(screenReads, 6)
    }

    func testExpandedDetectionAreaStillHonorsActivationGates() throws {
        let store = SettingsStore(defaults: isolatedDefaults())
        store.preferences.detectionAreaSize = 160
        let trigger = CornerTriggerController(settings: store)
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let point = NSPoint(x: screen.frame.minX + 120, y: screen.frame.minY + 120)

        XCTAssertNil(trigger.triggerScreen(containing: point))
        trigger.setPermissionsGranted(true)
        XCTAssertNotNil(trigger.triggerScreen(containing: point))
        trigger.setSuspended(true)
        XCTAssertNil(trigger.triggerScreen(containing: point))
        trigger.setSuspended(false)
        XCTAssertNotNil(trigger.triggerScreen(containing: point))
        store.preferences.enabled = false
        XCTAssertNil(trigger.triggerScreen(containing: point))
        store.preferences.enabled = true
        XCTAssertNotNil(trigger.triggerScreen(containing: point))

        // Exercise the display-scope setting when the host has another display.
        for secondary in NSScreen.screens.dropFirst() {
            let secondaryPoint = NSPoint(x: secondary.frame.minX + 120,
                                         y: secondary.frame.minY + 120)
            guard !screen.frame.contains(secondaryPoint) else { continue }
            store.preferences.activationDisplays = .main
            XCTAssertNil(trigger.triggerScreen(containing: secondaryPoint))
            store.preferences.activationDisplays = .all
            XCTAssertNotNil(trigger.triggerScreen(containing: secondaryPoint))
        }
    }

    private func configuredOverlay(on screen: NSScreen, corner: CornerChoice) -> OverlayPanelController {
        let layout = ArcLayoutEngine().layout(
            display: DisplayGeometry(displayFrame: screen.frame, visibleFrame: screen.visibleFrame),
            corner: corner, windowCount: 3)
        let records = (0..<3).map { index in
            WindowRecord(id: UUID(), processID: 0, bundleIdentifier: nil,
                         applicationName: "Test App", title: "Window \(index)", bounds: .zero,
                         isMinimized: false, isHidden: false)
        }
        let overlay = OverlayPanelController()
        overlay.model.update(records: records, layout: layout, selectedID: records[1].id, animated: false)
        // Configure geometry without opening a panel or sending real input.
        overlay.update(layout: layout, screen: screen)
        return overlay
    }

    func testEmptyClicksWaitForExitFromEntireDismissedInteractionArea() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        for corner in CornerChoice.allCases {
            for detectionSize in [32.0, 160.0] {
                for button: NSEvent.EventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
                    let store = SettingsStore(defaults: isolatedDefaults())
                    store.preferences.corner = corner
                    store.preferences.detectionAreaSize = detectionSize
                    let trigger = CornerTriggerController(settings: store)
                    let overlay = configuredOverlay(on: screen, corner: corner)
                    overlay.detectionAreaSize = CGFloat(detectionSize)
                    let region = try XCTUnwrap(overlay.interactionRegion)
                    let x: (CGFloat) -> CGFloat = { inset in
                        corner == .bottomLeft ? screen.frame.minX + inset : screen.frame.maxX - inset
                    }
                    let emptyCorner = NSPoint(x: x(8), y: screen.frame.minY + 8)
                    let withinWheel = NSPoint(x: x(180), y: screen.frame.minY + 180)
                    let outside = NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 1)
                    XCTAssertTrue(overlay.captures(emptyCorner), "Empty paths must remain available for scrolling")
                    XCTAssertFalse(overlay.containsCard(emptyCorner))
                    XCTAssertTrue(region.contains(withinWheel))
                    XCTAssertFalse(region.contains(outside))

                    var dismissalCount = 0
                    trigger.interactionContains = { overlay.contains($0) }
                    trigger.interactionClickContains = { overlay.containsCard($0) }
                    trigger.interactionRegion = { overlay.interactionRegion }
                    trigger.onDismiss = {
                        dismissalCount += 1
                        overlay.dismiss()
                    }
                    trigger.setPermissionsGranted(true)
                    XCTAssertNil(trigger.triggerScreen(containing: withinWheel))
                    trigger.showManually(on: screen)
                    trigger.didPresent()
                    trigger.handlePointer(button, at: emptyCorner, pressedMouseButtons: 1)
                    XCTAssertEqual(trigger.state, .idle)
                    XCTAssertEqual(dismissalCount, 1)
                    XCTAssertNil(overlay.interactionRegion, "Dismissal clears live geometry")

                    // Returning to the trigger after leaving only its small
                    // square must not rearm, even after live geometry is gone.
                    for point in [emptyCorner, withinWheel, emptyCorner, withinWheel, emptyCorner] {
                        trigger.handlePointer(.mouseMoved, at: point, pressedMouseButtons: 0)
                        XCTAssertEqual(trigger.state, .idle)
                    }
                    trigger.handlePointer(.mouseMoved, at: outside, pressedMouseButtons: 0)
                    XCTAssertEqual(trigger.state, .idle)
                    trigger.handlePointer(.mouseMoved, at: emptyCorner, pressedMouseButtons: 0)
                    XCTAssertEqual(trigger.state, .armed)
                    trigger.stop()
                }
            }
        }
    }

    func testOutsideClickAllowsDirectReturnToTrigger() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        for corner in CornerChoice.allCases {
            let store = SettingsStore(defaults: isolatedDefaults())
            store.preferences.corner = corner
            let trigger = CornerTriggerController(settings: store)
            let overlay = configuredOverlay(on: screen, corner: corner)
            let outside = NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 1)
            let inside = NSPoint(x: corner == .bottomLeft ? screen.frame.minX + 8 : screen.frame.maxX - 8,
                                 y: screen.frame.minY + 8)
            trigger.interactionContains = { overlay.contains($0) }
            trigger.interactionClickContains = { overlay.containsCard($0) }
            trigger.interactionRegion = { overlay.interactionRegion }
            trigger.onDismiss = { overlay.dismiss() }
            trigger.setPermissionsGranted(true)
            trigger.showManually(on: screen)
            trigger.didPresent()
            trigger.handlePointer(.leftMouseDown, at: outside, pressedMouseButtons: 1)
            XCTAssertEqual(trigger.state, .idle)
            trigger.handlePointer(.mouseMoved, at: inside, pressedMouseButtons: 0)
            XCTAssertEqual(trigger.state, .armed)
            trigger.stop()
        }
    }

    func testCardClickRemainsAvailableForWindowActivation() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        for corner in CornerChoice.allCases {
            let store = SettingsStore(defaults: isolatedDefaults())
            store.preferences.corner = corner
            let trigger = CornerTriggerController(settings: store)
            let overlay = configuredOverlay(on: screen, corner: corner)
            let region = try XCTUnwrap(overlay.interactionRegion)
            let primary = try XCTUnwrap(region.layout.primarySlot)
            let cardCenter = NSPoint(x: primary.globalFrame.midX, y: primary.globalFrame.midY)
            trigger.interactionContains = { overlay.contains($0) }
            trigger.interactionClickContains = { overlay.containsCard($0) }
            trigger.interactionRegion = { overlay.interactionRegion }
            trigger.onDismiss = { XCTFail("A card click must reach the card's activation action") }
            trigger.setPermissionsGranted(true)
            trigger.showManually(on: screen)
            trigger.didPresent()
            for button: NSEvent.EventType in [.leftMouseDown, .rightMouseDown] {
                trigger.handlePointer(button, at: cardCenter, pressedMouseButtons: 1)
                XCTAssertEqual(trigger.state, .browsing)
            }
            trigger.stop()
        }
    }

    func testContextMenuCancelsPendingDismissalAndResumesAfterClosing() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let trigger = CornerTriggerController(settings: SettingsStore(defaults: isolatedDefaults()))
        trigger.interactionContains = { $0.x < 0 }
        trigger.interactionClickContains = { $0.x < 0 }
        trigger.setPermissionsGranted(true)
        trigger.showManually(on: screen)
        trigger.didPresent()
        trigger.handlePointer(.mouseMoved, at: NSPoint(x: -1, y: 0), pressedMouseButtons: 0)
        // Queue the ordinary grace-period dismissal, then open a menu.
        trigger.handlePointer(.mouseMoved, at: .zero, pressedMouseButtons: 0)
        trigger.setContextMenuOpen(true)
        trigger.handlePointer(.mouseMoved, at: .zero, pressedMouseButtons: 0)
        trigger.handlePointer(.leftMouseDown, at: .zero, pressedMouseButtons: 1)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(trigger.state, .browsing, "Menu tracking must keep the wheel open outside its bounds")
        trigger.setContextMenuOpen(false, at: .zero)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(trigger.state, .idle, "Ordinary dismissal must resume after cancelling the menu")
        trigger.stop()
    }

    func testSuspendingWithContextMenuOpenDoesNotProtectNextSessionFromDismissal() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let trigger = CornerTriggerController(settings: SettingsStore(defaults: isolatedDefaults()))
        trigger.interactionContains = { _ in false }
        trigger.setPermissionsGranted(true)
        trigger.showManually(on: screen)
        trigger.didPresent()
        trigger.setContextMenuOpen(true)
        trigger.setSuspended(true)
        XCTAssertEqual(trigger.state, .disabled)
        trigger.setSuspended(false)
        trigger.showManually(on: screen)
        trigger.didPresent()
        trigger.handlePointer(.rightMouseDown, at: .zero, pressedMouseButtons: 2)
        XCTAssertEqual(trigger.state, .idle)
        trigger.stop()
    }

    func testCardHitTestingExcludesGapsAndIncludesHoveredCardExtent() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        for corner in CornerChoice.allCases {
            let overlay = configuredOverlay(on: screen, corner: corner)
            let region = try XCTUnwrap(overlay.interactionRegion)
            let primary = try XCTUnwrap(region.layout.primarySlot).globalFrame
            let bottom = region.layout.slots[0].globalFrame
            let gap = CGPoint(x: (max(primary.minX, bottom.minX) + min(primary.maxX, bottom.maxX)) / 2,
                              y: (bottom.maxY + primary.minY) / 2)
            XCTAssertTrue(overlay.captures(gap))
            XCTAssertTrue(region.contains(gap))
            XCTAssertFalse(overlay.containsCard(gap), "Travel paths are empty click targets")
            XCTAssertTrue(overlay.containsCard(CGPoint(x: primary.midX, y: primary.midY)))
            XCTAssertFalse(overlay.containsCard(CGPoint(x: primary.minX + 0.5, y: primary.minY + 0.5)),
                           "Transparent rounded corners are empty space")

            let hoverEdge = CGPoint(x: primary.maxX + 1, y: primary.midY)
            XCTAssertFalse(overlay.containsCard(hoverEdge))
            overlay.model.hoveredID = overlay.model.items[1].record.id
            XCTAssertTrue(overlay.containsCard(hoverEdge))

            let clippedNeighbor = CGPoint(x: bottom.midX, y: screen.frame.minY - 1)
            XCTAssertFalse(overlay.containsCard(clippedNeighbor), "Offscreen halves cannot receive clicks")
        }
    }

    func testInteractionSnapshotIncludesDetectionAreaAndRespectsDisplayBounds() {
        let display = CGRect(x: -800, y: -400, width: 800, height: 600)
        for corner in CornerChoice.allCases {
            let panel = CGRect(x: corner == .bottomLeft ? display.minX : display.maxX - 100,
                               y: display.minY, width: 100, height: 100)
            let card = CGRect(x: corner == .bottomLeft ? 10 : 70, y: 10, width: 20, height: 20)
            let slot = ArcSlot(index: 0, frame: card,
                               globalFrame: card.offsetBy(dx: panel.minX, dy: panel.minY), angle: .pi / 4)
            let layout = ArcLayout(panelFrame: panel, slots: [slot], cardSize: card.size, radius: 20, corner: corner)
            let region = WheelInteractionRegion(layout: layout, displayFrame: display, detectionAreaSize: 160)
            let x: (CGFloat) -> CGFloat = { inset in
                corner == .bottomLeft ? display.minX + inset : display.maxX - inset
            }
            let detectionOnly = CGPoint(x: x(159), y: display.minY + 159)
            let local = CGPoint(x: detectionOnly.x - panel.minX, y: detectionOnly.y - panel.minY)
            XCTAssertFalse(layout.containsKeepAlivePoint(local))
            XCTAssertTrue(region.contains(detectionOnly), "The saved region must include the configured trigger")
            XCTAssertFalse(region.contains(CGPoint(x: x(161), y: detectionOnly.y)))
            XCTAssertFalse(region.contains(CGPoint(x: x(8), y: display.minY - 1)))
            XCTAssertFalse(region.contains(CGPoint(x: x(-1), y: display.minY + 8)))
        }
    }

    func testSlidersSnapNearTheirDefaultsWithoutPullingInDistantValues() {
        let cases: [(ClosedRange<Double>, Double, Double, Double, Double, Double)] = [
            (16...160, 32, 30, 34, 28, 36),
            (0.85...1.15, 1, 0.996, 1.004, 0.992, 1.008),
            (0.1...0.5, 0.2, 0.195, 0.205, 0.19, 0.21),
            (0.5...2, 1, 0.98, 1.02, 0.96, 1.04)
        ]
        for (range, defaultValue, nearBelow, nearAbove, farBelow, farAbove) in cases {
            let slider = DefaultSliderControl(frame: NSRect(x: 0, y: 0, width: 165, height: 26))
            slider.minValue = range.lowerBound
            slider.maxValue = range.upperBound
            slider.defaultValue = defaultValue

            XCTAssertEqual(slider.resolvedValue(nearBelow, snapToDefault: true), defaultValue)
            XCTAssertEqual(slider.resolvedValue(nearAbove, snapToDefault: true), defaultValue)
            XCTAssertEqual(slider.resolvedValue(farBelow, snapToDefault: true), farBelow)
            XCTAssertEqual(slider.resolvedValue(farAbove, snapToDefault: true), farAbove)

            // Small keyboard/accessibility changes and an ongoing drag must
            // be able to leave the default without fighting the snap zone.
            XCTAssertEqual(slider.resolvedValue(nearBelow, snapToDefault: false), nearBelow)
            XCTAssertEqual(slider.resolvedValue(nearAbove, snapToDefault: false), nearAbove)
        }
    }

    func testDetectionSliderKeepsWholePointsWithoutAddingNativeTicks() {
        let slider = DefaultSliderControl(frame: NSRect(x: 0, y: 0, width: 165, height: 26))
        slider.minValue = 16
        slider.maxValue = 160
        slider.defaultValue = 32
        slider.roundingIncrement = 1

        XCTAssertEqual(slider.resolvedValue(95.3, snapToDefault: false), 95)
        XCTAssertEqual(slider.resolvedValue(95.8, snapToDefault: false), 96)
        XCTAssertEqual(slider.resolvedValue(15.7, snapToDefault: false), 16)
        XCTAssertEqual(slider.resolvedValue(160.2, snapToDefault: false), 160)
        XCTAssertEqual(slider.resolvedValue(33, snapToDefault: false), 33)
        XCTAssertEqual(slider.resolvedValue(33, snapToDefault: true), 32)
        XCTAssertEqual(slider.numberOfTickMarks, 0)
    }



}
