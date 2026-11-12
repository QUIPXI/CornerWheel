import CoreGraphics
import Foundation

struct ArcSlot: Equatable {
    let index: Int
    /// The complete card, including caption, in panel-local AppKit points.
    /// Neighbor frames intentionally extend past the panel's physical edge.
    let frame: CGRect
    let globalFrame: CGRect
    let angle: CGFloat

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

/// A value snapshot so dismissal can wait for the pointer to leave the whole
/// interaction area even after the overlay's live layout has been cleared.
struct WheelInteractionRegion {
    let layout: ArcLayout
    let displayFrame: CGRect
    let detectionAreaSize: CGFloat

    func contains(_ globalPoint: CGPoint) -> Bool {
        guard displayFrame.contains(globalPoint) else { return false }
        let local = CGPoint(x: globalPoint.x - layout.panelFrame.minX,
                            y: globalPoint.y - layout.panelFrame.minY)
        let display = DisplayGeometry(displayFrame: displayFrame, visibleFrame: displayFrame)
        return layout.containsKeepAlivePoint(local)
            || display.containsTrigger(globalPoint, corner: layout.corner, side: detectionAreaSize)
    }
}

struct ArcLayout: Equatable {
    /// The visible, on-screen portion of the carousel. The panel clips cards
    /// centered on the bottom and side edges to exactly one half.
    let panelFrame: CGRect
    let slots: [ArcSlot]
    /// Size of the fully visible card; edge cards are smaller.
    let cardSize: CGSize
    let radius: CGFloat
    let corner: CornerChoice

    var visibleSlotCount: Int { slots.count }
    var primarySlotIndex: Int { slots.count >= 3 ? 1 : 0 }
    var primarySlot: ArcSlot? { slots.indices.contains(primarySlotIndex) ? slots[primarySlotIndex] : nil }
    var orbitCenter: CGPoint {
        CGPoint(x: corner == .bottomLeft ? panelFrame.minX : panelFrame.maxX,
                y: panelFrame.minY)
    }

    /// Keep pointer travel between the physical trigger and the three visible
    /// cards active, including the gaps between the cards.
    func containsInteractivePoint(_ localPoint: CGPoint) -> Bool {
        guard !slots.isEmpty else { return false }
        let cardInset: CGFloat = 20
        if slots.contains(where: { $0.frame.insetBy(dx: -cardInset, dy: -cardInset).contains(localPoint) }) {
            return true
        }

        let cornerPoint = CGPoint(x: corner == .bottomLeft ? 0 : panelFrame.width, y: 0)
        let primary = slots[primarySlotIndex].center
        let passages = [(cornerPoint, primary)] + slots.enumerated().compactMap { index, slot in
            index == primarySlotIndex ? nil : (primary, slot.center)
        }
        for (a, b) in passages {
            if distanceToSegment(localPoint, from: a, to: b) <= 45 { return true }
        }
        return false
    }

    /// A broader, corner-centered area keeps the gallery open while the
    /// pointer moves around its cards. This does not enlarge the panel's
    /// mouse-capturing area.
    func containsKeepAlivePoint(_ localPoint: CGPoint) -> Bool {
        guard !slots.isEmpty else { return false }
        let cornerPoint = CGPoint(x: corner == .bottomLeft ? 0 : panelFrame.width, y: 0)
        let margin = max(48, min(72, cardSize.width * 0.35))
        let outerRadius = radius + max(cardSize.width, cardSize.height) / 2 + margin
        return hypot(localPoint.x - cornerPoint.x, localPoint.y - cornerPoint.y) <= outerRadius
    }

    /// Integer positions match the resting slots. Off-stage positions continue
    /// around the same circle, so entries and exits rotate through the edge.
    func frame(forFractionalSlot position: CGFloat) -> CGRect {
        guard let first = slots.first else { return .zero }
        if slots.count == 1 { return first.frame }
        let angle: CGFloat
        let size: CGSize
        if position <= 0 {
            angle = first.angle + position * (slots[1].angle - first.angle)
            size = first.frame.size
        } else if position >= CGFloat(slots.count - 1) {
            let last = slots.count - 1
            angle = slots[last].angle + (position - CGFloat(last))
                * (slots[last].angle - slots[last - 1].angle)
            size = slots[last].frame.size
        } else {
            let lower = Int(floor(position))
            let progress = position - CGFloat(lower)
            angle = slots[lower].angle + progress
                * (slots[lower + 1].angle - slots[lower].angle)
            let from = slots[lower].frame.size
            let to = slots[lower + 1].frame.size
            size = CGSize(width: from.width + progress * (to.width - from.width),
                          height: from.height + progress * (to.height - from.height))
        }
        let centerX = corner == .bottomLeft
            ? radius * cos(angle)
            : panelFrame.width - radius * cos(angle)
        let centerY = radius * sin(angle)
        return CGRect(x: centerX - size.width / 2,
                      y: centerY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func distanceToSegment(_ point: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let denominator = dx * dx + dy * dy
        guard denominator > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let projection = ((point.x - a.x) * dx + (point.y - a.y) * dy) / denominator
        let t = min(1, max(0, projection))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}

/// A compact quarter-circle centered precisely on a physical display corner.
/// With three windows, the full card sits between two half-visible neighbors.
/// Its angle accounts for the rectangular card shape, giving both neighbors
/// the same visible edge gap while all three centers stay on one circle.
struct ArcLayoutEngine {
    static let baseCardWidth: CGFloat = 220
    static let cardGap: CGFloat = 12
    static let neighborScale: CGFloat = 0.82

    func layout(
        display: DisplayGeometry,
        corner: CornerChoice,
        windowCount: Int,
        preferredSlots: Int? = nil,
        previewScale: CGFloat = 1
    ) -> ArcLayout {
        let usable = display.usableFrame
        let physical = display.displayFrame
        let count = max(0, windowCount)
        guard count > 0, !usable.isNull, usable.width > 0, usable.height > 0 else {
            return ArcLayout(panelFrame: .zero, slots: [], cardSize: .zero, radius: 0, corner: corner)
        }

        // This layout always presents one primary and at most two neighbors.
        // Keep the argument for callers with a stored 3/4-card preference.
        _ = preferredSlots
        let slotCount = min(count, 3)
        let targetWidth = Self.baseCardWidth * min(1.5, max(0.65, previewScale))
        let width = fittingWidth(target: targetWidth, slots: slotCount,
                                 display: physical, usable: usable, corner: corner)
        guard width > 0 else {
            return ArcLayout(panelFrame: .zero, slots: [], cardSize: .zero, radius: 0, corner: corner)
        }

        let height = height(forWidth: width)
        let orbit = orbit(forWidth: width, height: height, slots: slotCount,
                          display: physical, usable: usable, corner: corner)
        let radius = orbit.radius
        let neighborWidth = width * Self.neighborScale
        let neighborHeight = height * Self.neighborScale
        let panelWidth = radius + (slotCount > 1 ? neighborWidth : width) / 2
        let panelHeight = radius + (slotCount > 1 ? neighborHeight : height) / 2
        let panelX = corner == .bottomLeft ? physical.minX : physical.maxX - panelWidth
        let panelFrame = CGRect(x: panelX, y: physical.minY,
                                width: panelWidth, height: panelHeight)
        let cardSize = CGSize(width: width, height: height)

        let angles: [CGFloat]
        switch slotCount {
        case 1: angles = [.pi / 4]
        case 2: angles = [.pi / 4, .pi / 2]
        default: angles = [0, orbit.primaryAngle, .pi / 2]
        }
        let slots = angles.enumerated().map { index, angle -> ArcSlot in
            let isPrimary = index == (slotCount == 3 ? 1 : 0)
            let slotWidth = isPrimary ? width : neighborWidth
            let slotHeight = isPrimary ? height : neighborHeight
            let centerX = corner == .bottomLeft
                ? radius * cos(angle)
                : panelWidth - radius * cos(angle)
            let centerY = radius * sin(angle)
            let localFrame = CGRect(x: centerX - slotWidth / 2, y: centerY - slotHeight / 2,
                                    width: slotWidth, height: slotHeight)
            return ArcSlot(index: index, frame: localFrame,
                           globalFrame: localFrame.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY),
                           angle: angle)
        }
        return ArcLayout(panelFrame: panelFrame, slots: slots, cardSize: cardSize,
                         radius: radius, corner: corner)
    }

    private func fittingWidth(target: CGFloat, slots: Int, display: CGRect,
                              usable: CGRect, corner: CornerChoice) -> CGFloat {
        if fits(width: target, slots: slots, display: display, usable: usable, corner: corner) {
            return target
        }
        var low: CGFloat = 0
        var high = target
        for _ in 0..<28 {
            let mid = (low + high) / 2
            if fits(width: mid, slots: slots, display: display, usable: usable, corner: corner) {
                low = mid
            } else {
                high = mid
            }
        }
        return low > 1 ? low - 0.01 : 0
    }

    private func fits(width: CGFloat, slots: Int, display: CGRect,
                      usable: CGRect, corner: CornerChoice) -> Bool {
        let height = height(forWidth: width)
        let orbit = orbit(forWidth: width, height: height, slots: slots,
                          display: display, usable: usable, corner: corner)
        let radius = orbit.radius
        let panelWidth = radius + (slots > 1 ? width * Self.neighborScale : width) / 2
        let panelHeight = radius + (slots > 1 ? height * Self.neighborScale : height) / 2
        guard panelWidth <= display.width, panelHeight <= display.height else { return false }

        let inwardX = radius * cos(orbit.primaryAngle)
        let inwardY = radius * sin(orbit.primaryAngle)
        let centerX = corner == .bottomLeft ? display.minX + inwardX : display.maxX - inwardX
        let primary = CGRect(x: centerX - width / 2,
                             y: display.minY + inwardY - height / 2,
                             width: width, height: height)
        return usable.contains(primary)
    }

    private func height(forWidth width: CGFloat) -> CGFloat {
        width * 0.58 + 34 // image plus readable caption
    }

    private func orbit(forWidth width: CGFloat, height: CGFloat, slots: Int,
                       display: CGRect, usable: CGRect,
                       corner: CornerChoice) -> (radius: CGFloat, primaryAngle: CGFloat) {
        let insetX = corner == .bottomLeft
            ? usable.minX - display.minX
            : display.maxX - usable.maxX
        let insetY = usable.minY - display.minY
        let neighborWidth = width * Self.neighborScale
        let neighborHeight = height * Self.neighborScale
        if slots >= 3 {
            // The bottom card overlaps the primary horizontally, and the side
            // card overlaps it vertically. Equal rectangle-edge gaps therefore
            // require different horizontal and vertical center offsets.
            let gap = max(Self.cardGap,
                          insetX + 8 - neighborWidth / 2,
                          insetY + 8 - neighborHeight / 2)
            let inwardX = (width + neighborWidth) / 2 + gap
            let inwardY = (height + neighborHeight) / 2 + gap
            return (hypot(inwardX, inwardY), atan2(inwardY, inwardX))
        }
        let primaryInward = max(width / 2 + insetX + 8,
                                height / 2 + insetY + 8)
        let separation = slots > 1 ? (width + neighborWidth) / 2 + Self.cardGap : 0
        return (max(primaryInward, separation) * sqrt(CGFloat(2)), .pi / 4)
    }
}
