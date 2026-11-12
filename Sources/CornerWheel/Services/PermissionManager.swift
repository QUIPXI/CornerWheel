import AppKit
import ApplicationServices
import OSLog

@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    private var observers: [NSObjectProtocol] = []
    private let diagnostics = Logger(subsystem: "com.cornerwheel.CornerWheel", category: "Permissions")

    init() {
        recheck()
        diagnostics.notice("Accessibility available at launch: \(self.accessibilityGranted)")
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in Task { @MainActor [weak self] in self?.recheck() }
            })
        }
    }

    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    var isReady: Bool { accessibilityGranted }

    /// Window enumeration and activation require Accessibility access.
    func recheck() {
        let accessibility = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        )
        if accessibilityGranted != accessibility {
            diagnostics.notice("Accessibility availability changed: \(accessibility)")
            accessibilityGranted = accessibility
        }
    }

    /// Call only after an explicit click in onboarding or Settings. macOS may
    /// require the installed application to restart after granting access.
    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
        recheck()
    }

    func openAccessibilitySettings() {
        openPrivacySettings("Privacy_Accessibility")
    }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
