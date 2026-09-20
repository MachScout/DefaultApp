import Foundation

public enum DefaultAppError: Error, Equatable, Sendable {
    case malformedAssociationIdentifier(kind: Association.Kind, value: String)
    case unknownContentType(identifier: String)
    case unreadableBundleMetadata(url: URL)
    case malformedBundleMetadata(url: URL, reason: String)
    case missingBundleIdentifier(url: URL)
    case applicationNotRegistered(ApplicationReference)
    case applicationNotCapable(application: ApplicationReference, association: Association)
    case unsupportedRole(backend: Backend, associationKind: Association.Kind)
    case privateSPIFailure(symbol: String, status: Int32)
    case malformedSPIPayload(symbol: String)
    case modernFailure(operation: String, description: String)
    case legacyFailure(operation: String, status: Int32)
    case changeRejected(description: String)
    case changeNotObserved(requested: ApplicationReference, observed: ApplicationReference?)
}

extension DefaultAppError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .malformedAssociationIdentifier(kind, value):
            "Malformed \(kind.description) identifier: \(value)"
        case let .unknownContentType(identifier):
            "Unknown content type: \(identifier)"
        case let .unreadableBundleMetadata(url):
            "Could not read bundle metadata at \(url.path)."
        case let .malformedBundleMetadata(url, reason):
            "Malformed bundle metadata at \(url.path): \(reason)"
        case let .missingBundleIdentifier(url):
            "The application at \(url.path) has no bundle identifier."
        case let .applicationNotRegistered(application):
            "The application at \(application.url.path) is not registered."
        case let .applicationNotCapable(application, association):
            "The application at \(application.url.path) cannot handle \(association.identifier)."
        case let .unsupportedRole(backend, associationKind):
            "The selected role is unsupported by the \(backend.rawValue) backend for \(associationKind.description)."
        case let .privateSPIFailure(symbol, status):
            "Private LaunchServices call \(symbol) failed with status \(status)."
        case let .malformedSPIPayload(symbol):
            "Private LaunchServices call \(symbol) returned a malformed payload."
        case let .modernFailure(operation, description):
            "Modern handler operation \(operation) failed: \(description)"
        case let .legacyFailure(operation, status):
            "Legacy handler operation \(operation) failed with status \(status)."
        case let .changeRejected(description):
            "The handler change was rejected: \(description)"
        case let .changeNotObserved(requested, observed):
            "Requested handler \(requested.id), but observed \(observed?.id ?? "no default handler")."
        }
    }
}

private extension Association.Kind {
    var description: String {
        switch self {
        case .urlScheme:
            "URL scheme"
        case .contentType:
            "content type"
        }
    }
}
