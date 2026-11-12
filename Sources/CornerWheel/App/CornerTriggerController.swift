import AppKit
import Combine
import OSLog

@MainActor
final class CornerTriggerController: ObservableObject {
    private let diagnostics = Logger(subsystem: "com.cornerwheel.CornerWheel", category: "Trigger")
    enum State: Equatable {
        case disabled
        case permissionBlocked
        case idle
        case armed
        case presenting
        case browsing
        case activating
        case dismissing
    }

    @Published private(set) var state: State = .idle

    var onShow: ((NSScreen) -> Void)?
    var onDismiss: (() -> Void)?
    var interactionContains: ((NSPoint) -> Bool)?
    var interactionClickContains: ((NSPoint) -> Bool)?
    var interactionRegion: (() -> WheelInteractionRegion?)?

    private let settings: SettingsStore
    private var started = false
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var dwellTimer: Timer?
    private var dismissalTimer: Timer?
    private var armedScreen: NSScreen?
    private var requiresTriggerExit = false
    private var openedManually = false
    private var contextMenuOpen = false
    private var dismissedInteractionRegion: WheelInteractionRegion?
    private var suspended = false
    private var permissionsGranted = false
    private var settingsSubscription: AnyCancellable?
    private let screens: () -> [NSScreen]
    private var screenObserver: NSObjectProtocol?
    private var triggerRegions: [(screen: NSScreen, frame: CGRect)] = []
    private var triggerConfiguration: TriggerConfiguration?

    private struct TriggerConfiguration: Equatable {
        let corner: CornerChoice
        let displays: ActivationDisplays
        let side: Double
    }

    init(settings: SettingsStore, screens: @escaping () -> [NSScreen] = { NSScreen.screens }) {
        self.settings = settings
        self.screens = screens
        settingsSubscription = settings.$preferences.sink { [weak self] _ in
            DispatchQueue.main.async { self?.settingsChanged() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateDisplayGeometry() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func invalidateDisplayGeometry() {
        triggerConfiguration = nil
        triggerRegions.removeAll(keepingCapacity: true)
    }

    func start() {
        guard !started else { return }
        started = true
        invalidateDisplayGeometry()
        installMissingMonitors()
        refreshState()
    }

    func stop() {
        started = false
        cancelTimers()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        armedScreen = nil
        requiresTriggerExit = false
        dismissedInteractionRegion = nil
        openedManually = false
        contextMenuOpen = false
    }

    func setPermissionsGranted(_ granted: Bool) {
        permissionsGranted = granted
        if granted && started { installMissingMonitors() }
        refreshState()
    }

    func setSuspended(_ value: Bool) {
        suspended = value
        if value { dismiss() }
        if !value { invalidateDisplayGeometry() }
        if !value && started && permissionsGranted { installMissingMonitors() }
        refreshState()
    }

    private func installMissingMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                          .otherMouseDragged, .leftMouseDown, .rightMouseDown,
                                          .otherMouseDown]
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handle(event)
                return event
            }
            if localMonitor == nil { diagnostics.error("Local pointer monitor could not be installed") }
        }
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handle(event)
            }
            if globalMonitor == nil { diagnostics.error("Global pointer monitor could not be installed") }
        }
    }

    func didPresent() {
        guard state == .presenting else { return }
        state = .browsing
    }

    func showManually(on screen: NSScreen) {
        guard settings.preferences.enabled, permissionsGranted, !suspended else { return }
        cancelTimers()
        requiresTriggerExit = false
        dismissedInteractionRegion = nil
        openedManually = true
        state = .presenting
        onShow?(screen)
    }

    func beginActivation() {
        guard state == .browsing else { return }
        state = .activating
        cancelTimers()
    }

    func setContextMenuOpen(_ value: Bool, at point: NSPoint? = nil) {
        guard !value || state == .browsing else { return }
        contextMenuOpen = value
        cancelTimers()
        if !value, state == .browsing {
            handlePointer(.mouseMoved, at: point ?? NSEvent.mouseLocation, pressedMouseButtons: 0)
        }
    }

    func dismiss(at point: NSPoint? = nil) {
        guard state == .armed || state == .presenting || state == .browsing || state == .activating else {
            cancelTimers()
            refreshState()
            return
        }
        let wasOpen = state == .presenting || state == .browsing || state == .activating
        state = .dismissing
        openedManually = false
        contextMenuOpen = false
        cancelTimers()
        armedScreen = nil
        // Capture this before onDismiss clears the overlay. Exiting only the
        // small trigger square must not reopen a wheel dismissed inside it.
        dismissedInteractionRegion = interactionRegion?()
        let dismissalPoint = point ?? NSEvent.mouseLocation
        requiresTriggerExit = dismissedInteractionRegion?.contains(dismissalPoint)
            ?? (triggerScreen(containing: dismissalPoint) != nil)
        if !requiresTriggerExit { dismissedInteractionRegion = nil }
        if wasOpen { onDismiss?() }
        refreshState()
    }

    private func settingsChanged() {
        if !settings.preferences.enabled { dismiss() }
        refreshState()
    }

    private func refreshState() {
        guard state != .presenting && state != .browsing && state != .activating else { return }
        if !settings.preferences.enabled || suspended {
            state = .disabled
        } else if !permissionsGranted {
            state = .permissionBlocked
        } else if state != .armed {
            state = .idle
        }
    }

    private func handle(_ event: NSEvent) {
        handlePointer(event.type, at: NSEvent.mouseLocation, pressedMouseButtons: NSEvent.pressedMouseButtons)
    }

    func handlePointer(_ eventType: NSEvent.EventType, at point: NSPoint, pressedMouseButtons: Int) {
        // Native menus can extend beyond the wheel. Their own tracking loop
        // owns pointer clicks and Escape until the menu closes.
        guard !contextMenuOpen else { return }
        let zoneScreen = triggerScreen(containing: point)

        if requiresTriggerExit, zoneScreen == nil,
           !(dismissedInteractionRegion?.contains(point) ?? false) {
            requiresTriggerExit = false
            dismissedInteractionRegion = nil
        }

        switch state {
        case .armed:
            if !Self.sameDisplay(zoneScreen, armedScreen) || isDragging(eventType) || pressedMouseButtons != 0 {
                cancelDwell()
                state = .idle
            }
        case .presenting, .browsing:
            let inside = interactionContains?(point) ?? false
            if (eventType == .leftMouseDown || eventType == .rightMouseDown || eventType == .otherMouseDown),
               !(interactionClickContains?(point) ?? inside) {
                dismiss(at: point)
                return
            }
            if inside {
                openedManually = false
                dismissalTimer?.invalidate()
                dismissalTimer = nil
            } else if !openedManually && dismissalTimer == nil {
                dismissalTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.dismiss() }
                }
            }
        case .idle:
            guard !requiresTriggerExit, let zoneScreen, !isDragging(eventType), pressedMouseButtons == 0 else { return }
            armedScreen = zoneScreen
            state = .armed
            let delay = max(0.05, settings.preferences.hoverDelay)
            dwellTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.dwellCompleted() }
            }
        case .disabled, .permissionBlocked, .activating, .dismissing:
            break
        }
    }

    private func dwellCompleted() {
        dwellTimer = nil
        guard state == .armed, let screen = armedScreen,
              Self.sameDisplay(triggerScreen(containing: NSEvent.mouseLocation), screen),
              NSEvent.pressedMouseButtons == 0 else {
            state = .idle
            return
        }
        state = .presenting
        openedManually = false
        onShow?(screen)
    }

    func triggerScreen(containing point: NSPoint) -> NSScreen? {
        guard settings.preferences.enabled, !suspended, permissionsGranted else { return nil }
        let preferences = settings.preferences
        let configuration = TriggerConfiguration(corner: preferences.corner,
                                                 displays: preferences.activationDisplays,
                                                 side: preferences.detectionAreaSize)
        // Compare the current preferences here so a slider/corner change takes
        // effect before the asynchronous Combine settings callback runs.
        if triggerConfiguration != configuration {
            triggerRegions = screens().enumerated().compactMap { index, screen in
                guard configuration.displays == .all || index == 0 else { return nil }
                let frame = screen.frame
                let display = DisplayGeometry(displayFrame: frame, visibleFrame: frame)
                return (screen, display.triggerFrame(corner: configuration.corner,
                                                     side: CGFloat(configuration.side)))
            }
            triggerConfiguration = configuration
        }
        for region in triggerRegions where region.frame.contains(point) {
            return region.screen
        }
        return nil
    }

    private static func sameDisplay(_ first: NSScreen?, _ second: NSScreen?) -> Bool {
        guard let first, let second else { return false }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let firstID = first.deviceDescription[key] as? NSNumber
        let secondID = second.deviceDescription[key] as? NSNumber
        if let firstID, let secondID { return firstID.uint32Value == secondID.uint32Value }
        return first.frame == second.frame
    }

    private func isDragging(_ eventType: NSEvent.EventType) -> Bool {
        eventType == .leftMouseDragged || eventType == .rightMouseDragged || eventType == .otherMouseDragged
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        armedScreen = nil
    }

    private func cancelTimers() {
        cancelDwell()
        dismissalTimer?.invalidate()
        dismissalTimer = nil
    }
}
