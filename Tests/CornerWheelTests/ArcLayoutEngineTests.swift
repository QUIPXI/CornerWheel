import CoreGraphics
import XCTest
@testable import CornerWheel

final class ArcLayoutEngineTests: XCTestCase {
    private let engine = ArcLayoutEngine()

    func testThreeCardsOrbitPhysicalCornerWithHalfClippedNeighbors() {
        let display = DisplayGeometry(
            displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 840)
        )
        let layout = engine.layout(display: display, corner: .bottomLeft, windowCount: 12)
        XCTAssertEqual(layout.visibleSlotCount, 3)
        XCTAssertEqual(layout.primarySlotIndex, 1)
        XCTAssertEqual(layout.orbitCenter, CGPoint(x: 0, y: 0))
        XCTAssertEqual(layout.slots[0].angle, 0, accuracy: 0.001)
        XCTAssertLessThan(layout.slots[1].angle, .pi / 4)
        XCTAssertEqual(layout.slots[2].angle, .pi / 2, accuracy: 0.001)
        XCTAssertTrue(display.displayFrame.contains(layout.panelFrame))
        XCTAssertLessThan(layout.panelFrame.width, 450)
        XCTAssertLessThan(layout.panelFrame.height, 450)

        for slot in layout.slots {
            let dx = slot.globalFrame.midX - layout.orbitCenter.x
            let dy = slot.globalFrame.midY - layout.orbitCenter.y
            XCTAssertEqual(hypot(dx, dy), layout.radius, accuracy: 0.001)
            XCTAssertEqual(layout.frame(forFractionalSlot: CGFloat(slot.index)).minX,
                           slot.frame.minX, accuracy: 0.001)
            XCTAssertEqual(layout.frame(forFractionalSlot: CGFloat(slot.index)).minY,
                           slot.frame.minY, accuracy: 0.001)
        }

        let bottom = layout.slots[0].globalFrame
        let primary = layout.slots[1].globalFrame
        let side = layout.slots[2].globalFrame
        XCTAssertEqual(primary.size, layout.cardSize)
        XCTAssertEqual(bottom.width, primary.width * ArcLayoutEngine.neighborScale, accuracy: 0.001)
        XCTAssertEqual(side.height, primary.height * ArcLayoutEngine.neighborScale, accuracy: 0.001)
        XCTAssertEqual(bottom.intersection(display.displayFrame).height,
                       bottom.height / 2, accuracy: 0.001)
        XCTAssertEqual(side.intersection(display.displayFrame).width,
                       side.width / 2, accuracy: 0.001)
        XCTAssertTrue(display.usableFrame.contains(primary))
        XCTAssertTrue(bottom.intersection(primary).isNull)
        XCTAssertTrue(side.intersection(primary).isNull)
        XCTAssertEqual(primary.minY - bottom.maxY, ArcLayoutEngine.cardGap, accuracy: 0.001)
        XCTAssertEqual(primary.minX - side.maxX, ArcLayoutEngine.cardGap, accuracy: 0.001)
    }

    func testBothVisibleGapsMatchAcrossCornersScalesAndDisplayInsets() {
        let displays = [
            DisplayGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 840)),
            DisplayGeometry(displayFrame: CGRect(x: -350, y: 300, width: 350, height: 350),
                            visibleFrame: CGRect(x: -350, y: 300, width: 350, height: 340)),
            DisplayGeometry(displayFrame: CGRect(x: 100, y: -400, width: 1100, height: 800),
                            visibleFrame: CGRect(x: 170, y: -330, width: 1030, height: 730))
        ]
        for display in displays {
            for corner in [CornerChoice.bottomLeft, .bottomRight] {
                for scale: CGFloat in [0.65, 1, 1.35] {
                    let layout = engine.layout(display: display, corner: corner,
                                               windowCount: 5, previewScale: scale)
                    XCTAssertEqual(layout.visibleSlotCount, 3)
                    let bottom = layout.slots[0].globalFrame
                    let primary = layout.slots[1].globalFrame
                    let side = layout.slots[2].globalFrame
                    XCTAssertLessThan(bottom.width, primary.width)
                    XCTAssertLessThan(side.width, primary.width)
                    let bottomGap = primary.minY - bottom.maxY
                    let sideGap = corner == .bottomLeft
                        ? primary.minX - side.maxX : side.minX - primary.maxX
                    XCTAssertEqual(bottomGap, sideGap, accuracy: 0.001)
                    XCTAssertGreaterThanOrEqual(bottomGap, ArcLayoutEngine.cardGap - 0.001)
                    XCTAssertTrue(display.usableFrame.contains(primary))
                    XCTAssertEqual(layout.frame(forFractionalSlot: 1).origin,
                                   layout.slots[1].frame.origin)
                }
            }
        }
    }

    func testThreeSlotsRemainThreeWhenLegacyPreferenceRequestsFour() {
        let display = DisplayGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 760))
        let layout = engine.layout(display: display, corner: .bottomRight,
                                   windowCount: 9, preferredSlots: 4)
        XCTAssertEqual(layout.visibleSlotCount, 3)
        XCTAssertEqual(layout.primarySlotIndex, 1)
    }

    func testSmallCountsKeepPrimaryFullyVisibleAndNeverDuplicateCards() {
        let display = DisplayGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 760))
        for count in 0...2 {
            let layout = engine.layout(display: display, corner: .bottomLeft, windowCount: count)
            XCTAssertEqual(layout.visibleSlotCount, count)
            XCTAssertEqual(layout.slots.map(\.index), Array(0..<count))
            if let primary = layout.primarySlot {
                XCTAssertEqual(primary.angle, .pi / 4, accuracy: 0.001)
                XCTAssertTrue(display.usableFrame.contains(primary.globalFrame))
            }
        }
        let pair = engine.layout(display: display, corner: .bottomLeft, windowCount: 2)
        XCTAssertEqual(pair.slots[1].angle, .pi / 2, accuracy: 0.001)
        XCTAssertLessThan(pair.slots[1].frame.width, pair.slots[0].frame.width)
        XCTAssertEqual(pair.slots[1].globalFrame.intersection(display.displayFrame).width,
                       pair.slots[1].frame.width / 2, accuracy: 0.001)
    }

    func testNarrowDisplayShrinksCardsAndKeepsPrimaryUsable() {
        let display = DisplayGeometry(displayFrame: CGRect(x: -300, y: 300, width: 300, height: 300),
                                      visibleFrame: CGRect(x: -300, y: 300, width: 300, height: 290))
        let layout = engine.layout(display: display, corner: .bottomLeft, windowCount: 10)
        XCTAssertEqual(layout.visibleSlotCount, 3)
        XCTAssertLessThan(layout.cardSize.width, ArcLayoutEngine.baseCardWidth)
        XCTAssertTrue(display.displayFrame.contains(layout.panelFrame))
        XCTAssertTrue(display.usableFrame.contains(layout.primarySlot!.globalFrame))
        XCTAssertTrue(layout.slots[0].globalFrame.intersection(layout.slots[1].globalFrame).isNull)
        XCTAssertTrue(layout.slots[1].globalFrame.intersection(layout.slots[2].globalFrame).isNull)
    }

    func testInteractiveCorridorIncludesCornerAndGapsButNotEmptyPanelSpace() {
        let display = DisplayGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 840))
        let left = engine.layout(display: display, corner: .bottomLeft, windowCount: 8)
        let first = left.slots[0].center
        let second = left.slots[1].center
        let gap = CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
        XCTAssertTrue(left.containsInteractivePoint(gap))
        XCTAssertTrue(left.containsInteractivePoint(
            CGPoint(x: second.x / 2, y: second.y / 2)))
        XCTAssertTrue(left.containsInteractivePoint(.zero))
        XCTAssertFalse(left.containsInteractivePoint(
            CGPoint(x: left.panelFrame.width - 6, y: left.panelFrame.height - 6)))

        let right = engine.layout(display: display, corner: .bottomRight, windowCount: 8)
        let rightGap = CGPoint(x: right.panelFrame.width - gap.x, y: gap.y)
        XCTAssertTrue(right.containsInteractivePoint(rightGap))
        XCTAssertTrue(right.containsInteractivePoint(CGPoint(x: right.panelFrame.width, y: 0)))
    }

    func testKeepAliveAreaExtendsBeyondCardsButNotAcrossTheScreen() {
        let display = DisplayGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 840))
        let left = engine.layout(display: display, corner: .bottomLeft, windowCount: 8)
        let near = CGPoint(x: left.panelFrame.width + 24, y: left.panelFrame.height * 0.35)
        XCTAssertFalse(left.containsInteractivePoint(near))
        XCTAssertTrue(left.containsKeepAlivePoint(near))
        XCTAssertFalse(left.containsKeepAlivePoint(
            CGPoint(x: left.panelFrame.width + 150, y: left.panelFrame.height + 150)))
        XCTAssertFalse(left.containsKeepAlivePoint(
            CGPoint(x: left.panelFrame.width - 6, y: left.panelFrame.height - 6)))

        let right = engine.layout(display: display, corner: .bottomRight, windowCount: 8)
        let mirroredNear = CGPoint(x: right.panelFrame.width - near.x, y: near.y)
        XCTAssertTrue(right.containsKeepAlivePoint(mirroredNear))
        XCTAssertFalse(right.containsInteractivePoint(mirroredNear))
    }

    func testRightCornerMirrorsFramesAndClipsAtPhysicalEdges() {
        let display = DisplayGeometry(displayFrame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
                                      visibleFrame: CGRect(x: -1860, y: -200, width: 1860, height: 1020))
        let left = engine.layout(display: display, corner: .bottomLeft, windowCount: 7)
        let right = engine.layout(display: display, corner: .bottomRight, windowCount: 7)
        XCTAssertEqual(left.visibleSlotCount, right.visibleSlotCount)
        XCTAssertEqual(left.panelFrame.size, right.panelFrame.size)
        XCTAssertEqual(right.orbitCenter, CGPoint(x: display.displayFrame.maxX, y: display.displayFrame.minY))
        XCTAssertTrue(display.displayFrame.contains(right.panelFrame))
        XCTAssertTrue(display.usableFrame.contains(right.primarySlot!.globalFrame))
        for (leftSlot, rightSlot) in zip(left.slots, right.slots) {
            XCTAssertEqual(leftSlot.frame.minX + rightSlot.frame.maxX,
                           left.panelFrame.width, accuracy: 0.001)
            XCTAssertEqual(leftSlot.frame.minY, rightSlot.frame.minY, accuracy: 0.001)
        }
        XCTAssertEqual(right.slots[0].globalFrame.intersection(display.displayFrame).height,
                       right.slots[0].frame.height / 2, accuracy: 0.001)
        XCTAssertEqual(right.slots[2].globalFrame.intersection(display.displayFrame).width,
                       right.slots[2].frame.width / 2, accuracy: 0.001)
    }

    func testCardsResizeSmoothlyAsTheyMoveThroughTheOrbit() {
        let display = DisplayGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 760))
        let layout = engine.layout(display: display, corner: .bottomRight, windowCount: 6)
        let halfwayIn = layout.frame(forFractionalSlot: 0.5)
        let halfwayOut = layout.frame(forFractionalSlot: 1.5)
        let expectedWidth = (layout.slots[0].frame.width + layout.slots[1].frame.width) / 2
        XCTAssertEqual(halfwayIn.width, expectedWidth, accuracy: 0.001)
        XCTAssertEqual(halfwayOut.width, expectedWidth, accuracy: 0.001)
        for frame in [halfwayIn, halfwayOut] {
            XCTAssertEqual(hypot(layout.panelFrame.width - frame.midX, frame.midY),
                           layout.radius, accuracy: 0.001)
        }
    }

    func testOffstageAnimationContinuesAroundPhysicalCorner() {
        let display = DisplayGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 760))
        let layout = engine.layout(display: display, corner: .bottomRight, windowCount: 6)
        let before = layout.frame(forFractionalSlot: -1)
        let after = layout.frame(forFractionalSlot: 3)
        XCTAssertLessThan(before.maxY, 0)
        XCTAssertGreaterThan(after.minX, layout.panelFrame.width)
    }

    func testPhysicalTriggerAndUsablePrimaryAreDistinct() {
        let display = DisplayGeometry(displayFrame: CGRect(x: 100, y: -400, width: 1100, height: 800),
                                      visibleFrame: CGRect(x: 170, y: -330, width: 1030, height: 730),
                                      backingScale: 2)
        let trigger = display.triggerFrame(corner: .bottomLeft)
        XCTAssertEqual(trigger.origin, CGPoint(x: 100, y: -400))
        XCTAssertTrue(display.containsTrigger(CGPoint(x: 105, y: -395), corner: .bottomLeft))
        XCTAssertTrue(display.containsTrigger(CGPoint(x: 124, y: -376), corner: .bottomLeft))
        XCTAssertTrue(display.containsTrigger(CGPoint(x: 1176, y: -376), corner: .bottomRight))
        XCTAssertFalse(display.containsTrigger(CGPoint(x: 133, y: -376), corner: .bottomLeft))
        XCTAssertFalse(display.containsTrigger(CGPoint(x: 1167, y: -376), corner: .bottomRight))
        XCTAssertFalse(display.usableFrame.contains(trigger))
        let layout = engine.layout(display: display, corner: .bottomLeft, windowCount: 3)
        XCTAssertEqual(layout.orbitCenter, CGPoint(x: 100, y: -400))
        XCTAssertTrue(display.usableFrame.contains(layout.primarySlot!.globalFrame))
    }

    func testCoordinateConversionRoundTripsOnOffsetDisplays() {
        let converter = DisplayCoordinateConverter(mainDisplayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let point = CGPoint(x: -520, y: 1040)
        XCTAssertEqual(converter.appKitToQuartz(point), CGPoint(x: -520, y: -140))
        XCTAssertEqual(converter.quartzToAppKit(converter.appKitToQuartz(point)), point)
        let rect = CGRect(x: -400, y: 880, width: 250, height: 180)
        XCTAssertEqual(converter.appKitToQuartz(rect), CGRect(x: -400, y: -160, width: 250, height: 180))
        XCTAssertEqual(converter.quartzToAppKit(converter.appKitToQuartz(rect)), rect)
    }

    func testCustomDetectionAreaUsesPhysicalPointsOnOffsetRetinaDisplay() {
        let display = DisplayGeometry(displayFrame: CGRect(x: -1200, y: -800, width: 1200, height: 800),
                                      visibleFrame: CGRect(x: -1130, y: -730, width: 1130, height: 700),
                                      backingScale: 2)
        XCTAssertEqual(display.triggerFrame(corner: .bottomLeft, side: 96),
                       CGRect(x: -1200, y: -800, width: 96, height: 96))
        XCTAssertEqual(display.triggerFrame(corner: .bottomRight, side: 96),
                       CGRect(x: -96, y: -800, width: 96, height: 96))
        XCTAssertTrue(display.containsTrigger(CGPoint(x: -1105, y: -705), corner: .bottomLeft, side: 96))
        XCTAssertTrue(display.containsTrigger(CGPoint(x: -95, y: -705), corner: .bottomRight, side: 96))
        XCTAssertFalse(display.containsTrigger(CGPoint(x: -1103, y: -705), corner: .bottomLeft, side: 96))
        XCTAssertFalse(display.containsTrigger(CGPoint(x: -97, y: -705), corner: .bottomRight, side: 96))
        XCTAssertFalse(display.containsTrigger(CGPoint(x: -1105, y: -703), corner: .bottomLeft, side: 96))
        XCTAssertFalse(display.containsTrigger(CGPoint(x: -95, y: -703), corner: .bottomRight, side: 96))
    }
}
