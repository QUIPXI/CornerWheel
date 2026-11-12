import ApplicationServices
import CoreGraphics
import Foundation

/// Finder reports a desktop accessibility element among `AXWindows` on some
/// systems. Role normally distinguishes it, and requiring a known window
/// subrole for Finder covers versions that expose it as an AXWindow instead.
/// A Finder folder named "Desktop" remains eligible: titles are not used here.
enum AXWindowEligibility {
    static func includes(bundleIdentifier: String?, role: String?, subrole: String?) -> Bool {
        guard role == "AXWindow" else { return false }
        switch subrole {
        case "AXStandardWindow", "AXDialog", "AXSystemDialog": return true
        case nil: return bundleIdentifier != "com.apple.finder"
        default: return false
        }
    }
}

/// Attribute errors occupy their original positions in a successful AX batch.
/// Treat them like a failed individual read, without shifting later values.
struct AXWindowAttributeValues {
    static let names: [CFString] = [kAXRoleAttribute as CFString, kAXSubroleAttribute as CFString,
                                   kAXPositionAttribute as CFString, kAXSizeAttribute as CFString,
                                   kAXMinimizedAttribute as CFString, kAXTitleAttribute as CFString]
    let role: String?
    let subrole: String?
    let bounds: CGRect?
    let isMinimized: Bool
    let title: String

    init?(values: [Any]) {
        guard values.count == Self.names.count else { return nil }
        role = values[0] as? String
        subrole = values[1] as? String
        bounds = Self.bounds(position: values[2] as CFTypeRef, size: values[3] as CFTypeRef)
        isMinimized = values[4] as? Bool ?? false
        title = values[5] as? String ?? ""
    }

    static func read(batch: () -> (AXError, [Any]?),
                     individual: (CFString) -> CFTypeRef?) -> Self? {
        let (error, values) = batch()
        if error == .success, let values, let decoded = Self(values: values) { return decoded }
        // Some providers time out or reject a batch while supporting separate
        // reads. Preserve discovery for them; only a destroyed object is final.
        guard error != .invalidUIElement else { return nil }
        return Self(values: names.map { individual($0) ?? kCFNull! })
    }

    private static func bounds(position: CFTypeRef, size: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            return nil
        }
        let positionValue = position as! AXValue
        let sizeValue = size as! AXValue
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else {
            return nil
        }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}

/// CF equality identifies the same AX object even when an app supplies a new
/// wrapper for it. CFHash has the same equality contract and avoids linear scans.
struct AXElementIdentity: Hashable {
    let element: AXUIElement
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// Cross-process AX calls live on this actor's executor, away from the UI.
/// Each target gets a short AX messaging timeout so one hung app cannot block
/// the gallery indefinitely. AX references stay inside the actor.
actor AccessibilityWindowStore {
    struct Application: Sendable {
        let processID: pid_t
        let launchDate: Date?
        let bundleIdentifier: String?
        let name: String
        let isHidden: Bool
    }

    struct Window: Sendable {
        let token: UUID
        let processID: pid_t
        let bundleIdentifier: String?
        let applicationName: String
        let title: String
        let bounds: CGRect
        let isMinimized: Bool
        let isHidden: Bool
    }

    private struct RetainedWindow {
        let processID: pid_t
        let launchDate: Date?
        let element: AXUIElement
    }

    private var retained: [UUID: RetainedWindow] = [:]
    private var tokensByProcess: [pid_t: [AXElementIdentity: UUID]] = [:]
    private var scanGeneration = 0
    private let messagingTimeout: Float = 0.20

    func clear() {
        scanGeneration += 1
        retained.removeAll()
        tokensByProcess.removeAll()
    }

    func scan(_ applications: [Application], includeMinimized: Bool) async -> [Window]? {
        scanGeneration += 1
        let generation = scanGeneration
        let live = Dictionary(uniqueKeysWithValues: applications.map { ($0.processID, $0.launchDate) })
        var nextRetained = retained.filter { _, item in
            guard let currentLaunchDate = live[item.processID] else { return false }
            return currentLaunchDate == item.launchDate
        }
        let knownByProcess = Self.identityIndex(nextRetained)

        var result: [Window] = []
        var observedTokens = Set<UUID>()
        var scannedProcessIDs = Set<pid_t>()
        for app in applications {
            await Task.yield()
            guard !Task.isCancelled, generation == scanGeneration else { return nil }
            let appElement = AXUIElementCreateApplication(app.processID)
            AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
            guard let windows = elements(appElement, attribute: kAXWindowsAttribute as CFString) else { continue }
            var remainingWorkTime: TimeInterval = 0.9
            var seenElements = Set<AXElementIdentity>()
            var completed = true
            for element in windows {
                await Task.yield()
                guard !Task.isCancelled, generation == scanGeneration else { return nil }
                guard remainingWorkTime > 0 else { completed = false; break }
                // Activation may run while the scan yields. Its elapsed time
                // must not consume this app's own enumeration work budget.
                let startedAt = ProcessInfo.processInfo.systemUptime
                defer { remainingWorkTime -= ProcessInfo.processInfo.systemUptime - startedAt }
                let identity = AXElementIdentity(element: element)
                guard seenElements.insert(identity).inserted else { continue }
                AXUIElementSetMessagingTimeout(element, messagingTimeout)
                guard let values = windowAttributes(element) else { continue }
                guard AXWindowEligibility.includes(bundleIdentifier: app.bundleIdentifier,
                                                   role: values.role, subrole: values.subrole) else { continue }
                guard let bounds = values.bounds, bounds.width >= 100, bounds.height >= 75,
                      bounds.origin.x.isFinite, bounds.origin.y.isFinite else { continue }
                let minimized = values.isMinimized
                if minimized && !includeMinimized { continue }
                let token = knownByProcess[app.processID]?[identity] ?? UUID()
                observedTokens.insert(token)
                nextRetained[token] = RetainedWindow(processID: app.processID,
                                                  launchDate: app.launchDate,
                                                  element: element)
                result.append(Window(token: token, processID: app.processID,
                                     bundleIdentifier: app.bundleIdentifier,
                                     applicationName: app.name,
                                     title: values.title,
                                     bounds: bounds, isMinimized: minimized,
                                     isHidden: app.isHidden))
            }
            if completed { scannedProcessIDs.insert(app.processID) }
        }
        // A successful app scan retires absent windows; a timed-out scan keeps
        // references briefly for a later retry. Process exit/PID reuse was
        // already removed above.
        guard !Task.isCancelled, generation == scanGeneration else { return nil }
        retained = nextRetained.filter { token, item in
            !scannedProcessIDs.contains(item.processID) || observedTokens.contains(token)
        }
        tokensByProcess = Self.identityIndex(retained)
        return result
    }

    private static func identityIndex(_ windows: [UUID: RetainedWindow]) -> [pid_t: [AXElementIdentity: UUID]] {
        var result: [pid_t: [AXElementIdentity: UUID]] = [:]
        for (token, window) in windows {
            result[window.processID, default: [:]][AXElementIdentity(element: window.element)] = token
        }
        return result
    }

    func contains(_ token: UUID, processID: pid_t) -> Bool {
        guard let item = retained[token], item.processID == processID else { return false }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let windows = elements(app, attribute: kAXWindowsAttribute as CFString) else { return false }
        return windows.contains { CFEqual($0, item.element) }
    }

    func isMinimized(_ token: UUID, processID: pid_t) -> Bool? {
        guard let item = retained[token], item.processID == processID else { return nil }
        AXUIElementSetMessagingTimeout(item.element, messagingTimeout)
        return bool(item.element, attribute: kAXMinimizedAttribute as CFString)
    }

    func restoreAndRaise(_ token: UUID, processID: pid_t, restore: Bool) -> Bool {
        guard let item = retained[token], item.processID == processID,
              contains(token, processID: processID) else { return false }
        let window = item.element
        AXUIElementSetMessagingTimeout(window, messagingTimeout)
        if restore {
            _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return raised == .success
    }

    func setMinimized(_ minimized: Bool, token: UUID, processID: pid_t) async -> ActivationResult {
        guard let item = retained[token], item.processID == processID,
              contains(token, processID: processID) else {
            return .failure("The selected window is no longer available")
        }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(item.element, kAXMinimizedAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return .failure("This window does not support minimizing")
        }
        let value = minimized ? kCFBooleanTrue! : kCFBooleanFalse!
        let error = AXUIElementSetAttributeValue(item.element, kAXMinimizedAttribute as CFString, value)
        return await completeMinimizationRequest(minimized, error: error, readState: {
            // Keep the exact AX reference across retries. A catalog refresh
            // can remove its token as soon as the window becomes minimized.
            self.bool(item.element, attribute: kAXMinimizedAttribute as CFString)
        })
    }

    func completeMinimizationRequest(_ minimized: Bool, error: AXError,
                                     readState: () -> Bool?,
                                     waitForState: () async throws -> Void = {
                                         try await Task.sleep(for: .milliseconds(100))
                                     }) async -> ActivationResult {
        // A successful set is an accepted request; some apps publish the
        // minimized attribute only after the animation finishes.
        if error == .success { return .success }
        guard error == .cannotComplete else {
            return .failure(minimized ? "Could not minimize this window" : "Could not restore this window")
        }
        // The short AX timeout may expire while the app is still carrying
        // out the request. Observe it without issuing the action again.
        for attempt in 0..<6 {
            guard !Task.isCancelled else { break }
            if readState() == minimized { return .success }
            if attempt < 5 {
                do { try await waitForState() }
                catch { break }
            }
        }
        return .failure(minimized ? "Could not confirm that this window was minimized"
                                  : "Could not confirm that this window was restored")
    }

    func closeWindow(_ token: UUID, processID: pid_t) -> ActivationResult {
        guard let item = retained[token], item.processID == processID,
              contains(token, processID: processID) else {
            return .failure("The selected window is no longer available")
        }
        guard let button = element(item.element, attribute: kAXCloseButtonAttribute as CFString) else {
            return .failure("This window does not support closing")
        }
        AXUIElementSetMessagingTimeout(button, messagingTimeout)
        guard bool(button, attribute: kAXEnabledAttribute as CFString) != false,
              AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            return .failure("Could not close this window")
        }
        // The app owns any save confirmation; accepting the close request
        // does not imply an unsaved document has already disappeared.
        return .success
    }

    func focusedToken(processID: pid_t) -> UUID? {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let focused = element(app, attribute: kAXFocusedWindowAttribute as CFString) else { return nil }
        return tokensByProcess[processID]?[AXElementIdentity(element: focused)]
    }

    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &raw) == .success else { return nil }
        return raw
    }

    private func elements(_ element: AXUIElement, attribute name: CFString) -> [AXUIElement]? {
        attribute(element, name) as? [AXUIElement]
    }

    private func element(_ element: AXUIElement, attribute name: CFString) -> AXUIElement? {
        guard let raw = attribute(element, name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private func bool(_ element: AXUIElement, attribute name: CFString) -> Bool? {
        attribute(element, name) as? Bool
    }

    private func windowAttributes(_ element: AXUIElement) -> AXWindowAttributeValues? {
        AXWindowAttributeValues.read(batch: {
            var raw: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(element, AXWindowAttributeValues.names as CFArray,
                                                              [], &raw)
            return (error, raw as? [Any])
        }, individual: { attribute(element, $0) })
    }
}
