import CoreGraphics
import Foundation

enum ScrollInputKind {
    case wheel
    case trackpad
    case momentum
    case ended
}

struct CarouselVisibleItem: Equatable {
    let id: UUID
    let slot: Int
    let isCurrentWindow: Bool
    let isSelected: Bool
}

struct CarouselSnapshot: Equatable {
    let visible: [CarouselVisibleItem]
    let startIndex: Int
    let totalCount: Int
    let selectedID: UUID?
    let currentID: UUID?

    var visibleIDs: [UUID] { visible.map(\.id) }
    /// One-based position of the primary window in the frozen session order.
    var selectedPosition: Int? {
        guard totalCount > 0,
              let selectedSlot = visible.firstIndex(where: \.isSelected) else { return nil }
        return (startIndex + selectedSlot) % totalCount + 1
    }

    var displayedRange: ClosedRange<Int>? {
        guard !visible.isEmpty, startIndex + visible.count <= totalCount else { return nil }
        return (startIndex + 1)...(startIndex + visible.count)
    }
}

struct CarouselSlotChange: Equatable {
    let id: UUID
    /// -1 and `visibleSlots` describe the off-stage endpoints.
    let fromSlot: Int
    let toSlot: Int
}

struct CarouselMovement: Equatable {
    let fromStartIndex: Int
    let toStartIndex: Int
    let changes: [CarouselSlotChange]
    /// Logical direction remains correct when the index crosses the seam.
    let direction: Int
}

/// Pure session state. Construct it from a frozen MRU snapshot when the gallery
/// opens; changes to MRU do not mutate this order until the next session.
struct CarouselController {
    private(set) var orderedIDs: [UUID]
    private(set) var visibleSlots: Int
    private(set) var startIndex: Int = 0
    private(set) var selectedID: UUID?
    private(set) var currentID: UUID?
    private var accumulatedDelta: CGFloat = 0
    private var momentumStepTaken = false

    init(orderedIDs: [UUID], visibleSlots: Int, currentID: UUID? = nil) {
        var seen = Set<UUID>()
        self.orderedIDs = orderedIDs.filter { seen.insert($0).inserted }
        self.visibleSlots = min(3, max(1, visibleSlots))
        self.currentID = currentID
        self.selectedID = self.orderedIDs.first(where: { $0 == currentID }) ?? self.orderedIDs.first
        if let selectedID = self.selectedID,
           let selectedIndex = self.orderedIDs.firstIndex(of: selectedID) {
            self.startIndex = Self.wrapped(selectedIndex - primarySlot, count: self.orderedIDs.count)
        }
    }

    var snapshot: CarouselSnapshot {
        let ids = visibleIDs
        return CarouselSnapshot(
            visible: ids.enumerated().map { slot, id in
                CarouselVisibleItem(id: id, slot: slot,
                                    isCurrentWindow: id == currentID,
                                    isSelected: id == selectedID)
            },
            startIndex: startIndex,
            totalCount: orderedIDs.count,
            selectedID: selectedID,
            currentID: currentID
        )
    }

    /// Mouse-wheel ticks advance one window. Precise trackpad deltas accumulate
    /// to a threshold, with at most one move from each event and one additional
    /// move over a momentum tail. Positive macOS deltaY means scrolling up.
    mutating func scroll(
        deltaY: CGFloat,
        input: ScrollInputKind,
        sensitivity: Double = 1,
        reversed: Bool = false
    ) -> CarouselMovement? {
        if input == .ended {
            resetScroll()
            return nil
        }
        guard deltaY != 0, orderedIDs.count > 1 else { return nil }
        let sign: CGFloat = reversed ? 1 : -1
        let signed = deltaY * sign
        let direction = signed > 0 ? 1 : -1

        if input == .wheel {
            accumulatedDelta = 0
            momentumStepTaken = false
            return step(by: direction)
        }

        if input == .momentum && momentumStepTaken { return nil }
        if accumulatedDelta != 0 && (accumulatedDelta > 0) != (signed > 0) {
            accumulatedDelta = 0
            momentumStepTaken = false
        }
        let factor = min(3, max(0.25, sensitivity))
        let threshold: CGFloat = (input == .momentum ? 100 : 42) / factor
        accumulatedDelta += signed
        guard abs(accumulatedDelta) >= threshold else { return nil }
        accumulatedDelta -= CGFloat(direction) * threshold
        accumulatedDelta = min(threshold, max(-threshold, accumulatedDelta))
        if input == .momentum { momentumStepTaken = true }
        return step(by: direction)
    }

    /// Keyboard arrows use the same orbit transition as a wheel tick.
    @discardableResult
    mutating func navigate(by direction: Int) -> CarouselMovement? {
        guard direction != 0 else { return nil }
        return step(by: direction > 0 ? 1 : -1)
    }

    /// Arrow-key navigation rotates the ring around the primary window. It
    /// never changes the identity of the actually focused window.
    @discardableResult
    mutating func moveSelection(by amount: Int) -> UUID? {
        guard !orderedIDs.isEmpty else { return nil }
        let currentIndex = selectedID.flatMap { orderedIDs.firstIndex(of: $0) }
            ?? Self.wrapped(startIndex + primarySlot, count: orderedIDs.count)
        let next = Self.wrapped(currentIndex + amount, count: orderedIDs.count)
        selectedID = orderedIDs[next]
        startIndex = Self.wrapped(next - primarySlot, count: orderedIDs.count)
        return selectedID
    }

    @discardableResult
    mutating func select(_ id: UUID) -> Bool {
        guard orderedIDs.contains(id) else { return false }
        selectedID = id
        if let index = orderedIDs.firstIndex(of: id) {
            startIndex = Self.wrapped(index - primarySlot, count: orderedIDs.count)
        }
        return true
    }

    mutating func setCurrentWindow(_ id: UUID?) {
        currentID = id
    }

    /// A closed window is removed in place. New unrelated windows are omitted
    /// until the next session so a target cannot move under the pointer.
    mutating func removeWindow(id: UUID) {
        guard let removedIndex = orderedIDs.firstIndex(of: id) else { return }
        orderedIDs.remove(at: removedIndex)
        if currentID == id { currentID = nil }
        if selectedID == id {
            selectedID = orderedIDs.isEmpty ? nil : orderedIDs[removedIndex % orderedIDs.count]
        }
        if let selectedID, !orderedIDs.contains(selectedID) {
            self.selectedID = orderedIDs.first
        }
        if let selectedID, let index = orderedIDs.firstIndex(of: selectedID) {
            startIndex = Self.wrapped(index - primarySlot, count: orderedIDs.count)
        } else {
            startIndex = 0
        }
    }

    mutating func resetScroll() {
        accumulatedDelta = 0
        momentumStepTaken = false
    }

    private mutating func step(by direction: Int) -> CarouselMovement? {
        guard orderedIDs.count > 1 else { return nil }
        let oldStart = startIndex
        let oldVisible = visibleIDs
        startIndex = Self.wrapped(oldStart + direction, count: orderedIDs.count)
        let newVisible = visibleIDs
        selectedID = newVisible[primarySlot]
        let lastSlot = newVisible.count - 1

        // Include both the departing and arriving presentation when every
        // window is visible. They have the same window ID but travel along
        // opposite ends of the arc, so animation must keep both instances.
        let changes: [CarouselSlotChange]
        if direction > 0 {
            changes = oldVisible.enumerated().map { slot, id in
                CarouselSlotChange(id: id, fromSlot: slot, toSlot: slot - 1)
            } + [CarouselSlotChange(id: newVisible[lastSlot],
                                    fromSlot: newVisible.count, toSlot: lastSlot)]
        } else {
            changes = [CarouselSlotChange(id: newVisible[0], fromSlot: -1, toSlot: 0)]
                + oldVisible.enumerated().map { slot, id in
                    CarouselSlotChange(id: id, fromSlot: slot, toSlot: slot + 1)
                }
        }
        return CarouselMovement(fromStartIndex: oldStart, toStartIndex: startIndex,
                                changes: changes, direction: direction)
    }

    private var primarySlot: Int { min(1, max(0, min(orderedIDs.count, visibleSlots) - 2)) }

    private var visibleIDs: [UUID] {
        guard !orderedIDs.isEmpty else { return [] }
        return (0..<min(orderedIDs.count, visibleSlots)).map {
            orderedIDs[Self.wrapped(startIndex + $0, count: orderedIDs.count)]
        }
    }

    private static func wrapped(_ index: Int, count: Int) -> Int {
        (index % count + count) % count
    }
}
