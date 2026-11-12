import AppKit
import ApplicationServices
import CoreGraphics

private let cornerWheelAXObserverCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    let catalog = Unmanaged<WindowCatalog>.fromOpaque(refcon).takeUnretainedValue()
    Task { @MainActor in catalog.scheduleRefresh() }
}

/// A burst of requests shares one worker and at most one pending pass. The
/// worker is independent of individual waiters, so cancelling a debounce does
/// not cancel a refresh another caller is awaiting.
@MainActor
final class WindowCatalogRefreshScheduler {
    private var worker: Task<Void, Never>?
    private var pending = false
    private var generation = 0

    func refresh(operation: @escaping (Int) async -> Void) async {
        guard !Task.isCancelled else { return }
        generation += 1
        pending = true
        while pending || worker != nil {
            if let worker {
                await worker.value
            } else {
                let task = Task { @MainActor in
                    while self.pending && !Task.isCancelled {
                        self.pending = false
                        await operation(self.generation)
                    }
                    self.worker = nil
                }
                worker = task
                await task.value
            }
        }
    }

    func isCurrent(_ generation: Int) -> Bool { self.generation == generation }

    func invalidate() {
        generation += 1
        pending = false
        worker?.cancel()
    }
}

/// Discovers individually actionable Accessibility windows. Window metadata
/// supplies the title used alongside each application's static icon.
@MainActor
final class WindowCatalog: ObservableObject {
    @Published private(set) var windows: [WindowRecord] = []
    @Published private(set) var focusedWindowID: UUID?

    var includeMinimized = false { didSet { scheduleRefresh() } }
    var excludedBundleIdentifiers: Set<String> = [] { didSet { scheduleRefresh() } }

    let axStore = AccessibilityWindowStore()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var axObservers: [pid_t: AXObserver] = [:]
    private var debouncedRefresh: Task<Void, Never>?
    private var storeClearing: Task<Void, Never>?
    private let refreshScheduler = WindowCatalogRefreshScheduler()
    private var recordsByID: [UUID: WindowRecord] = [:]
    private var observing = false

    func record(for id: UUID) -> WindowRecord? { recordsByID[id] }

    func refresh() async {
        debouncedRefresh?.cancel()
        debouncedRefresh = nil
        await refreshScheduler.refresh { [weak self] generation in
            await self?.performRefresh(generation: generation)
        }
    }

    private func performRefresh(generation: Int) async {
        // Permission loss clears the actor asynchronously. A new session must
        // finish that clear before scanning, or it could erase the new results.
        await storeClearing?.value
        guard refreshScheduler.isCurrent(generation), !Task.isCancelled else { return }
        guard AXIsProcessTrusted() else {
            clear()
            return
        }
        let apps = eligibleApplications()
        guard let axWindows = await axStore.scan(apps, includeMinimized: includeMinimized) else { return }
        guard refreshScheduler.isCurrent(generation), !Task.isCancelled else { return }

        publishWindows(axWindows.map { item in
            return WindowRecord(id: item.token, processID: item.processID,
                                bundleIdentifier: item.bundleIdentifier,
                                applicationName: item.applicationName,
                                title: item.title, bounds: item.bounds,
                                isMinimized: item.isMinimized, isHidden: item.isHidden)
        })
        let focus: UUID?
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            focus = await axStore.focusedToken(processID: pid)
        } else {
            focus = nil
        }
        guard refreshScheduler.isCurrent(generation), !Task.isCancelled else { return }
        if focusedWindowID != focus { focusedWindowID = focus }
    }

    func publishWindows(_ records: [WindowRecord]) {
        guard records.count != windows.count ||
                !zip(records, windows).allSatisfy({ $0.hasSameMetadata(as: $1) }) else { return }
        recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        windows = records
    }

    func startObserving() {
        guard !observing else { return }
        observing = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.rebuildAXObservers()
                    self?.scheduleRefresh()
                }
            })
        }
        rebuildAXObservers()
        scheduleRefresh()
    }

    func stopObserving() {
        refreshScheduler.invalidate()
        debouncedRefresh?.cancel()
        debouncedRefresh = nil
        guard observing else { return }
        observing = false
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        for observer in axObservers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), CFRunLoopMode.commonModes)
        }
        axObservers.removeAll()
    }

    func clear() {
        refreshScheduler.invalidate()
        debouncedRefresh?.cancel()
        debouncedRefresh = nil
        publishWindows([])
        if focusedWindowID != nil { focusedWindowID = nil }
        let previousClear = storeClearing
        storeClearing = Task {
            await previousClear?.value
            await axStore.clear()
        }
    }

    fileprivate func scheduleRefresh() {
        guard observing else { return }
        debouncedRefresh?.cancel()
        debouncedRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.debouncedRefresh = nil
            await self?.refresh()
        }
    }

    private func eligibleApplications() -> [AccessibilityWindowStore.Application] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excludedSystemBundles: Set<String> = [
            "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui",
            "com.apple.WindowManager", "com.apple.loginwindow", "com.apple.systemuiserver"
        ]
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier != ownPID, app.activationPolicy != .prohibited else { return nil }
            if let bundleID = app.bundleIdentifier,
               excludedBundleIdentifiers.contains(bundleID) || excludedSystemBundles.contains(bundleID) {
                return nil
            }
            return AccessibilityWindowStore.Application(
                processID: app.processIdentifier, launchDate: app.launchDate,
                bundleIdentifier: app.bundleIdentifier,
                name: app.localizedName ?? app.bundleIdentifier ?? "Application",
                isHidden: app.isHidden
            )
        }
    }

    private func rebuildAXObservers() {
        guard observing, AXIsProcessTrusted() else { return }
        let apps = eligibleApplications()
        let pids = Set(apps.map(\.processID))
        for (pid, observer) in Array(axObservers) where !pids.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), CFRunLoopMode.commonModes)
            axObservers[pid] = nil
        }
        for app in apps where axObservers[app.processID] == nil {
            var observer: AXObserver?
            guard AXObserverCreate(app.processID, cornerWheelAXObserverCallback, &observer) == .success,
                  let observer else { continue }
            let appElement = AXUIElementCreateApplication(app.processID)
            AXUIElementSetMessagingTimeout(appElement, 0.15)
            let context = Unmanaged.passUnretained(self).toOpaque()
            var installed = false
            for name in [kAXFocusedWindowChangedNotification as CFString,
                         kAXMainWindowChangedNotification as CFString,
                         kAXWindowCreatedNotification as CFString] {
                installed = AXObserverAddNotification(observer, appElement, name, context) == .success || installed
            }
            guard installed else { continue }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), CFRunLoopMode.commonModes)
            axObservers[app.processID] = observer
        }
    }
}
