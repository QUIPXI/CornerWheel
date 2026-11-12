import AppKit
import Combine
import Foundation
import ServiceManagement

enum CornerChoice: String, Codable, CaseIterable, Identifiable {
    case bottomLeft
    case bottomRight

    var id: String { rawValue }
    var label: String { self == .bottomLeft ? "Bottom left" : "Bottom right" }
}

enum ActivationDisplays: String, Codable, CaseIterable, Identifiable {
    case main
    case all

    var id: String { rawValue }
    var label: String { self == .main ? "Main display only" : "All displays" }
}

enum PreviewSlots: String, Codable, CaseIterable, Identifiable {
    case automatic
    case three
    case four

    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Auto"
        case .three: return "Three"
        case .four: return "Four"
        }
    }
}

enum AppearanceChoice: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

struct CornerWheelPreferences: Codable, Equatable {
    var enabled = true
    var corner: CornerChoice = .bottomLeft
    var activationDisplays: ActivationDisplays = .main
    var detectionAreaSize = Double(DisplayGeometry.triggerSideLength) {
        didSet { detectionAreaSize = Self.normalizedDetectionAreaSize(detectionAreaSize) }
    }
    var previewSlots: PreviewSlots = .automatic
    var previewScale = 1.0
    var hoverDelay = 0.2
    var scrollSensitivity = 1.0
    var reverseScroll = false
    var includeMinimized = false
    var excludedBundleIdentifiers: Set<String> = []
    var appearance: AppearanceChoice = .system
    var launchAtLogin = false

    static let detectionAreaSizeRange: ClosedRange<Double> = 16...160
    static let defaults = CornerWheelPreferences()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, corner, activationDisplays, detectionAreaSize, previewSlots, previewScale
        case hoverDelay, scrollSensitivity, reverseScroll, includeMinimized
        case excludedBundleIdentifiers, appearance, launchAtLogin
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        corner = try values.decodeIfPresent(CornerChoice.self, forKey: .corner) ?? corner
        activationDisplays = try values.decodeIfPresent(ActivationDisplays.self, forKey: .activationDisplays) ?? activationDisplays
        // Older saved preferences have no detection-area value. Keep their
        // other choices and use the original 32-point trigger as the default.
        detectionAreaSize = Self.normalizedDetectionAreaSize(
            try values.decodeIfPresent(Double.self, forKey: .detectionAreaSize) ?? detectionAreaSize)
        previewSlots = try values.decodeIfPresent(PreviewSlots.self, forKey: .previewSlots) ?? previewSlots
        previewScale = try values.decodeIfPresent(Double.self, forKey: .previewScale) ?? previewScale
        hoverDelay = try values.decodeIfPresent(Double.self, forKey: .hoverDelay) ?? hoverDelay
        scrollSensitivity = try values.decodeIfPresent(Double.self, forKey: .scrollSensitivity) ?? scrollSensitivity
        reverseScroll = try values.decodeIfPresent(Bool.self, forKey: .reverseScroll) ?? reverseScroll
        includeMinimized = try values.decodeIfPresent(Bool.self, forKey: .includeMinimized) ?? includeMinimized
        excludedBundleIdentifiers = try values.decodeIfPresent(Set<String>.self, forKey: .excludedBundleIdentifiers) ?? excludedBundleIdentifiers
        appearance = try values.decodeIfPresent(AppearanceChoice.self, forKey: .appearance) ?? appearance
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
    }

    private static func normalizedDetectionAreaSize(_ value: Double) -> Double {
        guard value.isFinite else { return Double(DisplayGeometry.triggerSideLength) }
        return min(detectionAreaSizeRange.upperBound, max(detectionAreaSizeRange.lowerBound, value))
    }
}

struct RunningApplicationOption: Identifiable {
    let name: String
    let bundleID: String
    var id: String { bundleID }
}

@MainActor
final class SettingsStore: ObservableObject {
    private static let preferencesKey = "CornerWheel.preferences.v1"
    private let defaults: UserDefaults

    @Published var preferences: CornerWheelPreferences {
        didSet { save() }
    }
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var runningApplications: [RunningApplicationOption] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.preferencesKey),
           let value = try? JSONDecoder().decode(CornerWheelPreferences.self, from: data) {
            preferences = value
        } else {
            preferences = .defaults
        }
    }

    func reset() {
        preferences = .defaults
        syncLaunchAtLogin()
    }

    func refreshRunningApplications() {
        let ownID = Bundle.main.bundleIdentifier
        let byID = NSWorkspace.shared.runningApplications.reduce(into: [String: String]()) { result, app in
            guard app.activationPolicy == .regular,
                  let id = app.bundleIdentifier, id != ownID else { return }
            result[id] = app.localizedName ?? id
        }
        runningApplications = byID.map { RunningApplicationOption(name: $0.value, bundleID: $0.key) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func syncLaunchAtLogin() {
        do {
            if preferences.launchAtLogin {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            preferences.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.preferencesKey)
    }
}
