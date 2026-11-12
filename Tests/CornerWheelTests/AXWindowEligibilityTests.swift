import ApplicationServices
import Combine
import XCTest
@testable import CornerWheel

final class AXWindowEligibilityTests: XCTestCase {
    func testFinderDesktopIsExcludedWhileDocumentAndDialogWindowsRemainEligible() {
        XCTAssertFalse(AXWindowEligibility.includes(bundleIdentifier: "com.apple.finder",
                                                role: "AXScrollArea", subrole: nil))
        XCTAssertFalse(AXWindowEligibility.includes(bundleIdentifier: "com.apple.finder",
                                                role: "AXWindow", subrole: nil))
        XCTAssertFalse(AXWindowEligibility.includes(bundleIdentifier: "com.apple.finder",
                                                role: "AXWindow", subrole: "AXFloatingWindow"))
        XCTAssertTrue(AXWindowEligibility.includes(bundleIdentifier: "com.apple.finder",
                                               role: "AXWindow", subrole: "AXStandardWindow"))
        XCTAssertTrue(AXWindowEligibility.includes(bundleIdentifier: "com.apple.finder",
                                               role: "AXWindow", subrole: "AXDialog"))
    }

    func testOtherApplicationsCanExposeNormalWindowsWithoutSubrole() {
        XCTAssertTrue(AXWindowEligibility.includes(bundleIdentifier: "com.example.editor",
                                               role: "AXWindow", subrole: nil))
    }

    private func validAttributeValues() -> [Any] {
        var point = CGPoint(x: 25, y: 30)
        var size = CGSize(width: 600, height: 400)
        return ["AXWindow", "AXStandardWindow", AXValueCreate(.cgPoint, &point)!,
                AXValueCreate(.cgSize, &size)!, true, "Document"]
    }

    func testBatchedAttributesKeepErrorPositionsAndOptionalDefaults() throws {
        var values = validAttributeValues()
        var error = AXError.attributeUnsupported
        let unsupported = try XCTUnwrap(AXValueCreate(.axError, &error))
        values[1] = unsupported
        values[4] = kCFNull!
        values[5] = unsupported
        let decoded = try XCTUnwrap(AXWindowAttributeValues(values: values))
        XCTAssertEqual(decoded.role, "AXWindow")
        XCTAssertNil(decoded.subrole)
        XCTAssertEqual(decoded.bounds, CGRect(x: 25, y: 30, width: 600, height: 400))
        XCTAssertFalse(decoded.isMinimized)
        XCTAssertEqual(decoded.title, "")
        XCTAssertTrue(AXWindowEligibility.includes(bundleIdentifier: "example.editor",
                                                  role: decoded.role, subrole: decoded.subrole))
        values[2] = unsupported
        XCTAssertNil(AXWindowAttributeValues(values: values)?.bounds)
        XCTAssertNil(AXWindowAttributeValues(values: Array(values.dropLast())))
    }

    func testBatchSuccessUsesOneCallAndLegacyProviderFallsBackToIndividualReads() throws {
        let values = validAttributeValues()
        var individualCalls = 0
        let individual: (CFString) -> CFTypeRef? = { name in
            individualCalls += 1
            let index = AXWindowAttributeValues.names.firstIndex { CFEqual($0, name) }!
            return values[index] as CFTypeRef
        }
        let batch = try XCTUnwrap(AXWindowAttributeValues.read(batch: { (.success, values) },
                                                              individual: individual))
        XCTAssertEqual(individualCalls, 0)
        XCTAssertEqual(batch.title, "Document")
        for error in [AXError.notImplemented, .cannotComplete] {
            individualCalls = 0
            let legacy = try XCTUnwrap(AXWindowAttributeValues.read(batch: { (error, nil) },
                                                                   individual: individual))
            XCTAssertEqual(individualCalls, 6)
            XCTAssertEqual(legacy.bounds, batch.bounds)
            XCTAssertEqual(legacy.isMinimized, batch.isMinimized)
            XCTAssertEqual(legacy.title, batch.title)
        }
    }

    func testDestroyedWindowDoesNotTriggerFallbackMessages() {
        var individualCalls = 0
        let decoded = AXWindowAttributeValues.read(batch: { (.invalidUIElement, nil) }, individual: { _ in
            individualCalls += 1
            return nil
        })
        XCTAssertNil(decoded)
        XCTAssertEqual(individualCalls, 0)
    }

    func testCancelledScanIsDistinctFromAnEmptyWindowCatalog() async {
        let store = AccessibilityWindowStore()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.scan([], includeMinimized: false)
        }
        let discarded = await cancelled.value
        XCTAssertNil(discarded)
        let empty = await store.scan([], includeMinimized: false)
        XCTAssertEqual(empty?.count, 0)
    }

    func testAXIdentityLookupMatchesEquivalentWrappersAndSeparatesProcesses() {
        let original = AXElementIdentity(element: AXUIElementCreateApplication(123))
        let equivalent = AXElementIdentity(element: AXUIElementCreateApplication(123))
        let different = AXElementIdentity(element: AXUIElementCreateApplication(124))
        let id = UUID()
        let index = [original: id]
        XCTAssertEqual(index[equivalent], id)
        XCTAssertNil(index[different])
        XCTAssertEqual(Set([original, equivalent, different]).count, 2)
    }

    func testWindowActionsRejectAnUnretainedWindow() async {
        let store = AccessibilityWindowStore()
        let token = UUID()
        let minimized = await store.setMinimized(true, token: token, processID: 123)
        let closed = await store.closeWindow(token, processID: 123)
        XCTAssertEqual(minimized, .failure("The selected window is no longer available"))
        XCTAssertEqual(closed, .failure("The selected window is no longer available"))
    }

    func testAcceptedMinimizationDoesNotRequireAnImmediateStateUpdate() async {
        let store = AccessibilityWindowStore()
        for delayedState: Bool? in [false, nil] {
            let result = await store.completeMinimizationRequest(true, error: .success, readState: {
                delayedState
            }, waitForState: {
                XCTFail("An accepted request should not wait for the animation")
            })
            XCTAssertEqual(result, .success)
        }
    }

    func testTimedOutMinimizationCanFinishAfterTheRequestReturns() async {
        let store = AccessibilityWindowStore()
        for desiredState in [true, false] {
            var reads = 0
            var waits = 0
            let result = await store.completeMinimizationRequest(desiredState, error: .cannotComplete,
                                                                readState: {
                reads += 1
                // Providers can briefly fail a read, then expose the old
                // state before finally publishing the requested state.
                if reads == 1 { return nil }
                return reads < 4 ? !desiredState : desiredState
            }, waitForState: { waits += 1 })
            XCTAssertEqual(result, .success)
            XCTAssertEqual(reads, 4)
            XCTAssertEqual(waits, 3)
        }
    }

    func testRejectedMinimizationStillReportsFailureWithoutWaiting() async {
        let store = AccessibilityWindowStore()
        let result = await store.completeMinimizationRequest(true, error: .attributeUnsupported, readState: {
            XCTFail("A rejected request does not need state verification")
            return false
        }, waitForState: { XCTFail("A rejected request should fail immediately") })
        XCTAssertEqual(result, .failure("Could not minimize this window"))
    }

    func testUnconfirmedMinimizationStopsRetryingAndReportsUncertainty() async {
        let store = AccessibilityWindowStore()
        var reads = 0
        var waits = 0
        let result = await store.completeMinimizationRequest(true, error: .cannotComplete, readState: {
            reads += 1
            return false
        }, waitForState: { waits += 1 })
        XCTAssertEqual(result, .failure("Could not confirm that this window was minimized"))
        XCTAssertEqual(reads, 6)
        XCTAssertEqual(waits, 5)
    }
}

@MainActor
final class WindowCatalogOptimizationTests: XCTestCase {
    func testWindowActionsRejectStaleCatalogIdentityBeforeContactingAnApplication() async {
        let catalog = WindowCatalog()
        let service = WindowActivationService(catalog: catalog)
        let id = UUID()
        func record(pid: pid_t) -> WindowRecord {
            WindowRecord(id: id, processID: pid, bundleIdentifier: "example.editor",
                         applicationName: "Editor", title: "Same title", bounds: .zero,
                         isMinimized: false, isHidden: false)
        }
        catalog.publishWindows([record(pid: 124)])
        for action: WindowContextAction in [.show, .minimize, .restore, .close] {
            let result = await service.perform(action, on: record(pid: 123))
            XCTAssertEqual(result, .failure("The selected window is no longer available"))
        }
        catalog.publishWindows([])
        let result = await service.perform(.close, on: record(pid: 124))
        XCTAssertEqual(result, .failure("The selected window is no longer available"))
    }

    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func open() { continuation?.resume(); continuation = nil }
    }

    func testRefreshBurstRunsOneWorkerAndOneMergedFollowup() async {
        let scheduler = WindowCatalogRefreshScheduler()
        let gate = Gate()
        let started = expectation(description: "First refresh started")
        let requested = expectation(description: "Burst requested")
        requested.expectedFulfillmentCount = 20
        var calls = 0
        var active = 0
        var maximumActive = 0
        var published = 0
        let operation: (Int) async -> Void = { generation in
            calls += 1
            active += 1
            maximumActive = max(maximumActive, active)
            if calls == 1 {
                started.fulfill()
                await gate.wait()
            }
            if scheduler.isCurrent(generation) { published += 1 }
            active -= 1
        }
        let first = Task { await scheduler.refresh(operation: operation) }
        await fulfillment(of: [started], timeout: 2)
        let burst = (0..<20).map { _ in
            Task {
                requested.fulfill()
                await scheduler.refresh(operation: operation)
            }
        }
        await fulfillment(of: [requested], timeout: 2)
        gate.open()
        await first.value
        for task in burst { await task.value }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(maximumActive, 1)
        XCTAssertEqual(published, 1, "A superseded scan must not publish stale metadata")
    }

    func testInvalidationAndRestartWaitForOldWorkerAndUseLatestConfiguration() async {
        let scheduler = WindowCatalogRefreshScheduler()
        let gate = Gate()
        let started = expectation(description: "First refresh started")
        let restarted = expectation(description: "Restart requested")
        var configuration = "old exclusions and minimized setting"
        var scans: [String] = []
        var publications: [String] = []
        let operation: (Int) async -> Void = { generation in
            let capturedConfiguration = configuration
            scans.append(capturedConfiguration)
            if scans.count == 1 {
                started.fulfill()
                await gate.wait()
            }
            if scheduler.isCurrent(generation), !Task.isCancelled {
                publications.append(capturedConfiguration)
            }
        }
        let first = Task { await scheduler.refresh(operation: operation) }
        await fulfillment(of: [started], timeout: 2)
        scheduler.invalidate()
        configuration = "new exclusions and minimized setting"
        let second = Task {
            restarted.fulfill()
            await scheduler.refresh(operation: operation)
        }
        await fulfillment(of: [restarted], timeout: 2)
        gate.open()
        await first.value
        await second.value
        XCTAssertEqual(scans, ["old exclusions and minimized setting", "new exclusions and minimized setting"])
        XCTAssertEqual(publications, ["new exclusions and minimized setting"])
    }

    func testInvalidationWithoutRestartDiscardsPendingWork() async {
        let scheduler = WindowCatalogRefreshScheduler()
        let gate = Gate()
        let started = expectation(description: "Refresh started")
        var publicationCount = 0
        let task = Task {
            await scheduler.refresh { generation in
                started.fulfill()
                await gate.wait()
                if scheduler.isCurrent(generation) { publicationCount += 1 }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        scheduler.invalidate()
        gate.open()
        await task.value
        XCTAssertEqual(publicationCount, 0)
    }

    func testCancellingOneWaiterDoesNotCancelSharedRefresh() async {
        let scheduler = WindowCatalogRefreshScheduler()
        let gate = Gate()
        let started = expectation(description: "Refresh started")
        var workerWasCancelled = false
        let task = Task {
            await scheduler.refresh { _ in
                started.fulfill()
                await gate.wait()
                workerWasCancelled = Task.isCancelled
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        gate.open()
        await task.value
        XCTAssertFalse(workerWasCancelled)
    }

    func testCatalogSuppressesUnchangedMetadataButPublishesTitleAndGeometryChanges() {
        let catalog = WindowCatalog()
        let id = UUID()
        func record(title: String = "Document", x: CGFloat = 10, minimized: Bool = false) -> WindowRecord {
            WindowRecord(id: id, processID: 123, bundleIdentifier: "example.editor",
                         applicationName: "Editor", title: title,
                         bounds: CGRect(x: x, y: 10, width: 500, height: 400),
                         isMinimized: minimized, isHidden: false)
        }
        var publications = 0
        let subscription = catalog.$windows.dropFirst().sink { _ in publications += 1 }
        catalog.publishWindows([record()])
        catalog.publishWindows([record()])
        XCTAssertEqual(publications, 1)
        catalog.publishWindows([record(title: "Renamed")])
        XCTAssertEqual(catalog.record(for: id)?.title, "Renamed")
        catalog.publishWindows([record(title: "Renamed", x: 20)])
        catalog.publishWindows([record(title: "Renamed", x: 20, minimized: true)])
        XCTAssertEqual(publications, 4)
        XCTAssertTrue(catalog.record(for: id)?.isMinimized == true)
        catalog.publishWindows([])
        XCTAssertNil(catalog.record(for: id))
        XCTAssertEqual(publications, 5)
        withExtendedLifetime(subscription) {}
    }
}
