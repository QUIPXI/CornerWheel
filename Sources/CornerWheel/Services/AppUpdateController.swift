import AppKit
import Combine
import Foundation
import Sparkle

/// An unconfigured development build must never contact a placeholder server.
struct UpdateConfiguration {
    let feedURL: URL
    let publicKey: String

    init?(infoDictionary: [String: Any]) {
        guard let feed = infoDictionary["SUFeedURL"] as? String,
              let components = URLComponents(string: feed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil,
              !feed.contains("$("),
              let url = components.url,
              let key = infoDictionary["SUPublicEDKey"] as? String,
              let keyData = Data(base64Encoded: key), keyData.count == 32,
              keyData.contains(where: { $0 != 0 }) else { return nil }
        feedURL = url
        publicKey = key
    }
}

@MainActor
final class AppUpdateController: NSObject, ObservableObject, @preconcurrency SPUStandardUserDriverDelegate {
    @Published private(set) var isAvailable = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?
    @Published private(set) var pendingUpdateVersion: String?
    @Published private(set) var unavailableMessage = "Updates aren’t available in this build."

    private let configuration: UpdateConfiguration?
    private var controller: SPUStandardUpdaterController?
    private var subscriptions: Set<AnyCancellable> = []
    private var didAttemptStart = false

    init(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        configuration = UpdateConfiguration(infoDictionary: infoDictionary)
        super.init()
    }

    func start() {
        guard !didAttemptStart else { return }
        didAttemptStart = true
        guard configuration != nil else { return }

        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                     updaterDelegate: nil,
                                                     userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        // Keep system-profile reporting off even if an older preference enabled it.
        updater.sendsSystemProfile = false
        do {
            try updater.start()
            isAvailable = true
        } catch {
            unavailableMessage = "Updates couldn’t start. Please restart CornerWheel and try again."
            self.controller = nil
            return
        }

        // Sparkle owns persistence, scheduling, and changes made in its own UI.
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.automaticallyDownloadsUpdates = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastUpdateCheckDate = $0 }
            .store(in: &subscriptions)
    }

    func checkForUpdates() {
        guard isAvailable, canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isAvailable else { return }
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard isAvailable else { return }
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Background checks surface in the menu bar without interrupting work.
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if !state.userInitiated { pendingUpdateVersion = update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingUpdateVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingUpdateVersion = nil
    }
}
