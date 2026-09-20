import Foundation

/// Shared asynchronous entry point for catalog discovery and handler operations.
public actor HandlerService {
    private struct WaitingOperation {
        let id: UInt
        let exclusive: Bool
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let applicationCatalog: any ApplicationCatalogProviding
    private let modernBackend: any HandlerBackend
    private let legacyBackend: any HandlerBackend
    private var writerActive = false
    private var activeReaders = 0
    private var applicationIndex: [String: ApplicationRecord]?
    private var indexedApplications: [ApplicationRecord] = []
    private var nextWaitingOperationID: UInt = 0
    private var waitingOperations: [WaitingOperation] = []

    var waitingOperationCountForTesting: Int { waitingOperations.count }

    public init(
        catalog: any ApplicationCatalogProviding = ApplicationCatalog(),
        modernBackend: any HandlerBackend = ModernHandlerBackend(),
        legacyBackend: any HandlerBackend = LegacyHandlerBackend()
    ) {
        applicationCatalog = catalog
        self.modernBackend = modernBackend
        self.legacyBackend = legacyBackend
    }

    public func catalog(forceRefresh: Bool = false) async throws -> CatalogSnapshot {
        try await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        let snapshot = try await applicationCatalog.loadCatalog(forceRefresh: forceRefresh)
        index(snapshot)
        return snapshot
    }

    public func applications(
        capableOf handling: Association,
        backend: Backend = .modern,
        role: HandlerRole = .all
    ) async throws -> [ApplicationRecord] {
        try await acquireOperation(exclusive: false)
        defer { releaseOperation(exclusive: false) }
        try Task.checkCancellation()
        let references = try await selectedBackend(backend).applications(for: handling, role: role)
        guard !references.isEmpty else { return [] }
        var records: [String: ApplicationRecord] = [:]
        for reference in references {
            let record = resolve(reference)
            records[record.id] = records[record.id] ?? record
        }
        return records.values.sorted {
            let comparison = $0.displayName.localizedStandardCompare($1.displayName)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    public func defaultApplication(
        for association: Association,
        backend: Backend = .modern,
        role: HandlerRole = .all
    ) async throws -> ApplicationRecord? {
        try await acquireOperation(exclusive: false)
        defer { releaseOperation(exclusive: false) }
        try Task.checkCancellation()
        guard let reference = try await selectedBackend(backend).defaultApplication(for: association, role: role) else {
            return nil
        }
        return resolve(reference)
    }

    public func setDefaultApplication(
        _ application: ApplicationReference,
        for association: Association,
        backend: Backend = .modern,
        role: HandlerRole = .all
    ) async throws {
        try await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        let selected = selectedBackend(backend)
        try await selected.setDefaultApplication(application, for: association, role: role)
        let observed = try await selected.defaultApplication(for: association, role: role)
        guard let observed, matches(application, observed) else {
            throw DefaultAppError.changeNotObserved(requested: application, observed: observed)
        }
        // Changing a default does not change installed bundle declarations.
    }

    public func refreshApplication(at url: URL) async throws -> CatalogSnapshot {
        try await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        let snapshot = try await applicationCatalog.refreshApplication(at: url)
        index(snapshot)
        return snapshot
    }

    public func refreshContentType(_ identifier: String) async throws -> CatalogSnapshot {
        try await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        let snapshot = try await applicationCatalog.refreshContentType(identifier)
        index(snapshot)
        return snapshot
    }

    private func index(_ snapshot: CatalogSnapshot) {
        guard applicationIndex == nil || indexedApplications != snapshot.applications else { return }
        indexedApplications = snapshot.applications
        applicationIndex = Dictionary(snapshot.applications.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func selectedBackend(_ backend: Backend) -> any HandlerBackend {
        switch backend {
        case .modern: modernBackend
        case .legacy: legacyBackend
        }
    }

    private func resolve(_ reference: ApplicationReference) -> ApplicationRecord {
        // Catalog identity is the installation URL: a bundle ID may occur at several paths.
        applicationIndex?[reference.id] ?? ApplicationRecord(
            url: reference.url,
            bundleIdentifier: reference.bundleIdentifier,
            displayName: reference.url.deletingPathExtension().lastPathComponent
        )
    }

    private func matches(_ requested: ApplicationReference, _ observed: ApplicationReference) -> Bool {
        if requested.url.isFileURL, observed.url.isFileURL, requested.id == observed.id { return true }
        guard let identifier = requested.bundleIdentifier, !identifier.isEmpty else { return false }
        return identifier == observed.bundleIdentifier
    }

    private func acquireOperation(exclusive: Bool = true) async throws {
        try Task.checkCancellation()
        if !writerActive, waitingOperations.isEmpty, exclusive ? activeReaders == 0 : activeReaders < 4 {
            if exclusive { writerActive = true } else { activeReaders += 1 }
            return
        }

        nextWaitingOperationID &+= 1
        let id = nextWaitingOperationID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waitingOperations.append(WaitingOperation(id: id, exclusive: exclusive, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaitingOperation(id) }
        }
    }

    private func cancelWaitingOperation(_ id: UInt) {
        guard let index = waitingOperations.firstIndex(where: { $0.id == id }) else { return }
        let waiting = waitingOperations.remove(at: index)
        waiting.continuation.resume(throwing: CancellationError())
        resumeWaitingOperations()
    }

    private func releaseOperation(exclusive: Bool = true) {
        if exclusive { writerActive = false } else { activeReaders -= 1 }
        resumeWaitingOperations()
    }

    private func resumeWaitingOperations() {
        // FIFO writer barrier: concurrent reads never overlap a setter + verification,
        // and a steady stream of reads cannot starve a queued mutation.
        guard !writerActive else { return }
        while let next = waitingOperations.first {
            if next.exclusive {
                guard activeReaders == 0 else { return }
                writerActive = true
                waitingOperations.removeFirst().continuation.resume()
                return
            }
            guard activeReaders < 4 else { return }
            activeReaders += 1
            waitingOperations.removeFirst().continuation.resume()
        }
    }
}
