import XCTest
@testable import DefaultAppCore

// XCTest owns the instance; fixtures are immutable Sendable values and every mutable fake is an actor.
final class HandlerServiceTests: XCTestCase, @unchecked Sendable {
    private let safari = ApplicationRecord(
        url: URL(fileURLWithPath: "/Applications/Safari.app"),
        bundleIdentifier: "com.apple.Safari", displayName: "Safari", shortVersion: "26"
    )
    private let firefox = ApplicationRecord(
        url: URL(fileURLWithPath: "/Applications/Firefox.app"),
        bundleIdentifier: "org.mozilla.firefox", displayName: "Firefox", shortVersion: "140"
    )

    // Wrong backend selection or dropped role/association must change the result or recorded boundary call.
    func testSelectedBackendReceivesLookupAndRole() async throws {
        let modern = ServiceBackend(defaultValue: safari.reference)
        let legacy = ServiceBackend(defaultValue: firefox.reference)
        let service = HandlerService(catalog: ServiceCatalog(), modernBackend: modern, legacyBackend: legacy)
        let association = try Association.contentType("public.text")
        let result = try await service.defaultApplication(for: association, backend: .legacy, role: .editor)
        XCTAssertEqual(result?.bundleIdentifier, "org.mozilla.firefox")
        let modernCalls = await modern.calls
        let legacyCalls = await legacy.calls
        XCTAssertEqual(modernCalls, [])
        XCTAssertEqual(legacyCalls, [.lookup(association, .editor)])
    }

    func testDefaultArgumentsUseModernAllAndEnrichByURL() async throws {
        let modern = ServiceBackend(defaultValue: ApplicationReference(url: firefox.url))
        let service = HandlerService(catalog: ServiceCatalog(applications: [firefox]), modernBackend: modern, legacyBackend: ServiceBackend())
        let association = try Association.urlScheme("http")
        _ = try await service.catalog()
        let result = try await service.defaultApplication(for: association)
        XCTAssertEqual(result, firefox)
        let calls = await modern.calls
        XCTAssertEqual(calls, [.lookup(association, .all)])
    }

    func testCapableApplicationsRouteDeduplicateAndSortWhilePreservingDistinctInstallations() async throws {
        let otherFirefox = ApplicationReference(url: URL(fileURLWithPath: "/Other/Firefox.app"), bundleIdentifier: firefox.bundleIdentifier)
        let legacy = ServiceBackend(applications: [safari.reference, otherFirefox, firefox.reference, safari.reference])
        let modern = ServiceBackend()
        let service = HandlerService(catalog: ServiceCatalog(applications: [safari, firefox]), modernBackend: modern, legacyBackend: legacy)
        let association = try Association.contentType("public.text")
        _ = try await service.catalog()
        let result = try await service.applications(capableOf: association, backend: .legacy, role: .viewer)
        XCTAssertEqual(result.map(\.url.path), ["/Applications/Firefox.app", "/Other/Firefox.app", "/Applications/Safari.app"])
        XCTAssertEqual(result[0], firefox)
        XCTAssertNil(result[1].shortVersion)
        let calls = await legacy.calls
        let modernCalls = await modern.calls
        XCTAssertEqual(calls, [.applications(association, .viewer)])
        XCTAssertEqual(modernCalls, [])
    }

    func testModernCapableLookupUsesDefaultRole() async throws {
        let modern = ServiceBackend(applications: [firefox.reference])
        let service = HandlerService(catalog: ServiceCatalog(), modernBackend: modern, legacyBackend: ServiceBackend())
        let association = try Association.urlScheme("mailto")
        let result = try await service.applications(capableOf: association)
        XCTAssertEqual(result.map(\.bundleIdentifier), ["org.mozilla.firefox"])
        let calls = await modern.calls
        XCTAssertEqual(calls, [.applications(association, .all)])
    }

    func testOutOfCatalogDefaultKeepsIdentityAsMinimalRecord() async throws {
        let service = HandlerService(catalog: ServiceCatalog(), modernBackend: ServiceBackend(defaultValue: firefox.reference), legacyBackend: ServiceBackend())
        let result = try await service.defaultApplication(for: .urlScheme("http"))
        XCTAssertEqual(result?.reference, firefox.reference)
        XCTAssertEqual(result?.displayName, "Firefox")
        XCTAssertEqual(result?.urlSchemes, [])
        XCTAssertNil(result?.shortVersion)
    }

    func testDirectoryURLSpellingStillEnrichesAndDeduplicates() async throws {
        let record = ApplicationRecord(url: URL(fileURLWithPath: "/Fixture/Reader.app", isDirectory: true),
                                       bundleIdentifier: "test.reader", displayName: "A Reader", shortVersion: "1")
        let alternate = ApplicationReference(url: URL(fileURLWithPath: "/Fixture/Reader.app", isDirectory: false))
        let backend = ServiceBackend(applications: [alternate, record.reference], defaultValue: alternate)
        let service = HandlerService(catalog: ServiceCatalog(applications: [record]), modernBackend: backend, legacyBackend: ServiceBackend())
        _ = try await service.catalog()
        let result = try await service.defaultApplication(for: .urlScheme("http"))
        let applications = try await service.applications(capableOf: .urlScheme("http"))
        XCTAssertEqual(result, record)
        XCTAssertEqual(applications, [record])
    }

    // A held setter makes actor reentrancy observable: no other service operation may enter a dependency.
    func testPendingMutationSerializesOtherMutationsAndCatalogReads() async throws {
        let entered = expectation(description: "First setter suspended")
        let overlap = expectation(description: "No operation enters while the setter is pending")
        overlap.isInverted = true
        let suspension = ServiceSuspension(entered: entered, overlap: overlap)
        let catalog = ServiceCatalog(suspension: suspension)
        let backend = ServiceBackend(defaultValue: firefox.reference, suspension: suspension)
        let service = HandlerService(catalog: catalog, modernBackend: backend, legacyBackend: backend)
        let application = firefox.reference
        let association = try Association.urlScheme("http")
        let first = Task { try await service.setDefaultApplication(application, for: association) }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task { try await service.setDefaultApplication(application, for: association, backend: .legacy) }
        let refresh = Task { try await service.catalog(forceRefresh: true) }
        let lookup = Task { try await service.defaultApplication(for: association) }
        let capable = Task { try await service.applications(capableOf: association) }
        await fulfillment(of: [overlap], timeout: 0.1)
        await suspension.release()
        try await first.value
        try await second.value
        _ = try await refresh.value
        _ = try await lookup.value
        _ = try await capable.value
        let count = await catalog.invalidationCount
        XCTAssertEqual(count, 0)
    }

    func testIndependentReadsOverlapWhileOneBackendReadIsSuspended() async throws {
        let entered = expectation(description: "Applications read suspended")
        let secondEntered = expectation(description: "Default read enters concurrently")
        let backend = ConcurrentReadBackend(entered: entered, secondEntered: secondEntered)
        let service = HandlerService(catalog: ServiceCatalog(), modernBackend: backend)
        let first = Task { try await service.applications(capableOf: .urlScheme("http")) }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task { try await service.defaultApplication(for: .urlScheme("mailto")) }
        await fulfillment(of: [secondEntered], timeout: 2)
        await backend.release()
        _ = try await first.value
        _ = try await second.value
    }

    func testServiceBoundsConcurrentDefaultReads() async throws {
        let entered = expectation(description: "Four reads entered")
        let backend = BoundedReadBackend(entered: entered)
        let service = HandlerService(catalog: ServiceCatalog(), modernBackend: backend)
        let reads = (0..<12).map { index in Task { try await service.defaultApplication(for: .contentType("test.type-\(index)")) } }
        await fulfillment(of: [entered], timeout: 2)
        let beforeRelease = await backend.activeCount
        XCTAssertEqual(beforeRelease, 4)
        await backend.release()
        for read in reads { _ = try await read.value }
        let peak = await backend.peakCount
        XCTAssertEqual(peak, 4)
    }

    func testAlreadyCancelledMutationNeverCallsBackend() async throws {
        let backend = ServiceBackend(defaultValue: firefox.reference)
        let catalog = ServiceCatalog()
        let service = HandlerService(catalog: catalog, modernBackend: backend, legacyBackend: ServiceBackend())
        let application = firefox.reference
        let association = try Association.urlScheme("http")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await service.setDefaultApplication(application, for: association)
        }
        await XCTAssertThrowsErrorAsync({ try await task.value }) { XCTAssertTrue($0 is CancellationError) }
        let calls = await backend.calls
        let count = await catalog.invalidationCount
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(count, 0)
        // A failed/cancelled operation must also release the service for later work.
        _ = try await service.catalog()
    }

    func testCancelledQueuedOperationFinishesBeforeActiveMutation() async throws {
        let entered = expectation(description: "Setter suspended")
        let overlap = expectation(description: "No dependency overlap")
        overlap.isInverted = true
        let cancelled = expectation(description: "Queued operation cancelled")
        let suspension = ServiceSuspension(entered: entered, overlap: overlap)
        let catalog = ServiceCatalog(suspension: suspension)
        let backend = ServiceBackend(defaultValue: firefox.reference, suspension: suspension)
        let service = HandlerService(catalog: catalog, modernBackend: backend, legacyBackend: backend)
        let first = Task {
            try await service.setDefaultApplication(firefox.reference, for: .urlScheme("http"))
        }
        await fulfillment(of: [entered], timeout: 2)

        let queued = Task {
            do {
                _ = try await service.catalog()
                XCTFail("Cancelled queued operation unexpectedly succeeded")
            } catch is CancellationError {
                // Expected: cancellation removes the waiter without waiting for the active mutation.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            cancelled.fulfill()
        }
        while await service.waitingOperationCountForTesting == 0 {
            await Task.yield()
        }
        queued.cancel()

        await fulfillment(of: [cancelled], timeout: 2)
        await fulfillment(of: [overlap], timeout: 0.1)
        let refreshes = await catalog.refreshes
        XCTAssertTrue(refreshes.isEmpty)
        await suspension.release()
        await queued.value
        try await first.value
    }

    func testEmptyBackendResultsDoNotRequireCatalogDiscovery() async throws {
        let catalog = ServiceCatalog(failure: .privateSPIFailure(symbol: "fixture", status: -1))
        let service = HandlerService(catalog: catalog, modernBackend: ServiceBackend(), legacyBackend: ServiceBackend())
        let result = try await service.defaultApplication(for: .urlScheme("http"))
        let applications = try await service.applications(capableOf: .urlScheme("http"))
        XCTAssertNil(result)
        XCTAssertTrue(applications.isEmpty)
        let refreshes = await catalog.refreshes
        XCTAssertEqual(refreshes, [])
    }

    func testQuickHandlerLookupsReturnMinimalRecordsBeforeCatalogDiscovery() async throws {
        let catalog = ServiceCatalog(failure: .privateSPIFailure(symbol: "fixture", status: -1))
        let backend = ServiceBackend(applications: [firefox.reference], defaultValue: firefox.reference)
        let service = HandlerService(catalog: catalog, modernBackend: backend, legacyBackend: ServiceBackend())

        let applications = try await service.applications(capableOf: .urlScheme("http"))
        let selected = try await service.defaultApplication(for: .urlScheme("http"))

        XCTAssertEqual(applications.map(\.reference), [firefox.reference])
        XCTAssertEqual(selected?.reference, firefox.reference)
        let refreshes = await catalog.refreshes
        XCTAssertEqual(refreshes, [])
    }

    func testCatalogForwardsRefreshAndDiscoveryFailures() async throws {
        let catalog = ServiceCatalog(applications: [firefox])
        let service = HandlerService(catalog: catalog, modernBackend: ServiceBackend(), legacyBackend: ServiceBackend())
        let initial = try await service.catalog()
        let refreshed = try await service.catalog(forceRefresh: true)
        XCTAssertEqual(initial.applications, [firefox])
        XCTAssertEqual(refreshed.applications, [firefox])
        let refreshes = await catalog.refreshes
        XCTAssertEqual(refreshes, [false, true])

        let error = DefaultAppError.privateSPIFailure(symbol: "fixture", status: -1)
        let failing = HandlerService(catalog: ServiceCatalog(failure: error), modernBackend: ServiceBackend(), legacyBackend: ServiceBackend())
        await XCTAssertThrowsErrorAsync({ try await failing.catalog() }) { XCTAssertEqual($0 as? DefaultAppError, error) }
    }

    // A reported setter success alone must never invalidate the catalog or become public success.
    func testUnobservedSetReportsBothIdentitiesWithoutInvalidation() async throws {
        let catalog = ServiceCatalog()
        let backend = ServiceBackend(defaultValue: safari.reference)
        let service = HandlerService(catalog: catalog, modernBackend: backend, legacyBackend: ServiceBackend())
        await XCTAssertThrowsErrorAsync({ try await service.setDefaultApplication(self.firefox.reference, for: .urlScheme("http")) }) {
            XCTAssertEqual($0 as? DefaultAppError, .changeNotObserved(requested: self.firefox.reference, observed: self.safari.reference))
        }
        let count = await catalog.invalidationCount
        XCTAssertEqual(count, 0)
    }

    func testNilObservedDefaultDoesNotMatchMissingBundleIdentifiers() async throws {
        let requested = ApplicationReference(url: firefox.url)
        let catalog = ServiceCatalog()
        let service = HandlerService(catalog: catalog, modernBackend: ServiceBackend(), legacyBackend: ServiceBackend())
        await XCTAssertThrowsErrorAsync({ try await service.setDefaultApplication(requested, for: .urlScheme("http")) }) {
            XCTAssertEqual($0 as? DefaultAppError, .changeNotObserved(requested: requested, observed: nil))
        }
        let count = await catalog.invalidationCount
        XCTAssertEqual(count, 0)
    }

    func testEmptyOrMissingIdentifiersCannotVerifyDifferentURLs() async throws {
        for identifier: String? in [nil, ""] {
            let requested = ApplicationReference(url: firefox.url, bundleIdentifier: identifier)
            let observed = ApplicationReference(url: safari.url, bundleIdentifier: identifier)
            let service = HandlerService(catalog: ServiceCatalog(), modernBackend: ServiceBackend(defaultValue: observed), legacyBackend: ServiceBackend())
            await XCTAssertThrowsErrorAsync({ try await service.setDefaultApplication(requested, for: .urlScheme("http")) }) {
                XCTAssertEqual($0 as? DefaultAppError, .changeNotObserved(requested: requested, observed: observed))
            }
        }
    }

    func testSuccessfulSetVerifiesSameBackendAssociationAndRoleWithoutInvalidatingCatalog() async throws {
        let catalog = ServiceCatalog()
        let modern = ServiceBackend(defaultValue: safari.reference)
        let legacy = ServiceBackend(defaultValue: firefox.reference, catalog: catalog)
        let service = HandlerService(catalog: catalog, modernBackend: modern, legacyBackend: legacy)
        let association = try Association.contentType("public.text")
        try await service.setDefaultApplication(firefox.reference, for: association, backend: .legacy, role: .editor)
        let calls = await legacy.calls
        let modernCalls = await modern.calls
        let beforeVerification = await legacy.invalidationsAtLookup
        let count = await catalog.invalidationCount
        XCTAssertEqual(calls, [.set(firefox.reference, association, .editor), .lookup(association, .editor)])
        XCTAssertEqual(modernCalls, [])
        XCTAssertEqual(beforeVerification, [0])
        XCTAssertEqual(count, 0)
    }

    func testVerificationMatchesStandardizedURLWithoutBundleIdentifier() async throws {
        let observed = ApplicationReference(url: URL(fileURLWithPath: "/Applications/Temporary/../Firefox.app"))
        let catalog = ServiceCatalog()
        let backend = ServiceBackend(defaultValue: observed)
        let service = HandlerService(catalog: catalog, modernBackend: backend, legacyBackend: ServiceBackend())
        try await service.setDefaultApplication(firefox.reference, for: .urlScheme("http"))
        let count = await catalog.invalidationCount
        XCTAssertEqual(count, 0)
    }

    func testVerificationMatchesNonemptyBundleIdentifierAtAnotherURL() async throws {
        let observed = ApplicationReference(url: URL(fileURLWithPath: "/Other/Firefox.app"), bundleIdentifier: firefox.bundleIdentifier)
        let catalog = ServiceCatalog()
        let service = HandlerService(catalog: catalog, modernBackend: ServiceBackend(defaultValue: observed), legacyBackend: ServiceBackend())
        try await service.setDefaultApplication(firefox.reference, for: .urlScheme("http"))
        let count = await catalog.invalidationCount
        XCTAssertEqual(count, 0)
    }

    func testSetterFailurePropagatesWithoutVerificationOrInvalidation() async throws {
        let error = DefaultAppError.changeRejected(description: "fixture rejection")
        let catalog = ServiceCatalog()
        let backend = ServiceBackend(defaultValue: firefox.reference, setFailure: error)
        let service = HandlerService(catalog: catalog, modernBackend: backend, legacyBackend: ServiceBackend())
        let association = try Association.urlScheme("http")
        await XCTAssertThrowsErrorAsync({ try await service.setDefaultApplication(self.firefox.reference, for: association) }) {
            XCTAssertEqual($0 as? DefaultAppError, error)
        }
        let calls = await backend.calls
        let count = await catalog.invalidationCount
        XCTAssertEqual(calls, [.set(firefox.reference, association, .all)])
        XCTAssertEqual(count, 0)
    }

    func testVerificationReadFailurePropagatesWithoutInvalidation() async throws {
        let error = DefaultAppError.legacyFailure(operation: "fixture read", status: -1)
        let catalog = ServiceCatalog()
        let backend = ServiceBackend(readFailure: error)
        let service = HandlerService(catalog: catalog, modernBackend: ServiceBackend(), legacyBackend: backend)
        await XCTAssertThrowsErrorAsync({ try await service.setDefaultApplication(self.firefox.reference, for: .urlScheme("http"), backend: .legacy) }) {
            XCTAssertEqual($0 as? DefaultAppError, error)
        }
        let count = await catalog.invalidationCount
        XCTAssertEqual(count, 0)
    }
}

private actor ServiceCatalog: ApplicationCatalogProviding {
    let snapshot: CatalogSnapshot
    let failure: DefaultAppError?
    let suspension: ServiceSuspension?
    private(set) var refreshes: [Bool] = []
    private(set) var invalidationCount = 0

    init(applications: [ApplicationRecord] = [], failure: DefaultAppError? = nil, suspension: ServiceSuspension? = nil) {
        snapshot = CatalogSnapshot(applications: applications)
        self.failure = failure
        self.suspension = suspension
    }

    func loadCatalog(forceRefresh: Bool) async throws -> CatalogSnapshot {
        await suspension?.noteOtherOperation()
        refreshes.append(forceRefresh)
        if let failure { throw failure }
        return snapshot
    }

    func invalidate() { invalidationCount += 1 }
}

private actor ServiceBackend: HandlerBackend {
    enum Call: Equatable {
        case applications(Association, HandlerRole)
        case lookup(Association, HandlerRole)
        case set(ApplicationReference, Association, HandlerRole)
    }
    let applicationValues: [ApplicationReference]
    let defaultValue: ApplicationReference?
    let setFailure: DefaultAppError?
    let readFailure: DefaultAppError?
    let catalog: ServiceCatalog?
    let suspension: ServiceSuspension?
    private(set) var calls: [Call] = []
    private(set) var invalidationsAtLookup: [Int] = []

    init(applications: [ApplicationReference] = [], defaultValue: ApplicationReference? = nil,
         setFailure: DefaultAppError? = nil, readFailure: DefaultAppError? = nil, catalog: ServiceCatalog? = nil,
         suspension: ServiceSuspension? = nil) {
        applicationValues = applications
        self.defaultValue = defaultValue
        self.setFailure = setFailure
        self.readFailure = readFailure
        self.catalog = catalog
        self.suspension = suspension
    }

    func applications(for association: Association, role: HandlerRole) async throws -> [ApplicationReference] {
        await suspension?.noteOtherOperation()
        calls.append(.applications(association, role))
        if let readFailure { throw readFailure }
        return applicationValues
    }

    func defaultApplication(for association: Association, role: HandlerRole) async throws -> ApplicationReference? {
        await suspension?.noteOtherOperation()
        calls.append(.lookup(association, role))
        if let catalog { invalidationsAtLookup.append(await catalog.invalidationCount) }
        if let readFailure { throw readFailure }
        return defaultValue
    }

    func setDefaultApplication(_ application: ApplicationReference, for association: Association, role: HandlerRole) async throws {
        calls.append(.set(application, association, role))
        await suspension?.pauseFirstSet()
        if let setFailure { throw setFailure }
    }
}

private actor ServiceSuspension {
    let entered: XCTestExpectation
    let overlap: XCTestExpectation
    private var hasPaused = false
    private var reportedOverlap = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(entered: XCTestExpectation, overlap: XCTestExpectation) {
        self.entered = entered
        self.overlap = overlap
    }

    func pauseFirstSet() async {
        if hasPaused {
            noteOtherOperation()
            return
        }
        hasPaused = true
        await withCheckedContinuation {
            continuation = $0
            entered.fulfill()
        }
    }

    func noteOtherOperation() {
        if continuation != nil, !reportedOverlap {
            reportedOverlap = true
            overlap.fulfill()
        }
    }

    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

private actor ConcurrentReadBackend: HandlerBackend {
    let entered: XCTestExpectation
    let secondEntered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation, secondEntered: XCTestExpectation) {
        self.entered = entered
        self.secondEntered = secondEntered
    }
    func applications(for association: Association, role: HandlerRole) async throws -> [ApplicationReference] {
        await withCheckedContinuation { continuation = $0; entered.fulfill() }
        return []
    }
    func defaultApplication(for association: Association, role: HandlerRole) async throws -> ApplicationReference? {
        secondEntered.fulfill()
        return nil
    }
    func setDefaultApplication(_ application: ApplicationReference, for association: Association, role: HandlerRole) async throws {}
    func release() { continuation?.resume(); continuation = nil }
}

private actor BoundedReadBackend: HandlerBackend {
    let entered: XCTestExpectation
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var activeCount = 0
    private(set) var peakCount = 0
    init(entered: XCTestExpectation) { self.entered = entered }
    func applications(for association: Association, role: HandlerRole) async throws -> [ApplicationReference] { [] }
    func defaultApplication(for association: Association, role: HandlerRole) async throws -> ApplicationReference? {
        activeCount += 1
        peakCount = max(peakCount, activeCount)
        if activeCount == 4 && !released { entered.fulfill() }
        if !released { await withCheckedContinuation { waiters.append($0) } }
        activeCount -= 1
        return nil
    }
    func setDefaultApplication(_ application: ApplicationReference, for association: Association, role: HandlerRole) async throws {}
    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
