import AppKit
import Combine
import Foundation
import DefaultAppCore

@MainActor
protocol IncomingOpening {
    func applications(for url: URL) async throws -> [ApplicationRecord]
    func open(_ url: URL, with application: URL) async throws
}

@MainActor
struct SystemIncomingOpening: IncomingOpening {
    func applications(for url: URL) async throws -> [ApplicationRecord] {
        NSWorkspace.shared.urlsForApplications(toOpen: url).map { applicationURL in
            let bundle = Bundle(url: applicationURL)
            return ApplicationRecord(url: applicationURL, bundleIdentifier: bundle?.bundleIdentifier,
                displayName: bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? applicationURL.deletingPathExtension().lastPathComponent)
        }
    }

    func open(_ url: URL, with application: URL) async throws {
        // Always target the chosen installation; opening via the default would loop back to us.
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: application,
                                             configuration: NSWorkspace.OpenConfiguration())
    }
}

struct IncomingOpenRequest: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var displayValue: String { url.isFileURL ? url.path : url.absoluteString }
}

@MainActor
final class IncomingOpenStore: ObservableObject {
    @Published private(set) var requests: [IncomingOpenRequest] = []
    @Published private(set) var handlers: [ApplicationRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isOpening = false
    @Published private(set) var errorMessage: String?
    @Published var selectedHandlerID: String?

    var current: IncomingOpenRequest? { requests.first }
    var remainingCount: Int { max(0, requests.count - 1) }
    private(set) var pendingRequestCount = 0
    private let workspace: any IncomingOpening
    private let ownApplication: ApplicationReference
    private var lookupGeneration = 0

    init(workspace: any IncomingOpening = SystemIncomingOpening(),
         ownApplication: ApplicationReference = ApplicationReference(url: Bundle.main.bundleURL,
                                                                     bundleIdentifier: Bundle.main.bundleIdentifier)) {
        self.workspace = workspace
        self.ownApplication = ownApplication
    }

    func enqueue(_ urls: [URL]) {
        let newRequests = urls.map { IncomingOpenRequest(url: $0) }
        pendingRequestCount += newRequests.count
        requests.append(contentsOf: newRequests)
    }

    func loadHandlers() async {
        guard let request = current else { return }
        lookupGeneration += 1
        let generation = lookupGeneration
        isLoading = true
        handlers = []
        selectedHandlerID = nil
        errorMessage = nil
        defer { if lookupGeneration == generation { isLoading = false } }
        do {
            let candidates = try await workspace.applications(for: request.url)
            guard current?.id == request.id, lookupGeneration == generation, !Task.isCancelled else { return }
            var seen = Set<String>()
            handlers = candidates.filter { !isSelf($0.reference) && seen.insert($0.id).inserted }
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            selectedHandlerID = handlers.first?.id
        } catch is CancellationError {
            return
        } catch {
            guard current?.id == request.id, lookupGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func open(using application: ApplicationRecord) async {
        guard let request = current, !isOpening, !isSelf(application.reference),
              handlers.contains(where: { $0.id == application.id }) else { return }
        isOpening = true
        errorMessage = nil
        defer { isOpening = false }
        do {
            try await workspace.open(request.url, with: application.url)
            if current?.id == request.id { advance() }
        } catch {
            if current?.id == request.id { errorMessage = error.localizedDescription }
        }
    }

    func skip() {
        guard !isOpening else { return }
        advance()
    }

    func discardWaitingItems() {
        guard !requests.isEmpty else { return }
        pendingRequestCount = 1
        requests.removeSubrange(requests.index(after: requests.startIndex)..<requests.endIndex)
    }

    func discardAllItems() {
        lookupGeneration += 1
        pendingRequestCount = 0
        requests.removeAll()
        resetPresentationState()
    }

    func copyCurrent() {
        guard let current else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(current.displayValue, forType: .string)
    }

    func revealCurrent() {
        guard let url = current?.url, url.isFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func advance() {
        guard !requests.isEmpty else { return }
        lookupGeneration += 1
        pendingRequestCount -= 1
        requests.removeFirst()
        resetPresentationState()
    }

    private func resetPresentationState() {
        handlers = []
        selectedHandlerID = nil
        errorMessage = nil
        isLoading = false
    }

    private func isSelf(_ application: ApplicationReference) -> Bool {
        application.url.resolvingSymlinksInPath().standardizedFileURL == ownApplication.url.resolvingSymlinksInPath().standardizedFileURL
            || (ownApplication.bundleIdentifier != nil && application.bundleIdentifier == ownApplication.bundleIdentifier)
    }
}
