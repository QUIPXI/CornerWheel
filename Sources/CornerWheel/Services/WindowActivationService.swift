import AppKit

/// Uses the retained AX reference for the selected *window*, then verifies the
/// focused AX window. An app-wide activation alone is never reported as success.
@MainActor
final class WindowActivationService {
    private let catalog: WindowCatalog

    init(catalog: WindowCatalog) { self.catalog = catalog }

    func perform(_ action: WindowContextAction, on record: WindowRecord) async -> ActivationResult {
        if action == .show || action == .restore { return await activate(record) }
        guard let current = catalog.record(for: record.id), current.processID == record.processID else {
            return .failure("The selected window is no longer available")
        }
        guard let app = NSRunningApplication(processIdentifier: record.processID), !app.isTerminated else {
            return .failure("The application has quit")
        }
        switch action {
        case .minimize:
            return await catalog.axStore.setMinimized(true, token: record.id, processID: record.processID)
        case .close:
            return await catalog.axStore.closeWindow(record.id, processID: record.processID)
        case .show, .restore:
            return await activate(record)
        }
    }

    func activate(_ record: WindowRecord) async -> ActivationResult {
        guard let current = catalog.record(for: record.id),
              current.processID == record.processID else {
            return .failure("The selected window is no longer available")
        }
        guard let app = NSRunningApplication(processIdentifier: record.processID),
              !app.isTerminated else {
            return .failure("The application has quit")
        }
        guard await catalog.axStore.contains(record.id, processID: record.processID) else {
            return .failure("The selected window has closed or stopped responding")
        }
        let shouldRestore = await catalog.axStore.isMinimized(record.id,
                                                             processID: record.processID) ?? current.isMinimized

        if app.isHidden { app.unhide() }
        _ = await catalog.axStore.restoreAndRaise(record.id, processID: record.processID,
                                                  restore: shouldRestore)
        guard app.activate(options: []) else {
            return .failure("macOS did not activate \(current.applicationName)")
        }
        _ = await catalog.axStore.restoreAndRaise(record.id, processID: record.processID,
                                                  restore: shouldRestore)

        if await catalog.axStore.focusedToken(processID: record.processID) == record.id {
            return .success
        }
        // One short verification retry accommodates normal focus delivery.
        try? await Task.sleep(for: .milliseconds(100))
        _ = await catalog.axStore.restoreAndRaise(record.id, processID: record.processID,
                                                  restore: shouldRestore)
        if await catalog.axStore.focusedToken(processID: record.processID) == record.id {
            return .success
        }
        return .failure("Could not verify that \(current.displayTitle) became the focused window")
    }
}
