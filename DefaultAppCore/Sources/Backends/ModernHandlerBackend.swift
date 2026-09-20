import AppKit
import UniformTypeIdentifiers

enum ModernHandlerTarget: Sendable {
    case url(URL)
    case contentType(UTType)
}

protocol ModernWorkspaceProviding: Sendable {
    func applications(for target: ModernHandlerTarget) async -> [URL]
    func defaultApplication(for target: ModernHandlerTarget) async -> URL?
    func setDefaultApplication(at url: URL, for target: ModernHandlerTarget) async throws
}

public struct ModernHandlerBackend: HandlerBackend {
    private let workspace: any ModernWorkspaceProviding

    public init() {
        workspace = SystemModernWorkspace()
    }

    init(workspace: any ModernWorkspaceProviding) {
        self.workspace = workspace
    }

    public func applications(for association: Association, role: HandlerRole) async throws -> [ApplicationReference] {
        let target = try target(for: association, role: role)
        return await workspace.applications(for: target).map(Self.reference)
    }

    public func defaultApplication(for association: Association, role: HandlerRole) async throws -> ApplicationReference? {
        let target = try target(for: association, role: role)
        return await workspace.defaultApplication(for: target).map(Self.reference)
    }

    public func setDefaultApplication(_ application: ApplicationReference, for association: Association, role: HandlerRole) async throws {
        let target = try target(for: association, role: role)
        do {
            try await workspace.setDefaultApplication(at: application.url, for: target)
        } catch {
            throw DefaultAppError.modernFailure(operation: "setDefaultApplication", description: error.localizedDescription)
        }
    }

    private func target(for association: Association, role: HandlerRole) throws -> ModernHandlerTarget {
        guard role == .all else {
            throw DefaultAppError.unsupportedRole(backend: .modern, associationKind: association.kind)
        }
        switch association.kind {
        case .urlScheme:
            guard let url = URL(string: association.identifier + ":") else {
                throw DefaultAppError.malformedAssociationIdentifier(kind: .urlScheme, value: association.identifier)
            }
            return .url(url)
        case .contentType:
            guard let type = UTType(association.identifier) else {
                throw DefaultAppError.unknownContentType(identifier: association.identifier)
            }
            return .contentType(type)
        }
    }

    private static func reference(_ url: URL) -> ApplicationReference {
        ApplicationReference(url: url, bundleIdentifier: Bundle(url: url)?.bundleIdentifier)
    }
}

private struct SystemModernWorkspace: ModernWorkspaceProviding {
    // Read-only workspace queries run on the generic executor, not the UI actor.
    func applications(for target: ModernHandlerTarget) async -> [URL] {
        switch target {
        case .url(let url): NSWorkspace.shared.urlsForApplications(toOpen: url)
        case .contentType(let type): NSWorkspace.shared.urlsForApplications(toOpen: type)
        }
    }

    func defaultApplication(for target: ModernHandlerTarget) async -> URL? {
        switch target {
        case .url(let url): NSWorkspace.shared.urlForApplication(toOpen: url)
        case .contentType(let type): NSWorkspace.shared.urlForApplication(toOpen: type)
        }
    }

    @MainActor
    func setDefaultApplication(at url: URL, for target: ModernHandlerTarget) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let completion: @Sendable (Error?) -> Void = { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            switch target {
            case .url(let targetURL):
                // The target is constructed only from a validated URL scheme.
                NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: targetURL.scheme!, completion: completion)
            case .contentType(let type):
                NSWorkspace.shared.setDefaultApplication(at: url, toOpen: type, completion: completion)
            }
        }
    }
}
