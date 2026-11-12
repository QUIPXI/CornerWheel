import AppKit
import SwiftUI

/// Icons live only for the current browsing session. Limit retention when a
/// session visits many applications, and cache missing icons as well.
@MainActor
final class ApplicationIconCache {
    private struct Key: Hashable {
        let processID: pid_t
        let bundleIdentifier: String?

        init(_ record: WindowRecord) {
            processID = record.processID
            bundleIdentifier = record.bundleIdentifier
        }
    }

    private struct Entry {
        let icon: NSImage?
        var lastAccess: UInt64
    }

    private let capacity: Int
    private let load: (WindowRecord) -> NSImage?
    private var entries: [Key: Entry] = [:]
    private var access: UInt64 = 0

    init(capacity: Int = 64, load: @escaping (WindowRecord) -> NSImage? = {
        NSRunningApplication(processIdentifier: $0.processID)?.icon
    }) {
        self.capacity = max(1, capacity)
        self.load = load
    }

    func icon(for record: WindowRecord) -> NSImage? {
        let key = Key(record)
        access &+= 1
        if var entry = entries[key] {
            entry.lastAccess = access
            entries[key] = entry
            return entry.icon
        }
        if entries.count >= capacity,
           let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            entries.removeValue(forKey: oldest)
        }
        let icon = load(record)
        entries[key] = Entry(icon: icon, lastAccess: access)
        return icon
    }

    func retainApplications(in records: [WindowRecord]) {
        let valid = Set(records.map(Key.init))
        entries = entries.filter { valid.contains($0.key) }
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: false)
        access = 0
    }
}

@MainActor
final class OverlayViewModel: ObservableObject {
    struct Item: Identifiable {
        let record: WindowRecord
        let frame: CGRect
        let appIcon: NSImage?
        /// A wrapped card briefly exists at both ends of the orbit while it
        /// leaves one edge and enters the other. Those presentations need
        /// separate SwiftUI identities even though they represent one window.
        let id: UUID

        init(record: WindowRecord, frame: CGRect, id: UUID? = nil, appIcon: NSImage? = nil) {
            self.record = record
            self.frame = frame
            self.id = id ?? record.id
            self.appIcon = appIcon
        }
    }

    @Published var items: [Item] = []
    @Published var emptyStateFrame: CGRect?
    @Published var selectedID: UUID?
    @Published var hoveredID: UUID?
    @Published var contentOffset: CGPoint = .zero
    @Published var failureText: String?
    var onActivate: ((WindowRecord) -> Void)?
    var onWindowAction: ((WindowContextAction, WindowRecord) -> Void)?
    private(set) var isAnimating = false
    private var transitionToken = 0
    private let icons: ApplicationIconCache

    init(icons: ApplicationIconCache? = nil) {
        self.icons = icons ?? ApplicationIconCache()
    }

    func retainApplications(in records: [WindowRecord]) {
        icons.retainApplications(in: records)
    }

    func reset() {
        // Queued animation callbacks must not repopulate a dismissed panel.
        transitionToken += 1
        isAnimating = false
        items = []
        emptyStateFrame = nil
        selectedID = nil
        hoveredID = nil
        failureText = nil
        if contentOffset != .zero { contentOffset = .zero }
        icons.removeAll()
    }

    private func makeItem(record: WindowRecord, frame: CGRect, id: UUID? = nil) -> Item {
        Item(record: record, frame: frame, id: id, appIcon: icons.icon(for: record))
    }

    func update(records: [WindowRecord], layout: ArcLayout, selectedID: UUID?, animated: Bool) {
        transitionToken += 1
        let token = transitionToken
        isAnimating = animated
        let newItems = zip(records, layout.slots).map { makeItem(record: $0.0, frame: $0.1.frame) }
        let apply = {
            self.items = newItems
            self.selectedID = selectedID
            self.emptyStateFrame = records.isEmpty ? layout.primarySlot?.frame : nil
            if !records.contains(where: { $0.id == self.hoveredID }) { self.hoveredID = nil }
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.2), apply)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.21) {
                guard self.transitionToken == token else { return }
                self.isAnimating = false
            }
        } else { apply() }
    }

    func transition(movement: CarouselMovement, recordsByID: [UUID: WindowRecord],
                    layout: ArcLayout, snapshot: CarouselSnapshot, reduceMotion: Bool) {
        let visibleRecords = snapshot.visible.compactMap { recordsByID[$0.id] }
        guard !reduceMotion else {
            update(records: visibleRecords, layout: layout,
                   selectedID: snapshot.selectedID, animated: false)
            return
        }
        transitionToken += 1
        let token = transitionToken
        isAnimating = true
        emptyStateFrame = nil
        let changes = movement.changes.compactMap { change -> (Item, CGRect)? in
            guard let record = recordsByID[change.id] else { return nil }
            let expected = layout.frame(forFractionalSlot: CGFloat(change.fromSlot))
            let existing = items.filter { $0.record.id == change.id }.min {
                hypot($0.frame.midX - expected.midX, $0.frame.midY - expected.midY)
                    < hypot($1.frame.midX - expected.midX, $1.frame.midY - expected.midY)
            }
            let offstage = change.fromSlot < 0 || change.fromSlot >= layout.visibleSlotCount
            let frame = offstage ? expected : (existing?.frame ?? expected)
            // An entering copy may still be onscreen when another wheel event
            // arrives. Keep that presentation's identity as it moves through
            // the visible slots; reusing the canonical ID from its departing
            // twin would make SwiftUI jump across the orbit.
            let presentationID = offstage ? UUID() : (existing?.id ?? change.id)
            return (makeItem(record: record, frame: frame, id: presentationID),
                    layout.frame(forFractionalSlot: CGFloat(change.toSlot)))
        }
        items = changes.map { $0.0 }
        selectedID = snapshot.selectedID
        DispatchQueue.main.async {
            guard self.transitionToken == token else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                self.items = changes.map { item, destination in
                    Item(record: item.record, frame: destination, id: item.id, appIcon: item.appIcon)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.21) {
                guard self.transitionToken == token else { return }
                self.items = zip(visibleRecords, layout.slots).map { self.makeItem(record: $0.0, frame: $0.1.frame) }
                self.isAnimating = false
            }
        }
    }
}

/// Keep each menu's selection separate from the changing carousel selection.
@MainActor
final class WindowContextMenu: NSObject {
    let menu = NSMenu()
    private(set) var selectedAction: WindowContextAction?

    init(record: WindowRecord) {
        super.init()
        menu.autoenablesItems = false
        let actions: [WindowContextAction] = [.show, record.isMinimized ? .restore : .minimize, .close]
        for action in actions {
            if action == .close { menu.addItem(.separator()) }
            let item = NSMenuItem(title: action.title, action: #selector(selectAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = action.rawValue
            menu.addItem(item)
        }
    }

    @objc private func selectAction(_ sender: NSMenuItem) {
        selectedAction = WindowContextAction(rawValue: sender.tag)
    }
}

private final class CornerWheelPanel: NSPanel {
    var onScroll: ((NSEvent) -> Void)?
    var onEscape: (() -> Void)?
    var onNavigate: ((Int) -> Void)?
    var onEnter: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown ||
            (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            onContextMenu?(event)
            return
        }
        if event.type == .scrollWheel {
            onScroll?(event)
            return
        }
        if event.type == .keyDown {
            switch event.keyCode {
            case 53: onEscape?(); return
            case 123, 125: onNavigate?(-1); return
            case 124, 126: onNavigate?(1); return
            case 36, 76: onEnter?(); return
            default: break
            }
        }
        super.sendEvent(event)
    }
}

@MainActor
final class OverlayPanelController {
    let model = OverlayViewModel()
    private var panel: CornerWheelPanel?
    private var currentLayout: ArcLayout?
    private var physicalCorner: CGPoint?
    private var activeScreenFrame: CGRect = .zero
    private var actualPanelFrame: CGRect = .zero
    private var appliedDetectionAreaSize: CGFloat?
    private var contextMenu: NSMenu?
    var detectionAreaSize: CGFloat = DisplayGeometry.triggerSideLength
    var appearance: NSAppearance? {
        didSet { panel?.appearance = appearance }
    }

    var onScroll: ((NSEvent) -> Void)?
    var onEscape: (() -> Void)?
    var onNavigate: ((Int) -> Void)?
    var onEnter: (() -> Void)?
    var onContextMenuChanged: ((Bool) -> Void)?

    var interactionRegion: WheelInteractionRegion? {
        guard let layout = currentLayout else { return nil }
        return WheelInteractionRegion(layout: layout, displayFrame: activeScreenFrame,
                                      detectionAreaSize: detectionAreaSize)
    }

    func show(layout: ArcLayout, screen: NSScreen) {
        guard !layout.panelFrame.isEmpty else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        updateGeometry(layout: layout, screen: screen)
        if panel.frame != actualPanelFrame { panel.setFrame(actualPanelFrame, display: false) }
        panel.appearance = appearance
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
    }

    func update(layout: ArcLayout, screen: NSScreen) {
        updateGeometry(layout: layout, screen: screen)
        if let panel, panel.frame != actualPanelFrame {
            panel.setFrame(actualPanelFrame, display: true)
        }
    }

    private func updateGeometry(layout: ArcLayout, screen: NSScreen) {
        guard currentLayout != layout || activeScreenFrame != screen.frame ||
                appliedDetectionAreaSize != detectionAreaSize else { return }
        currentLayout = layout
        physicalCorner = CGPoint(x: layout.corner == .bottomLeft ? screen.frame.minX : screen.frame.maxX,
                                 y: screen.frame.minY)
        activeScreenFrame = screen.frame
        appliedDetectionAreaSize = detectionAreaSize
        actualPanelFrame = expandedFrame(for: layout, screen: screen)
        let offset = CGPoint(x: layout.panelFrame.minX - actualPanelFrame.minX,
                             y: layout.panelFrame.minY - actualPanelFrame.minY)
        if model.contentOffset != offset { model.contentOffset = offset }
    }

    func dismiss() {
        let menu = contextMenu
        contextMenu = nil
        menu?.cancelTracking()
        panel?.orderOut(nil)
        currentLayout = nil
        physicalCorner = nil
        activeScreenFrame = .zero
        actualPanelFrame = .zero
        appliedDetectionAreaSize = nil
        model.reset()
    }

    func contains(_ globalPoint: CGPoint) -> Bool {
        let ignoresMouseEvents = !captures(globalPoint)
        if panel?.ignoresMouseEvents != ignoresMouseEvents {
            panel?.ignoresMouseEvents = ignoresMouseEvents
        }
        return interactionRegion?.contains(globalPoint) ?? false
    }

    /// Only visible cards accept a click. The empty travel paths still capture
    /// scrolling, but clicking them should dismiss the wheel.
    func containsCard(_ globalPoint: CGPoint) -> Bool {
        record(at: globalPoint) != nil
    }

    func record(at globalPoint: CGPoint) -> WindowRecord? {
        guard let layout = currentLayout,
              activeScreenFrame.contains(globalPoint),
              actualPanelFrame.contains(globalPoint) else { return nil }
        let local = CGPoint(x: globalPoint.x - layout.panelFrame.minX,
                            y: globalPoint.y - layout.panelFrame.minY)
        // Match the SwiftUI stacking order if cards overlap during a turn.
        let hoveredID = model.hoveredID
        let selectedID = model.selectedID
        let ordered = model.items.reversed().sorted { first, second in
            func priority(_ item: OverlayViewModel.Item) -> Int {
                hoveredID == item.record.id ? 3 : selectedID == item.record.id ? 2 : 1
            }
            return priority(first) > priority(second)
        }
        return ordered.first { item in
            let scale: CGFloat = model.hoveredID == item.record.id ? 1.04 : 1
            let frame = item.frame.insetBy(dx: -item.frame.width * (scale - 1) / 2,
                                          dy: -item.frame.height * (scale - 1) / 2)
            return CGPath(roundedRect: frame, cornerWidth: 10 * scale,
                          cornerHeight: 10 * scale, transform: nil).contains(local)
        }?.record
    }

    /// Model frames already describe the destination while SwiftUI still draws
    /// moving cards. Do not target a destructive menu action from those frames.
    func contextMenuRecord(at globalPoint: CGPoint) -> WindowRecord? {
        guard !model.isAnimating else { return nil }
        return record(at: globalPoint)
    }

    private func showContextMenu(for event: NSEvent) {
        guard contextMenu == nil, let panel, let view = panel.contentView,
              let record = contextMenuRecord(at: panel.convertPoint(toScreen: event.locationInWindow)) else { return }
        let context = WindowContextMenu(record: record)
        contextMenu = context.menu
        onContextMenuChanged?(true)
        NSMenu.popUpContextMenu(context.menu, with: event, for: view)
        // Permission loss, display changes or suspension may have dismissed
        // this session while AppKit was tracking the menu.
        guard contextMenu === context.menu else { return }
        contextMenu = nil
        onContextMenuChanged?(false)
        if let action = context.selectedAction { model.onWindowAction?(action, record) }
    }

    func captures(_ globalPoint: CGPoint) -> Bool {
        guard let layout = currentLayout,
              activeScreenFrame.contains(globalPoint),
              actualPanelFrame.contains(globalPoint) else { return false }
        let local = CGPoint(x: globalPoint.x - layout.panelFrame.minX,
                            y: globalPoint.y - layout.panelFrame.minY)
        let withinCardsAndPaths = layout.containsInteractivePoint(local)

        // Keep a narrow passage from the physical corner to the fully visible
        // card so moving away from the trigger does not dismiss the switcher.
        guard let corner = physicalCorner,
              layout.slots.indices.contains(layout.primarySlotIndex) else {
            return withinCardsAndPaths
        }
        let primary = layout.slots[layout.primarySlotIndex]
        let cardPoint = CGPoint(x: primary.globalFrame.midX, y: primary.globalFrame.midY)
        let dx = cardPoint.x - corner.x
        let dy = cardPoint.y - corner.y
        let denominator = dx * dx + dy * dy
        guard denominator > 0 else { return withinCardsAndPaths }
        let t = min(1, max(0, ((globalPoint.x - corner.x) * dx + (globalPoint.y - corner.y) * dy) / denominator))
        let distance = hypot(globalPoint.x - (corner.x + t * dx), globalPoint.y - (corner.y + t * dy))
        return withinCardsAndPaths || distance < 70
    }

    private func expandedFrame(for layout: ArcLayout, screen: NSScreen) -> CGRect {
        let display = DisplayGeometry(displayFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let trigger = display.triggerFrame(corner: layout.corner, side: detectionAreaSize)
        // The outer cards touch the layout bounds. Leave room for their
        // shadows and hover enlargement without moving the orbit or exposing
        // the halves intentionally clipped at the physical screen edges.
        let renderingFrame = layout.panelFrame.insetBy(dx: -32, dy: -32)
        return renderingFrame.union(trigger).intersection(screen.frame)
    }

    private func makePanel() -> CornerWheelPanel {
        let panel = CornerWheelPanel(contentRect: .zero,
                                     styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.onScroll = { [weak self] event in self?.onScroll?(event) }
        panel.onEscape = { [weak self] in self?.onEscape?() }
        panel.onNavigate = { [weak self] amount in self?.onNavigate?(amount) }
        panel.onEnter = { [weak self] in self?.onEnter?() }
        panel.onContextMenu = { [weak self] event in self?.showContextMenu(for: event) }
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        return panel
    }
}
