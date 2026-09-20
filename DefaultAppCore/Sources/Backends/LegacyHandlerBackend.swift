import AppKit
import CoreServices

protocol LegacyHandlerAPI: Sendable {
    func handlers(forContentType identifier: String, roles: LSRolesMask) async -> [String]
    func defaultHandler(forContentType identifier: String, roles: LSRolesMask) async -> String?
    func setDefaultHandler(_ bundleIdentifier: String, forContentType identifier: String, roles: LSRolesMask) async -> OSStatus
    func handlers(forURLScheme scheme: String) async -> [String]
    func defaultHandler(forURLScheme scheme: String) async -> String?
    func setDefaultHandler(_ bundleIdentifier: String, forURLScheme scheme: String) async -> OSStatus
}

public struct LegacyHandlerBackend: HandlerBackend {
    private let api: any LegacyHandlerAPI
    private let resolver: @Sendable (String) async -> URL?

    public init() {
        api = SystemLegacyHandlerAPI()
        resolver = { identifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        }
    }

    init(api: any LegacyHandlerAPI, resolver: @escaping @Sendable (String) async -> URL?) {
        self.api = api
        self.resolver = resolver
    }

    public func applications(for association: Association, role: HandlerRole) async throws -> [ApplicationReference] {
        try validate(association, role: role)
        let identifiers: [String]
        switch association.kind {
        case .contentType:
            identifiers = await api.handlers(forContentType: association.identifier, roles: Self.roles(role))
        case .urlScheme:
            identifiers = await api.handlers(forURLScheme: association.identifier)
        }
        var applications: [ApplicationReference] = []
        for identifier in identifiers {
            if let url = await resolver(identifier) {
                applications.append(ApplicationReference(url: url, bundleIdentifier: identifier))
            }
        }
        return applications
    }

    public func defaultApplication(for association: Association, role: HandlerRole) async throws -> ApplicationReference? {
        try validate(association, role: role)
        let identifier: String?
        switch association.kind {
        case .contentType:
            identifier = await api.defaultHandler(forContentType: association.identifier, roles: Self.roles(role))
        case .urlScheme:
            identifier = await api.defaultHandler(forURLScheme: association.identifier)
        }
        guard let identifier, let url = await resolver(identifier) else { return nil }
        return ApplicationReference(url: url, bundleIdentifier: identifier)
    }

    public func setDefaultApplication(_ application: ApplicationReference, for association: Association, role: HandlerRole) async throws {
        try validate(association, role: role)
        guard let identifier = application.bundleIdentifier, !identifier.isEmpty else {
            throw DefaultAppError.missingBundleIdentifier(url: application.url)
        }
        let status: OSStatus
        let operation: String
        switch association.kind {
        case .contentType:
            operation = "LSSetDefaultRoleHandlerForContentType"
            status = await api.setDefaultHandler(identifier, forContentType: association.identifier, roles: Self.roles(role))
        case .urlScheme:
            operation = "LSSetDefaultHandlerForURLScheme"
            status = await api.setDefaultHandler(identifier, forURLScheme: association.identifier)
        }
        guard status == noErr else {
            throw DefaultAppError.legacyFailure(operation: operation, status: status)
        }
    }

    private func validate(_ association: Association, role: HandlerRole) throws {
        if association.kind == .urlScheme && role != .all {
            throw DefaultAppError.unsupportedRole(backend: .legacy, associationKind: .urlScheme)
        }
    }

    private static func roles(_ role: HandlerRole) -> LSRolesMask {
        // HandlerRole.all is a semantic union (14); kLSRolesAll is UInt32.max.
        role == .all ? .all : LSRolesMask(rawValue: role.rawValue)
    }
}

private struct SystemLegacyHandlerAPI: LegacyHandlerAPI {
    func handlers(forContentType identifier: String, roles: LSRolesMask) async -> [String] {
        LSCopyAllRoleHandlersForContentType(identifier as CFString, roles)?.takeRetainedValue() as? [String] ?? []
    }

    func defaultHandler(forContentType identifier: String, roles: LSRolesMask) async -> String? {
        LSCopyDefaultRoleHandlerForContentType(identifier as CFString, roles)?.takeRetainedValue() as String?
    }

    func setDefaultHandler(_ bundleIdentifier: String, forContentType identifier: String, roles: LSRolesMask) async -> OSStatus {
        LSSetDefaultRoleHandlerForContentType(identifier as CFString, roles, bundleIdentifier as CFString)
    }

    func handlers(forURLScheme scheme: String) async -> [String] {
        LSCopyAllHandlersForURLScheme(scheme as CFString)?.takeRetainedValue() as? [String] ?? []
    }

    func defaultHandler(forURLScheme scheme: String) async -> String? {
        LSCopyDefaultHandlerForURLScheme(scheme as CFString)?.takeRetainedValue() as String?
    }

    func setDefaultHandler(_ bundleIdentifier: String, forURLScheme scheme: String) async -> OSStatus {
        LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleIdentifier as CFString)
    }
}
