import AppKit
import Combine
import OSLog

@MainActor
final class CornerWheelCoordinator {
    private(set) var isRunning = false
    private let diagnostics = Logger(subsystem: "com.cornerwheel.CornerWheel", category: "Gallery")
    private let settings: SettingsStore
    private let permissions: PermissionManager
    private let catalog = WindowCatalog()
    private lazy var activation = WindowActivationService(catalog: catalog)
    private lazy var overlay = OverlayPanelController()
    private lazy var trigger = CornerTriggerController(settings: settings)
    private var mru = MRUTracker()
    private var carousel: CarouselController?
    private var sessionID: UUID?
    private var sessionScreen: NSScreen?
    private var sessionRecordsByID: [UUID: WindowRecord] = [:]
    private struct LayoutKey: Equatable {
        let display: DisplayGeometry
        let corner: CornerChoice
        let visibleCount: Int
        let previewScale: CGFloat
    }
    private var sessionLayout: (key: LayoutKey, layout: ArcLayout)?
    private var subscriptions: Set<AnyCancellable> = []
    private var menuOpen = false
    private var lifecyclePaused = false
    private var failureDismissal: Task<Void, Never>?
    private var lastPreferences: CornerWheelPreferences
    private var runGeneration = 0

    private var canScanWindows: Bool {
        isRunning && permissions.isReady && settings.preferences.enabled && !lifecyclePaused
    }

    init(settings: SettingsStore, permissions: PermissionManager) {
        self.settings = settings
        self.permissions = permissions
        self.lastPreferences = settings.preferences
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        runGeneration += 1
        lastPreferences = settings.preferences
        catalog.includeMinimized = settings.preferences.includeMinimized
        catalog.excludedBundleIdentifiers = settings.preferences.excludedBundleIdentifiers
        trigger.onShow = { [weak self] screen in self?.open(on: screen) }
        trigger.onDismiss = { [weak self] in self?.closeSession() }
        trigger.interactionContains = { [weak self] point in self?.overlay.contains(point) ?? false }
        trigger.interactionClickContains = { [weak self] point in self?.overlay.containsCard(point) ?? false }
        trigger.interactionRegion = { [weak self] in self?.overlay.interactionRegion }
        overlay.onScroll = { [weak self] event in self?.handleScroll(event) }
        overlay.onEscape = { [weak self] in self?.trigger.dismiss() }
        overlay.onNavigate = { [weak self] amount in self?.navigate(by: amount) }
        overlay.onEnter = { [weak self] in self?.activateSelection() }
        overlay.model.onActivate = { [weak self] record in self?.activate(record) }
        overlay.model.onWindowAction = { [weak self] action, record in self?.perform(action, on: record) }
        overlay.onContextMenuChanged = { [weak self] open in self?.trigger.setContextMenuOpen(open) }

        settings.$preferences.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.settingsChanged() }
        }.store(in: &subscriptions)
        permissions.$accessibilityGranted.dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.permissionsChanged() }
            }.store(in: &subscriptions)
        catalog.$windows.sink { [weak self] records in
            DispatchQueue.main.async { self?.catalogChanged(records) }
        }.store(in: &subscriptions)
        catalog.$focusedWindowID.sink { [weak self] id in
            DispatchQueue.main.async { self?.focusChanged(id) }
        }.store(in: &subscriptions)

        trigger.setPermissionsGranted(permissions.isReady)
        applySuspension()
        trigger.start()
        if canScanWindows {
            catalog.startObserving()
            refreshCatalog()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        runGeneration += 1
        failureDismissal?.cancel()
        trigger.setSuspended(true)
        trigger.stop()
        closeSession()
        catalog.stopObserving()
        catalog.clear()
        mru = MRUTracker()
        subscriptions.removeAll()
    }

    func settingsChanged() {
        guard isRunning else { return }
        let old = lastPreferences
        let current = settings.preferences
        guard old != current else { return }
        lastPreferences = current
        trigger.dismiss()
        overlay.appearance = current.appearance.appearance
        if old.includeMinimized != current.includeMinimized {
            catalog.includeMinimized = current.includeMinimized
        }
        if old.excludedBundleIdentifiers != current.excludedBundleIdentifiers {
            catalog.excludedBundleIdentifiers = current.excludedBundleIdentifiers
        }
        if !current.enabled {
            catalog.stopObserving()
        } else if canScanWindows && (!old.enabled ||
                    old.includeMinimized != current.includeMinimized ||
                    old.excludedBundleIdentifiers != current.excludedBundleIdentifiers) {
            catalog.startObserving()
            refreshCatalog()
        }
    }

    func setMenuOpen(_ value: Bool) {
        menuOpen = value
        guard isRunning else { return }
        applySuspension()
    }

    func showFromMenu() {
        guard canScanWindows, !menuOpen, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        trigger.showManually(on: screen)
    }

    func pauseForSession() {
        lifecyclePaused = true
        guard isRunning else { return }
        applySuspension()
        catalog.stopObserving()
    }

    func resumeAfterWake() {
        lifecyclePaused = false
        guard isRunning else { return }
        permissions.recheck()
        applySuspension()
        if canScanWindows {
            catalog.startObserving()
            refreshCatalog()
        }
    }

    func displayGeometryChanged() {
        guard isRunning else { return }
        trigger.invalidateDisplayGeometry()
        trigger.dismiss()
        refreshCatalog()
    }

    private func applySuspension() {
        trigger.setSuspended(menuOpen || lifecyclePaused)
    }

    private func permissionsChanged() {
        guard isRunning else { return }
        let ready = permissions.isReady
        trigger.setPermissionsGranted(ready)
        if canScanWindows {
            catalog.startObserving()
            refreshCatalog()
        } else if !ready {
            trigger.dismiss()
            catalog.stopObserving()
            catalog.clear()
        }
    }

    private func refreshCatalog() {
        guard canScanWindows else { return }
        // A queued refresh from an earlier run must not continue after a stop
        // or after a restart has begun another runtime session.
        let generation = runGeneration
        Task { [weak self] in
            guard let self, self.runGeneration == generation, self.canScanWindows else { return }
            await self.catalog.refresh()
        }
    }

    private func eligibleRecords(_ records: [WindowRecord]) -> [WindowRecord] {
        records.filter { record in
            (settings.preferences.includeMinimized || !record.isMinimized) &&
            !record.bundleIdentifier.map(settings.preferences.excludedBundleIdentifiers.contains).defaulting(to: false)
        }
    }

    private func open(on screen: NSScreen) {
        let openingStartedAt = ProcessInfo.processInfo.systemUptime
        guard canScanWindows else { trigger.dismiss(); return }
        let records = eligibleRecords(catalog.windows)
        let orderedIDs = mru.freezeOrder(eligibleIDs: records.map(\.id))
        let layout = makeLayout(screen: screen, count: orderedIDs.count)
        guard layout.visibleSlotCount > 0 else { trigger.dismiss(); return }
        sessionID = UUID()
        sessionScreen = screen
        sessionRecordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        overlay.appearance = settings.preferences.appearance.appearance
        overlay.detectionAreaSize = CGFloat(settings.preferences.detectionAreaSize)
        carousel = CarouselController(orderedIDs: orderedIDs,
                                      visibleSlots: layout.visibleSlotCount,
                                      currentID: catalog.focusedWindowID)
        render(layout: layout, animated: false)
        overlay.show(layout: layout, screen: screen)
        _ = overlay.contains(NSEvent.mouseLocation)
        trigger.didPresent()
#if DEBUG
        let openMilliseconds = Int((ProcessInfo.processInfo.systemUptime - openingStartedAt) * 1_000)
        diagnostics.debug("Gallery shell appeared in \(openMilliseconds) ms with \(layout.visibleSlotCount) slots")
#endif
        refreshCatalog()
    }

    private func closeSession() {
        failureDismissal?.cancel()
        failureDismissal = nil
        sessionID = nil
        sessionScreen = nil
        sessionRecordsByID.removeAll(keepingCapacity: false)
        sessionLayout = nil
        carousel?.resetScroll()
        carousel = nil
        overlay.dismiss()
    }

    private func makeLayout(screen: NSScreen, count: Int) -> ArcLayout {
        let preference = settings.preferences
        // An empty session still needs a visible slot and interaction area for
        // its message, without adding a selectable window to the carousel.
        let layoutCount = max(1, count)
        let key = LayoutKey(display: DisplayGeometry(displayFrame: screen.frame,
                                                     visibleFrame: screen.visibleFrame,
                                                     backingScale: screen.backingScaleFactor),
                            corner: preference.corner, visibleCount: min(layoutCount, 3),
                            previewScale: preference.previewScale)
        if let cached = sessionLayout, cached.key == key { return cached.layout }
        let layout = ArcLayoutEngine().layout(
            display: key.display,
            corner: key.corner,
            windowCount: layoutCount,
            preferredSlots: 3,
            previewScale: key.previewScale
        )
        sessionLayout = (key, layout)
        return layout
    }

    private func render(layout: ArcLayout? = nil, animated: Bool, movement: CarouselMovement? = nil) {
        guard let carousel, let screen = sessionScreen else { return }
        let snapshot = carousel.snapshot
        let layout = layout ?? makeLayout(screen: screen, count: snapshot.totalCount)
        let byID = sessionRecordsByID
        let visible = snapshot.visibleIDs.compactMap { byID[$0] }
        if let movement {
            overlay.model.transition(movement: movement, recordsByID: byID,
                                     layout: layout, snapshot: snapshot,
                                     reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        } else {
            overlay.model.update(records: visible, layout: layout,
                                 selectedID: snapshot.selectedID, animated: animated)
        }
        overlay.update(layout: layout, screen: screen)
    }

    private func handleScroll(_ event: NSEvent) {
        guard var carousel else { return }
        let input: ScrollInputKind
        if event.phase.contains(.ended) || event.momentumPhase.contains(.ended) {
            input = .ended
        } else if !event.momentumPhase.isEmpty {
            input = .momentum
        } else if event.hasPreciseScrollingDeltas {
            input = .trackpad
        } else {
            input = .wheel
        }
        let movement = carousel.scroll(deltaY: event.scrollingDeltaY, input: input,
                                       sensitivity: settings.preferences.scrollSensitivity,
                                       reversed: settings.preferences.reverseScroll)
        self.carousel = carousel
        if let movement { render(animated: true, movement: movement) }
    }

    private func navigate(by amount: Int) {
        guard var carousel else { return }
        let movement = carousel.navigate(by: amount)
        self.carousel = carousel
        if let movement { render(animated: true, movement: movement) }
    }

    private func activateSelection() {
        guard let id = carousel?.snapshot.selectedID,
              let record = catalog.record(for: id) else { return }
        activate(record)
    }

    private func activate(_ record: WindowRecord) {
        perform(.show, on: record)
    }

    private func perform(_ action: WindowContextAction, on record: WindowRecord) {
        guard canScanWindows else { trigger.dismiss(); return }
        guard let currentSession = sessionID,
              trigger.state == .browsing,
              carousel?.orderedIDs.contains(record.id) == true else { return }
        if action == .show, carousel?.snapshot.currentID == record.id,
           !record.isMinimized, !record.isHidden {
            trigger.dismiss()
            return
        }
        trigger.beginActivation()
        Task {
            guard canScanWindows, sessionID == currentSession else { return }
            let result = await activation.perform(action, on: record)
            guard canScanWindows, sessionID == currentSession else { return }
            switch result {
            case .success:
                trigger.dismiss()
                refreshCatalog()
            case .failure(let reason):
                overlay.model.failureText = reason
                failureDismissal = Task {
                    try? await Task.sleep(for: .seconds(1.7))
                    if !Task.isCancelled { trigger.dismiss() }
                }
            }
        }
    }

    private func catalogChanged(_ records: [WindowRecord]) {
        guard isRunning else { return }
        mru.retainOnly(Set(records.map(\.id)))
        guard var carousel else { return }
        let eligible = eligibleRecords(records)
        let valid = Set(eligible.map(\.id))
        sessionRecordsByID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        overlay.model.retainApplications(in: eligible)
        for id in carousel.orderedIDs where !valid.contains(id) { carousel.removeWindow(id: id) }
        // A populated session keeps its frozen order. When it is empty, newly
        // discovered windows can replace the message immediately.
        if carousel.orderedIDs.isEmpty && !eligible.isEmpty {
            carousel = CarouselController(orderedIDs: mru.freezeOrder(eligibleIDs: eligible.map(\.id)),
                                          visibleSlots: min(eligible.count, 3),
                                          currentID: catalog.focusedWindowID)
        }
        self.carousel = carousel
        render(animated: false)
    }

    private func focusChanged(_ id: UUID?) {
        guard isRunning else { return }
        guard let id else { return }
        mru.recordFocusedWindow(id)
        carousel?.setCurrentWindow(id)
    }
}

private extension Optional where Wrapped == Bool {
    func defaulting(to value: Bool) -> Bool { self ?? value }
}
