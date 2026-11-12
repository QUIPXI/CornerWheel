import AppKit
import Combine
import SwiftUI

enum CornerWheelHelp {
    static let url = URL(string: "https://cornerwheel.com/setup.html")!
}

@main
struct CornerWheelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let settings = SettingsStore()
    private let permissions = PermissionManager()
    private let updates = AppUpdateController()
    private var coordinator: CornerWheelCoordinator!
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var settingsWindow: NSWindow?
    private var settingsAwaitingActivation = false
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests create their own coordinators. The host must not start
        // pointer monitoring or window discovery on the owner's desktop.
        guard NSClassFromString("XCTestCase") == nil else { return }
        coordinator = CornerWheelCoordinator(settings: settings, permissions: permissions)
        coordinator.start()
        configureStatusItem()
        updates.start()
        updates.$pendingUpdateVersion.sink { [weak self] version in
            self?.refreshUpdateReminder(version: version)
        }.store(in: &subscriptions)

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.coordinator.resumeAfterWake() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.coordinator.pauseForSession() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.coordinator.pauseForSession() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.coordinator.resumeAfterWake() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.permissions.recheck() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.coordinator.displayGeometryChanged() }
        })

        if !permissions.isReady || !UserDefaults.standard.bool(forKey: "CornerWheel.onboardingSeen") {
            openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        subscriptions.removeAll()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.make()
        item.button?.toolTip = "CornerWheel"

        let menu = NSMenu()
        menu.delegate = self
        let enable = NSMenuItem(title: "Disable CornerWheel", action: #selector(toggleEnabled), keyEquivalent: "")
        enable.tag = 10
        menu.addItem(enable)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Show Window Wheel", action: #selector(showWindowWheel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Get Help", action: #selector(getHelp), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "About CornerWheel", action: #selector(showAbout), keyEquivalent: ""))
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.tag = 12
        menu.addItem(update)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit CornerWheel", action: #selector(quit), keyEquivalent: "q"))
        for menuItem in menu.items { menuItem.target = self }
        item.menu = menu
        statusItem = item
        self.menu = menu
        refreshEnabledMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        permissions.recheck()
        coordinator.setMenuOpen(true)
        refreshEnabledMenu()
    }

    func menuDidClose(_ menu: NSMenu) { coordinator.setMenuOpen(false) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) { return updates.canCheckForUpdates }
        if menuItem.action == #selector(showWindowWheel) {
            return settings.preferences.enabled && permissions.isReady
        }
        return true
    }

    private func refreshEnabledMenu() {
        menu?.item(withTag: 10)?.title = settings.preferences.enabled ? "Disable CornerWheel" : "Enable CornerWheel"
    }

    private func refreshUpdateReminder(version: String?) {
        let available = version != nil
        menu?.item(withTag: 12)?.title = version.map { "Update to \($0)…" } ?? "Check for Updates…"
        statusItem?.length = available ? 36 : NSStatusItem.squareLength
        statusItem?.button?.imagePosition = .imageLeading
        statusItem?.button?.title = available ? "•" : ""
        statusItem?.button?.toolTip = available ? "CornerWheel — Update available" : "CornerWheel"
        statusItem?.button?.setAccessibilityLabel(available ? "CornerWheel, update available" : "CornerWheel")
    }

    @objc private func checkForUpdates() {
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated { self?.updates.checkForUpdates() }
        }
    }

    @objc private func toggleEnabled() {
        settings.preferences.enabled.toggle()
        coordinator.settingsChanged()
    }

    @objc private func showWindowWheel() {
        // Keyboard users can navigate the macOS status menu to this command.
        // Wait for menu tracking to finish before making the wheel key.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated { self?.coordinator.showFromMenu() }
        }
    }

    @objc private func getHelp() {
        RunLoop.main.perform(inModes: [.default]) {
            NSWorkspace.shared.open(CornerWheelHelp.url)
        }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "CornerWheel"
        alert.informativeText = "A free, local, native window switcher for the bottom corner of your Mac. It uses static app icons and does not capture or record your screen."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        // Finish status-menu tracking before changing activation or window order.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated { self?.presentSettings() }
        }
    }

    private func presentSettings() {
        let contentSize = NSSize(width: 570, height: 690)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.center()
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.delegate = self
            window.contentView = NSHostingView(rootView:
                SettingsView(settings: settings, permissions: permissions, updates: updates))
            settingsWindow = window
        }
        guard let window = settingsWindow else { return }
        window.title = "CornerWheel Settings"
        window.setContentSize(contentSize)
        UserDefaults.standard.set(true, forKey: "CornerWheel.onboardingSeen")
        window.appearance = settings.preferences.appearance.appearance
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if window.isMiniaturized { window.deminiaturize(nil) }
        settingsAwaitingActivation = !NSApp.isActive
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Activation is asynchronous; make the requested window visible now,
        // then establish keyboard focus when macOS finishes activating the app.
        window.orderFrontRegardless()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard settingsAwaitingActivation else { return }
        settingsAwaitingActivation = false
        guard let window = settingsWindow, window.isVisible, !window.isMiniaturized else { return }
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillMiniaturize(_ notification: Notification) {
        settingsAwaitingActivation = false
    }

    func windowWillClose(_ notification: Notification) {
        settingsAwaitingActivation = false
        permissions.recheck()
    }
}

private enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()

            // The three separate, fanned panels match the brand's minimal glyph.
            let left = NSBezierPath()
            left.move(to: NSPoint(x: 0.6, y: 4.7))
            left.curve(to: NSPoint(x: 1.0, y: 5.9), controlPoint1: NSPoint(x: 0.4, y: 5.1), controlPoint2: NSPoint(x: 0.5, y: 5.5))
            left.line(to: NSPoint(x: 3.6, y: 10.1))
            left.curve(to: NSPoint(x: 4.8, y: 10.4), controlPoint1: NSPoint(x: 3.9, y: 10.6), controlPoint2: NSPoint(x: 4.4, y: 10.7))
            left.line(to: NSPoint(x: 11.0, y: 5.0))
            left.curve(to: NSPoint(x: 11.2, y: 4.1), controlPoint1: NSPoint(x: 11.3, y: 4.7), controlPoint2: NSPoint(x: 11.4, y: 4.4))
            left.line(to: NSPoint(x: 10.3, y: 1.1))
            left.curve(to: NSPoint(x: 9.5, y: 0.6), controlPoint1: NSPoint(x: 10.1, y: 0.6), controlPoint2: NSPoint(x: 9.9, y: 0.5))
            left.line(to: NSPoint(x: 1.2, y: 3.7))
            left.curve(to: NSPoint(x: 0.6, y: 4.7), controlPoint1: NSPoint(x: 0.7, y: 3.9), controlPoint2: NSPoint(x: 0.5, y: 4.3))
            left.close()
            left.fill()

            let middle = NSBezierPath()
            middle.move(to: NSPoint(x: 6.0, y: 11.5))
            middle.curve(to: NSPoint(x: 6.4, y: 12.5), controlPoint1: NSPoint(x: 5.8, y: 11.9), controlPoint2: NSPoint(x: 5.9, y: 12.2))
            middle.line(to: NSPoint(x: 10.2, y: 14.6))
            middle.curve(to: NSPoint(x: 11.0, y: 14.1), controlPoint1: NSPoint(x: 10.6, y: 14.9), controlPoint2: NSPoint(x: 10.9, y: 14.7))
            middle.line(to: NSPoint(x: 13.6, y: 5.6))
            middle.curve(to: NSPoint(x: 13.2, y: 4.7), controlPoint1: NSPoint(x: 13.8, y: 5.2), controlPoint2: NSPoint(x: 13.6, y: 4.9))
            middle.line(to: NSPoint(x: 12.7, y: 4.5))
            middle.curve(to: NSPoint(x: 12.1, y: 4.8), controlPoint1: NSPoint(x: 12.4, y: 4.4), controlPoint2: NSPoint(x: 12.2, y: 4.5))
            middle.close()
            middle.fill()

            let right = NSBezierPath()
            right.move(to: NSPoint(x: 12.2, y: 16.9))
            right.curve(to: NSPoint(x: 13.1, y: 17.5), controlPoint1: NSPoint(x: 12.2, y: 17.3), controlPoint2: NSPoint(x: 12.5, y: 17.5))
            right.line(to: NSPoint(x: 16.4, y: 17.5))
            right.curve(to: NSPoint(x: 17.5, y: 16.4), controlPoint1: NSPoint(x: 17.1, y: 17.5), controlPoint2: NSPoint(x: 17.5, y: 17.1))
            right.line(to: NSPoint(x: 17.5, y: 5.2))
            right.curve(to: NSPoint(x: 16.8, y: 4.6), controlPoint1: NSPoint(x: 17.5, y: 4.7), controlPoint2: NSPoint(x: 17.3, y: 4.5))
            right.line(to: NSPoint(x: 14.1, y: 5.5))
            right.curve(to: NSPoint(x: 13.7, y: 6.0), controlPoint1: NSPoint(x: 13.9, y: 5.6), controlPoint2: NSPoint(x: 13.7, y: 5.8))
            right.close()
            right.fill()

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "CornerWheel"
        return image
    }
}
