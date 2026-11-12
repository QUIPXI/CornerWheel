import AppKit
import CoreGraphics

/// A window, rather than an application. The UUID is retained for the lifetime of
/// the owning process and is never inferred from a mutable title alone.
struct WindowRecord: Identifiable, Hashable {
    let id: UUID
    let processID: pid_t
    let bundleIdentifier: String?
    let applicationName: String
    let title: String
    /// Global Quartz/Accessibility coordinates, with the origin at the upper left
    /// of the main display. UI layout must convert this to AppKit coordinates.
    let bounds: CGRect
    let isMinimized: Bool
    let isHidden: Bool
    var displayTitle: String { title.isEmpty ? "Untitled Window" : title }

    static func == (lhs: WindowRecord, rhs: WindowRecord) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Identity equality remains stable when a title or geometry changes. The
    /// catalog uses this separate comparison to suppress only unchanged data.
    func hasSameMetadata(as other: WindowRecord) -> Bool {
        id == other.id && processID == other.processID &&
        bundleIdentifier == other.bundleIdentifier && applicationName == other.applicationName &&
        title == other.title && bounds == other.bounds &&
        isMinimized == other.isMinimized && isHidden == other.isHidden
    }
}

enum ActivationResult: Equatable {
    case success
    case failure(String)

    var succeeded: Bool { self == .success }
}

enum WindowContextAction: Int {
    case show, minimize, restore, close

    var title: String {
        switch self {
        case .show: return "Show Window"
        case .minimize: return "Minimize Window"
        case .restore: return "Restore Window"
        case .close: return "Close Window"
        }
    }
}
