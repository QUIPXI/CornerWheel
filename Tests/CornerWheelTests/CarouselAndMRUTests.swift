import CoreGraphics
import XCTest
@testable import CornerWheel

final class CarouselAndMRUTests: XCTestCase {
    private func ids(_ count: Int) -> [UUID] { (0..<count).map { _ in UUID() } }

    func testZeroOneTwoAndManyWindowSnapshotsHaveUniqueIdentities() {
        for count in [0, 1, 2, 20] {
            let source = ids(count)
            let controller = CarouselController(orderedIDs: source + source, visibleSlots: 4)
            let snapshot = controller.snapshot
            XCTAssertEqual(snapshot.totalCount, count)
            XCTAssertEqual(snapshot.visible.count, min(count, 3))
            XCTAssertEqual(Set(snapshot.visibleIDs).count, snapshot.visibleIDs.count)
            if count > 0 {
                XCTAssertEqual(snapshot.selectedID, source[0])
                XCTAssertEqual(snapshot.selectedPosition, 1)
            }
        }
    }

    func testWheelAdvancesOneWindowPerEventAndWrapsInBothDirections() {
        let source = ids(9)
        var controller = CarouselController(orderedIDs: source, visibleSlots: 3, currentID: source[1])
        let first = controller.scroll(deltaY: -50, input: .wheel)
        XCTAssertEqual(first?.fromStartIndex, 0)
        XCTAssertEqual(first?.toStartIndex, 1)
        XCTAssertEqual(first?.direction, 1)
        XCTAssertEqual(first?.changes.count, 4)
        XCTAssertEqual(first?.changes.first?.fromSlot, 0)
        XCTAssertEqual(first?.changes.first?.toSlot, -1)
        for _ in 0..<7 { _ = controller.scroll(deltaY: -1, input: .wheel) }
        XCTAssertEqual(controller.startIndex, 8)
        XCTAssertEqual(controller.snapshot.visibleIDs, [source[8], source[0], source[1]])
        XCTAssertNil(controller.snapshot.displayedRange)
        let wrapped = controller.scroll(deltaY: -1, input: .wheel)
        XCTAssertEqual(wrapped?.fromStartIndex, 8)
        XCTAssertEqual(wrapped?.toStartIndex, 0)
        XCTAssertEqual(wrapped?.direction, 1)
        XCTAssertEqual(controller.snapshot.visibleIDs, [source[0], source[1], source[2]])
        let backwards = controller.scroll(deltaY: 1, input: .wheel)
        XCTAssertEqual(backwards?.toStartIndex, 8)
        XCTAssertEqual(backwards?.direction, -1)
    }

    func testTrackpadAccumulationMomentumAndDirectionChange() {
        let source = ids(10)
        var controller = CarouselController(orderedIDs: source, visibleSlots: 3, currentID: source[1])
        XCTAssertNil(controller.scroll(deltaY: -15, input: .trackpad))
        XCTAssertNil(controller.scroll(deltaY: -15, input: .trackpad))
        XCTAssertEqual(controller.scroll(deltaY: -15, input: .trackpad)?.toStartIndex, 1)
        XCTAssertNil(controller.scroll(deltaY: 10, input: .trackpad)) // reversal clears residue
        XCTAssertEqual(controller.scroll(deltaY: -120, input: .momentum)?.toStartIndex, 2)
        XCTAssertNil(controller.scroll(deltaY: -200, input: .momentum))
        _ = controller.scroll(deltaY: 0, input: .ended)
        XCTAssertEqual(controller.scroll(deltaY: -120, input: .momentum)?.toStartIndex, 3)
    }

    func testRapidScrollRetargetsFromCurrentLogicalSlotsWithoutDuplicates() {
        let source = ids(7)
        var controller = CarouselController(orderedIDs: source, visibleSlots: 3, currentID: source[1])
        let first = controller.scroll(deltaY: -1, input: .wheel)
        let interrupted = controller.scroll(deltaY: -1, input: .wheel)
        XCTAssertEqual(first?.toStartIndex, 1)
        XCTAssertEqual(interrupted?.fromStartIndex, 1)
        XCTAssertEqual(interrupted?.toStartIndex, 2)
        XCTAssertEqual(controller.snapshot.visibleIDs, Array(source[2...4]))
        XCTAssertEqual(Set(controller.snapshot.visibleIDs).count, 3)
        XCTAssertEqual(interrupted?.changes.first(where: { $0.id == source[1] })?.toSlot, -1)
        XCTAssertEqual(interrupted?.changes.first(where: { $0.id == source[4] })?.fromSlot, 3)
    }

    func testReverseDirectionSettingInvertsWheelNavigation() {
        let source = ids(6)
        var controller = CarouselController(orderedIDs: source, visibleSlots: 3, currentID: source[1])
        XCTAssertEqual(controller.scroll(deltaY: 1, input: .wheel, reversed: true)?.toStartIndex, 1)
        XCTAssertEqual(controller.scroll(deltaY: -1, input: .wheel, reversed: true)?.toStartIndex, 0)
    }

    func testKeyboardSelectionWrapsAndRemovalRetainsPrimaryWindow() {
        let source = ids(8)
        var controller = CarouselController(orderedIDs: source, visibleSlots: 3, currentID: source[0])
        XCTAssertEqual(controller.moveSelection(by: 4), source[4])
        XCTAssertEqual(controller.startIndex, 3)
        XCTAssertEqual(controller.snapshot.visibleIDs, [source[3], source[4], source[5]])
        XCTAssertEqual(controller.snapshot.currentID, source[0])
        controller.removeWindow(id: source[0])
        XCTAssertEqual(controller.startIndex, 2)
        XCTAssertEqual(controller.snapshot.selectedID, source[4])
        controller.removeWindow(id: source[4])
        XCTAssertEqual(controller.snapshot.selectedID, source[5])
        XCTAssertEqual(controller.snapshot.totalCount, 6)
        XCTAssertEqual(Set(controller.snapshot.visibleIDs).count, controller.snapshot.visibleIDs.count)
        XCTAssertEqual(controller.moveSelection(by: -6), source[5])
        XCTAssertEqual(controller.moveSelection(by: -1), source[3])
        let keyboardMove = controller.navigate(by: -1)
        XCTAssertEqual(keyboardMove?.direction, -1)
        XCTAssertEqual(controller.snapshot.selectedID, source[2])
    }

    func testThreeVisibleWindowsRotateThroughBothArcEndsWithoutDuplicatesAtRest() {
        let source = ids(3)
        var controller = CarouselController(orderedIDs: source, visibleSlots: 3, currentID: source[0])
        XCTAssertEqual(controller.snapshot.visibleIDs, [source[2], source[0], source[1]])
        XCTAssertEqual(controller.snapshot.visible.map(\.isSelected), [false, true, false])
        let move = controller.scroll(deltaY: -1, input: .wheel)
        XCTAssertEqual(controller.snapshot.visibleIDs, [source[0], source[1], source[2]])
        XCTAssertEqual(controller.snapshot.selectedID, source[1])
        XCTAssertEqual(move?.changes.filter { $0.id == source[2] }, [
            CarouselSlotChange(id: source[2], fromSlot: 0, toSlot: -1),
            CarouselSlotChange(id: source[2], fromSlot: 3, toSlot: 2)
        ])
        XCTAssertEqual(Set(controller.snapshot.visibleIDs).count, 3)
    }

    @MainActor
    func testRapidWrapKeepsIncomingPresentationIdentity() {
        let source = ids(3)
        let records = source.map {
            WindowRecord(id: $0, processID: 1, bundleIdentifier: nil,
                         applicationName: "Test", title: "Window", bounds: .zero,
                         isMinimized: false, isHidden: false)
        }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let display = DisplayGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 840))
        let layout = ArcLayoutEngine().layout(display: display, corner: .bottomRight, windowCount: 3)
        var controller = CarouselController(orderedIDs: source, visibleSlots: 3, currentID: source[0])
        let model = OverlayViewModel()
        model.update(records: controller.snapshot.visibleIDs.compactMap { byID[$0] }, layout: layout,
                     selectedID: controller.snapshot.selectedID, animated: false)

        let first = controller.navigate(by: 1)!
        model.transition(movement: first, recordsByID: byID, layout: layout,
                         snapshot: controller.snapshot, reduceMotion: false)
        let enteringID = model.items.last!.id
        XCTAssertNotEqual(enteringID, source[2])

        let second = controller.navigate(by: 1)!
        model.transition(movement: second, recordsByID: byID, layout: layout,
                         snapshot: controller.snapshot, reduceMotion: false)
        XCTAssertEqual(model.items.first(where: { $0.record.id == source[2] })?.id, enteringID)
    }

    func testTwoWindowsCycleAcrossSeam() {
        let pair = ids(2)
        var small = CarouselController(orderedIDs: pair, visibleSlots: 3, currentID: pair[0])
        XCTAssertEqual(small.snapshot.visibleIDs, pair)
        XCTAssertEqual(small.snapshot.visible.map(\.isSelected), [true, false])
        XCTAssertEqual(small.scroll(deltaY: -1, input: .wheel)?.toStartIndex, 1)
        XCTAssertEqual(small.snapshot.visibleIDs, Array(pair.reversed()))
        XCTAssertEqual(small.snapshot.selectedID, pair[1])

    }

    func testMRUFocusOrderAndFrozenSessionOrder() {
        let source = ids(4)
        var tracker = MRUTracker()
        tracker.recordFocusedWindow(source[1])
        tracker.recordFocusedWindow(source[2])
        tracker.recordFocusedWindow(source[1])
        let frozen = tracker.freezeOrder(eligibleIDs: source + [source[1]])
        XCTAssertEqual(frozen, [source[1], source[2], source[0], source[3]])
        tracker.recordFocusedWindow(source[3])
        XCTAssertEqual(frozen.first, source[1]) // browsing does not reorder
        XCTAssertEqual(tracker.freezeOrder(eligibleIDs: source).first, source[3])
        tracker.removeWindow(source[3])
        XCTAssertEqual(tracker.recentIDs.first, source[1])
    }
}
