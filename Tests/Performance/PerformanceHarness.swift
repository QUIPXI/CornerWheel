import AppKit
import Combine
import Foundation
import SwiftUI

/// This is a local, offscreen microbenchmark. It does not open the wheel,
/// synthesize input, scan other apps' windows, or change persistent preferences.
@main
struct PerformanceHarness {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else {
            throw NSError(domain: "CornerWheelBenchmark", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "A logged-in graphical macOS session is required."])
        }
        let suite = "CornerWheelBenchmark.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let trigger = CornerTriggerController(settings: settings)
        trigger.setPermissionsGranted(true)
        let outside = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        let applications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        // Finder's process and icon stay the same across both binaries.
        let iconApp = applications.first(where: { $0.bundleIdentifier == "com.apple.finder" })
            ?? applications.first(where: { $0.icon != nil })
        let fixturePID = iconApp?.processIdentifier ?? ProcessInfo.processInfo.processIdentifier
        let records = (0..<100).map { index in
            WindowRecord(id: UUID(), processID: fixturePID,
                         bundleIdentifier: iconApp?.bundleIdentifier,
                         applicationName: "Benchmark", title: "Window \(index)",
                         bounds: CGRect(x: 0, y: 0, width: 1000, height: 700),
                         isMinimized: false, isHidden: false)
        }
        let layout = ArcLayoutEngine().layout(
            display: DisplayGeometry(displayFrame: screen.frame,
                                     visibleFrame: screen.visibleFrame,
                                     backingScale: screen.backingScaleFactor),
            corner: .bottomLeft, windowCount: records.count)
        let overlay = OverlayPanelController()
        overlay.model.update(records: Array(records.prefix(3)), layout: layout,
                             selectedID: records[1].id, animated: false)
        overlay.update(layout: layout, screen: screen)
        let coordinator = CornerWheelCoordinator(settings: settings, permissions: PermissionManager())
        coordinator.benchmarkPrepare(records: records, screen: screen)
        let view = OverlayView(model: overlay.model)
        if let pngDirectory = ProcessInfo.processInfo.environment["CORNERWHEEL_BENCHMARK_PNG_DIRECTORY"] {
            try capture(overlay.model, layout: layout, directory: pngDirectory)
        }
        var checksum = 0
        var observations: [String: Any] = [:]
        let sampleCount = Int(ProcessInfo.processInfo.environment["CORNERWHEEL_BENCHMARK_SAMPLES"] ?? "3") ?? 3

        func measure(_ name: String, iterations: Int, operation: () -> Void) {
            // One untimed warm-up batch ensures caches and framework lazy work
            // are not mistaken for steady-state CPU cost.
            for _ in 0..<min(iterations, 300) { operation() }
            drainMainQueue()
            var samples: [Double] = []
            for _ in 0..<sampleCount {
                let started = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<iterations { operation() }
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                samples.append(Double(elapsed) / Double(iterations) / 1_000)
                drainMainQueue()
            }
            observations[name] = ["iterations_per_sample": iterations,
                                  "unit": "microseconds_per_operation",
                                  "samples": samples,
                                  "median": median(samples)]
        }
        measure("pointer_outside_corner", iterations: 20_000) {
            trigger.handlePointer(.mouseMoved, at: outside, pressedMouseButtons: 0)
        }
        measure("unchanged_panel_geometry", iterations: 10_000) {
            overlay.update(layout: layout, screen: screen)
        }
        measure("wheel_step_100_windows", iterations: 500) {
            coordinator.benchmarkNavigate()
        }
        measure("three_card_icon_access", iterations: 500) {
            checksum &+= view.benchmarkIconAccess()
        }
        coordinator.benchmarkFinish()
        observations["context"] = [
            "fixture_windows": records.count,
            "display_count": NSScreen.screens.count,
            "running_regular_apps": applications.count,
            "screen_width": screen.frame.width,
            "screen_height": screen.frame.height,
            "backing_scale": screen.backingScaleFactor,
            "icon_available": iconApp != nil,
            "checksum": checksum,
            "reduce_motion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "scope": "Offscreen component CPU microbenchmarks; excludes actual frame presentation, AX scans, activation, and intended hover delay."
        ]
        let data = try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    @MainActor
    private static func drainMainQueue() {
        // Run queued animation completion outside the timed interval. No real
        // window is created; this avoids retaining stale closures across trials.
        RunLoop.main.run(until: Date().addingTimeInterval(0.23))
    }

    private static func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    @MainActor
    private static func capture(_ model: OverlayViewModel, layout: ArcLayout,
                                directory: String) throws {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // An unshown window gives AppKit a backing context without altering
        // focus, screen contents, or any other application's windows.
        let bounds = CGRect(origin: .zero, size: layout.panelFrame.size)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = bounds
        window.contentView = host
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            host.appearance = NSAppearance(named: appearance)
            host.needsLayout = true
            drainMainQueue()
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else {
                throw NSError(domain: "CornerWheelBenchmark", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Could not create offscreen bitmap."])
            }
            host.cacheDisplay(in: bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "CornerWheelBenchmark", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Could not encode offscreen PNG."])
            }
            try png.write(to: url.appendingPathComponent("overlay-\(name).png"))
        }
        window.contentView = nil
        window.close()
    }
}
