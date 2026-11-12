import AppKit
import Combine
import XCTest
@testable import CornerWheel

@MainActor
final class OverlayOptimizationTests: XCTestCase {
    private func record(processID: pid_t, id: UUID = UUID(), title: String = "Window",
                        bundleIdentifier: String? = "test.app", minimized: Bool = false) -> WindowRecord {
        WindowRecord(id: id, processID: processID, bundleIdentifier: bundleIdentifier,
                     applicationName: "Test App", title: title, bounds: .zero,
                     isMinimized: minimized, isHidden: false)
    }

    private func layout(count: Int = 3) -> ArcLayout {
        ArcLayoutEngine().layout(
            display: DisplayGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                     visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 840)),
            corner: .bottomRight, windowCount: count)
    }

    func testWindowMenusOfferRestoreForMinimizedWindowsAndKeepSelectionsSeparate() {
        let normal = WindowContextMenu(record: record(processID: 1))
        let minimized = WindowContextMenu(record: record(processID: 2, minimized: true))
        XCTAssertEqual(normal.menu.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Show Window", "Minimize Window", "Close Window"])
        XCTAssertEqual(minimized.menu.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Show Window", "Restore Window", "Close Window"])
        XCTAssertNil(normal.selectedAction, "Cancelling a menu must not perform an action")
        minimized.menu.performActionForItem(at: 1)
        XCTAssertEqual(minimized.selectedAction, .restore)
        XCTAssertNil(normal.selectedAction)
        normal.menu.performActionForItem(at: 3)
        XCTAssertEqual(normal.selectedAction, .close)
    }

    func testContextMenuHitTestingTargetsClickedNeighborInsteadOfSelectedWindow() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        for corner in CornerChoice.allCases {
            let layout = ArcLayoutEngine().layout(
                display: DisplayGeometry(displayFrame: screen.frame, visibleFrame: screen.visibleFrame),
                corner: corner, windowCount: 3)
            let records = (1...3).map { record(processID: pid_t($0), title: "Same title") }
            let overlay = OverlayPanelController()
            overlay.model.update(records: records, layout: layout, selectedID: records[1].id, animated: false)
            overlay.update(layout: layout, screen: screen)
            for (record, slot) in zip(records, layout.slots) {
                let visible = slot.globalFrame.intersection(screen.frame)
                let point = CGPoint(x: visible.midX, y: visible.midY)
                XCTAssertEqual(overlay.record(at: point)?.id, record.id)
                XCTAssertEqual(overlay.contextMenuRecord(at: point)?.id, record.id)
            }
            overlay.dismiss()
            let primary = try XCTUnwrap(layout.primarySlot).globalFrame
            XCTAssertNil(overlay.record(at: CGPoint(x: primary.midX, y: primary.midY)))
        }
    }

    func testContextMenuWaitsUntilAnimatedCardsReachTheirHitTestFrames() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        for corner in CornerChoice.allCases {
            let layout = ArcLayoutEngine().layout(
                display: DisplayGeometry(displayFrame: screen.frame, visibleFrame: screen.visibleFrame),
                corner: corner, windowCount: 3)
            let records = (1...3).map { record(processID: pid_t($0), title: "Same title") }
            let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            var carousel = CarouselController(orderedIDs: records.map(\.id), visibleSlots: 3)
            let overlay = OverlayPanelController()
            overlay.model.update(records: carousel.snapshot.visibleIDs.compactMap { byID[$0] },
                                 layout: layout, selectedID: carousel.snapshot.selectedID, animated: false)
            overlay.update(layout: layout, screen: screen)
            let primary = try XCTUnwrap(layout.primarySlot).globalFrame
            let point = CGPoint(x: primary.midX, y: primary.midY)
            let oldTarget = try XCTUnwrap(overlay.contextMenuRecord(at: point)).id
            let movement = try XCTUnwrap(carousel.navigate(by: 1))
            let destinationTarget = try XCTUnwrap(carousel.snapshot.selectedID)
            XCTAssertNotEqual(oldTarget, destinationTarget)
            overlay.model.transition(movement: movement, recordsByID: byID, layout: layout,
                                     snapshot: carousel.snapshot, reduceMotion: false)
            XCTAssertNil(overlay.contextMenuRecord(at: point))

            // This block follows the queued destination-frame update, before
            // its delayed cleanup. The old lookup already returns a different
            // window even though the 200 ms visual turn has only just begun.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    XCTAssertEqual(overlay.record(at: point)?.id, destinationTarget)
                    XCTAssertNil(overlay.contextMenuRecord(at: point))
                    continuation.resume()
                }
            }
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(overlay.contextMenuRecord(at: point)?.id, destinationTarget)
            overlay.dismiss()
        }
    }

    func testReducedMotionAndImmediateUpdatesCancelContextMenuDelay() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let layout = ArcLayoutEngine().layout(
            display: DisplayGeometry(displayFrame: screen.frame, visibleFrame: screen.visibleFrame),
            corner: .bottomLeft, windowCount: 3)
        let records = (1...3).map { record(processID: pid_t($0)) }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var carousel = CarouselController(orderedIDs: records.map(\.id), visibleSlots: 3)
        let overlay = OverlayPanelController()
        overlay.update(layout: layout, screen: screen)
        let primary = try XCTUnwrap(layout.primarySlot).globalFrame
        let point = CGPoint(x: primary.midX, y: primary.midY)
        let initialRecords = carousel.snapshot.visibleIDs.compactMap { byID[$0] }
        overlay.model.update(records: initialRecords, layout: layout,
                             selectedID: carousel.snapshot.selectedID, animated: true)
        XCTAssertNil(overlay.contextMenuRecord(at: point))
        overlay.model.update(records: initialRecords, layout: layout,
                             selectedID: carousel.snapshot.selectedID, animated: false)
        XCTAssertEqual(overlay.contextMenuRecord(at: point)?.id, carousel.snapshot.selectedID)

        let movement = try XCTUnwrap(carousel.navigate(by: 1))
        overlay.model.transition(movement: movement, recordsByID: byID, layout: layout,
                                 snapshot: carousel.snapshot, reduceMotion: false)
        XCTAssertNil(overlay.contextMenuRecord(at: point))
        overlay.model.transition(movement: movement, recordsByID: byID, layout: layout,
                                 snapshot: carousel.snapshot, reduceMotion: true)
        XCTAssertEqual(overlay.contextMenuRecord(at: point)?.id, carousel.snapshot.selectedID)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(overlay.contextMenuRecord(at: point)?.id, carousel.snapshot.selectedID,
                       "Cancelled animation callbacks must not change the new immediate presentation")
        overlay.dismiss()
        XCTAssertFalse(overlay.model.isAnimating)
        XCTAssertNil(overlay.contextMenuRecord(at: point))
    }

    func testIconsAreSharedAcrossWindowsAndMissingIconsAreCached() {
        var loads: [pid_t] = []
        let icon = NSImage(size: NSSize(width: 48, height: 48))
        let cache = ApplicationIconCache { record in
            loads.append(record.processID)
            return record.processID == 1 ? icon : nil
        }
        XCTAssertTrue(cache.icon(for: record(processID: 1)) === icon)
        XCTAssertTrue(cache.icon(for: record(processID: 1)) === icon)
        XCTAssertNil(cache.icon(for: record(processID: 2)))
        XCTAssertNil(cache.icon(for: record(processID: 2)))
        XCTAssertEqual(loads, [1, 2])
    }

    func testIconRetentionIsBoundedAndInvalidatesDepartedApplications() {
        var loads: [pid_t] = []
        let cache = ApplicationIconCache(capacity: 2) { record in
            loads.append(record.processID)
            return nil
        }
        let first = record(processID: 1)
        let second = record(processID: 2)
        let third = record(processID: 3)
        _ = cache.icon(for: first)
        _ = cache.icon(for: second)
        _ = cache.icon(for: first) // Keep the first application most recently used.
        _ = cache.icon(for: third)
        _ = cache.icon(for: first)
        XCTAssertEqual(loads, [1, 2, 3])
        _ = cache.icon(for: second)
        XCTAssertEqual(loads, [1, 2, 3, 2])

        cache.retainApplications(in: [first])
        _ = cache.icon(for: second)
        XCTAssertEqual(loads, [1, 2, 3, 2, 2])
        _ = cache.icon(for: record(processID: 2, bundleIdentifier: "different.app"))
        XCTAssertEqual(loads.count, 6, "A reused process ID must not reuse a different application's icon")
    }

    func testModelUsesCachedIconsWhileKeepingUpdatedWindowTitles() {
        var loads = 0
        let icon = NSImage(size: NSSize(width: 48, height: 48))
        let model = OverlayViewModel(icons: ApplicationIconCache { _ in
            loads += 1
            return icon
        })
        let original = record(processID: 1, title: "Original title")
        model.update(records: [original], layout: layout(count: 1),
                     selectedID: original.id, animated: false)
        let renamed = record(processID: 1, id: original.id, title: "Renamed title")
        model.update(records: [renamed], layout: layout(count: 1),
                     selectedID: renamed.id, animated: false)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(model.items.first?.record.title, "Renamed title")
        XCTAssertTrue(model.items.first?.appIcon === icon)

        model.reset()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.selectedID)
        model.update(records: [renamed], layout: layout(count: 1),
                     selectedID: renamed.id, animated: false)
        XCTAssertEqual(loads, 2, "The next session must fetch current application icons")
    }

    func testDismissDuringAnimationDoesNotRestoreHiddenCards() async throws {
        let records = (1...3).map { record(processID: pid_t($0)) }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var carousel = CarouselController(orderedIDs: records.map(\.id), visibleSlots: 3)
        let overlay = OverlayPanelController()
        overlay.model.update(records: carousel.snapshot.visibleIDs.compactMap { byID[$0] },
                             layout: layout(), selectedID: carousel.snapshot.selectedID, animated: false)
        let movement = try XCTUnwrap(carousel.navigate(by: 1))
        overlay.model.transition(movement: movement, recordsByID: byID, layout: layout(),
                                 snapshot: carousel.snapshot, reduceMotion: false)
        // Allow the initial animation block to queue its delayed cleanup.
        try await Task.sleep(for: .milliseconds(30))
        overlay.model.hoveredID = records[0].id
        overlay.model.failureText = "Failure"
        overlay.dismiss()
        XCTAssertFalse(overlay.model.isAnimating)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(overlay.model.items.isEmpty)
        XCTAssertNil(overlay.model.selectedID)
        XCTAssertNil(overlay.model.hoveredID)
        XCTAssertNil(overlay.model.failureText)
        XCTAssertNil(overlay.interactionRegion)
    }

    func testResetBeforeAnimationStartsPreservesNewSession() async throws {
        let records = (1...3).map { record(processID: pid_t($0)) }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var carousel = CarouselController(orderedIDs: records.map(\.id), visibleSlots: 3)
        let model = OverlayViewModel()
        model.update(records: records, layout: layout(), selectedID: records[1].id, animated: false)
        let movement = try XCTUnwrap(carousel.navigate(by: 1))
        model.transition(movement: movement, recordsByID: byID, layout: layout(),
                         snapshot: carousel.snapshot, reduceMotion: false)
        model.reset()
        let nextSession = record(processID: 4)
        model.update(records: [nextSession], layout: layout(count: 1),
                     selectedID: nextSession.id, animated: false)
        XCTAssertFalse(model.isAnimating)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.items.map(\.record.id), [nextSession.id])
        XCTAssertEqual(model.selectedID, nextSession.id)
        XCTAssertFalse(model.isAnimating)
    }

    func testIdenticalGeometryDoesNotPublishAndChangesStillApply() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let display = DisplayGeometry(displayFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let initial = ArcLayoutEngine().layout(display: display, corner: .bottomRight, windowCount: 3)
        let overlay = OverlayPanelController()
        overlay.update(layout: initial, screen: screen)
        var offsetUpdates = 0
        let subscription = overlay.model.$contentOffset.dropFirst().sink { _ in offsetUpdates += 1 }
        for _ in 0..<100 { overlay.update(layout: initial, screen: screen) }
        XCTAssertEqual(offsetUpdates, 0)

        let changed = ArcLayoutEngine().layout(display: display, corner: .bottomLeft,
                                              windowCount: 1, previewScale: 0.7)
        overlay.detectionAreaSize = 160
        overlay.update(layout: changed, screen: screen)
        let region = try XCTUnwrap(overlay.interactionRegion)
        XCTAssertEqual(region.layout, changed)
        XCTAssertEqual(region.detectionAreaSize, 160)
        XCTAssertTrue(region.contains(CGPoint(x: screen.frame.minX + 150, y: screen.frame.minY + 150)))
        overlay.dismiss()
        overlay.update(layout: initial, screen: screen)
        XCTAssertEqual(overlay.interactionRegion?.layout, initial)
        withExtendedLifetime(subscription) {}
    }
}
