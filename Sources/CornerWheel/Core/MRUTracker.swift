import Foundation

/// Tracks actual focus observations. Hover and keyboard selection must not
/// call `recordFocusedWindow`; those are browsing state, not usage recency.
struct MRUTracker {
    private(set) var recentIDs: [UUID] = []

    mutating func recordFocusedWindow(_ id: UUID) {
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
    }

    mutating func removeWindow(_ id: UUID) {
        recentIDs.removeAll { $0 == id }
    }

    mutating func retainOnly(_ validIDs: Set<UUID>) {
        recentIDs.removeAll { !validIDs.contains($0) }
    }

    /// Immutable session order: observed windows first, then new eligible
    /// windows in catalog order. Repeated IDs are never emitted twice.
    func freezeOrder(eligibleIDs: [UUID]) -> [UUID] {
        let eligible = Set(eligibleIDs)
        var seen = Set<UUID>()
        return (recentIDs.filter { eligible.contains($0) } + eligibleIDs)
            .filter { seen.insert($0).inserted }
    }
}
