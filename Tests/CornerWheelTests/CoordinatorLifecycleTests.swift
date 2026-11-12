import XCTest
@testable import CornerWheel

@MainActor
final class CoordinatorLifecycleTests: XCTestCase {
    func testFreshInstallationStartsWithoutAccountOrActivationState() {
        let suite = "CornerWheelCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        // Exercise startup without enumerating this machine's windows.
        settings.preferences.enabled = false
        let coordinator = CornerWheelCoordinator(settings: settings, permissions: PermissionManager())
        defer { coordinator.stop() }

        coordinator.start()
        XCTAssertTrue(coordinator.isRunning)
        coordinator.start()
        XCTAssertTrue(coordinator.isRunning, "Repeated startup must be harmless")
    }

    func testStoppedRuntimeStaysStoppedAcrossQueuedSystemCallbacksUntilExplicitRestart() async {
        let suite = "CornerWheelCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.preferences.enabled = false
        let coordinator = CornerWheelCoordinator(settings: settings, permissions: PermissionManager())
        defer { coordinator.stop() }

        coordinator.start()
        settings.preferences.includeMinimized.toggle()
        coordinator.stop()
        coordinator.resumeAfterWake()
        coordinator.displayGeometryChanged()
        coordinator.settingsChanged()
        coordinator.setMenuOpen(false)
        await drainMainQueue()
        XCTAssertFalse(coordinator.isRunning)

        coordinator.start()
        XCTAssertTrue(coordinator.isRunning)
        coordinator.stop()
        XCTAssertFalse(coordinator.isRunning)
    }

    func testMenuAndSleepLifecycleDoNotPermanentlyStopFreeRuntime() async {
        let suite = "CornerWheelCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.preferences.enabled = false
        let coordinator = CornerWheelCoordinator(settings: settings, permissions: PermissionManager())
        defer { coordinator.stop() }

        coordinator.start()
        coordinator.setMenuOpen(true)
        coordinator.pauseForSession()
        coordinator.setMenuOpen(false)
        coordinator.resumeAfterWake()
        coordinator.displayGeometryChanged()
        await drainMainQueue()
        XCTAssertTrue(coordinator.isRunning)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
