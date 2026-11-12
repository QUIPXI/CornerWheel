import CoreGraphics
import Foundation

/// AppKit uses a bottom-left origin. `displayFrame` is the physical screen frame;
/// `visibleFrame` is the area left after the menu bar and Dock are accounted for.
struct DisplayGeometry: Equatable {
    static let triggerSideLength: CGFloat = 32

    let displayFrame: CGRect
    let visibleFrame: CGRect
    let backingScale: CGFloat

    init(displayFrame: CGRect, visibleFrame: CGRect, backingScale: CGFloat = 1) {
        self.displayFrame = displayFrame.standardized
        self.visibleFrame = visibleFrame.standardized
        self.backingScale = max(1, backingScale)
    }

    var usableFrame: CGRect {
        displayFrame.intersection(visibleFrame)
    }

    /// The trigger extends inward from the physical corner so the pointer can
    /// open the wheel before reaching either edge, regardless of Dock insets.
    func triggerFrame(corner: CornerChoice, side: CGFloat = DisplayGeometry.triggerSideLength) -> CGRect {
        let length = max(1, side)
        let x = corner == .bottomLeft ? displayFrame.minX : displayFrame.maxX - length
        return CGRect(x: x, y: displayFrame.minY, width: length, height: length)
    }

    func containsTrigger(_ point: CGPoint, corner: CornerChoice,
                         side: CGFloat = DisplayGeometry.triggerSideLength) -> Bool {
        triggerFrame(corner: corner, side: side).contains(point)
    }
}

/// Converts between AppKit's bottom-left global points and the top-left global
/// point system reported by Accessibility and Core Graphics window metadata.
/// The reference is the main display, whose AppKit frame may not include all
/// connected displays. No per-display scaling is applied to point coordinates.
struct DisplayCoordinateConverter {
    let mainDisplayFrame: CGRect

    func appKitToQuartz(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayFrame.maxY - point.y)
    }

    func quartzToAppKit(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayFrame.maxY - point.y)
    }

    func appKitToQuartz(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayFrame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    func quartzToAppKit(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayFrame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }
}
