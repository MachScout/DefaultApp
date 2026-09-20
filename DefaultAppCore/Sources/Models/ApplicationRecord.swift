import Foundation

/// Canonical identity for an installation, independent of Foundation's directory hint.
/// The models retain their original standardized URLs for display and system calls.
func canonicalApplicationURLIdentity(_ url: URL) -> String {
    guard url.isFileURL else { return url.absoluteString }
    return URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: false).absoluteString
}

public struct ApplicationReference: Hashable, Codable, Identifiable, Sendable {
    public let url: URL
    public let bundleIdentifier: String?

    public var id: String {
        canonicalApplicationURLIdentity(url)
    }

    public init(url: URL, bundleIdentifier: String? = nil) {
        self.url = url.standardizedFileURL
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct URLSchemeDeclaration: Hashable, Codable, Identifiable, Sendable {
    public let scheme: String
    public let name: String?
    public let role: HandlerRole

    public var id: String { scheme }

    public init(scheme: String, name: String? = nil, role: HandlerRole = .all) {
        self.scheme = scheme
        self.name = name
        self.role = role
    }
}

public struct DocumentTypeClaim: Hashable, Codable, Identifiable, Sendable {
    public let name: String?
    public let contentTypeIdentifiers: [String]
    public let filenameExtensions: [String]
    public let mimeTypes: [String]
    public let rank: String?
    public let role: HandlerRole

    public var id: String {
        ([name ?? ""] + contentTypeIdentifiers + filenameExtensions + mimeTypes).joined(separator: "|")
    }

    public init(
        name: String? = nil,
        contentTypeIdentifiers: [String] = [],
        filenameExtensions: [String] = [],
        mimeTypes: [String] = [],
        rank: String? = nil,
        role: HandlerRole = []
    ) {
        self.name = name
        self.contentTypeIdentifiers = contentTypeIdentifiers
        self.filenameExtensions = filenameExtensions
        self.mimeTypes = mimeTypes
        self.rank = rank
        self.role = role
    }
}

public enum ContentTypeDeclarationProvenance: String, Codable, Sendable {
    case imported
    case exported
}

public struct ContentTypeDeclaration: Hashable, Codable, Identifiable, Sendable {
    public let identifier: String
    public let provenance: ContentTypeDeclarationProvenance
    public let typeDescription: String?
    public let tags: [String: [String]]
    public let conformanceIdentifiers: [String]
    public let declaringBundleIdentifier: String?

    public var id: String { identifier }

    public init(
        identifier: String,
        provenance: ContentTypeDeclarationProvenance,
        typeDescription: String? = nil,
        tags: [String: [String]] = [:],
        conformanceIdentifiers: [String] = [],
        declaringBundleIdentifier: String? = nil
    ) {
        self.identifier = identifier
        self.provenance = provenance
        self.typeDescription = typeDescription
        self.tags = tags
        self.conformanceIdentifiers = conformanceIdentifiers
        self.declaringBundleIdentifier = declaringBundleIdentifier
    }
}

public struct ApplicationRecord: Hashable, Codable, Identifiable, Sendable {
    public let url: URL
    public let bundleIdentifier: String?
    public let displayName: String
    public let bundleVersion: String?
    public let shortVersion: String?
    public let urlSchemes: [URLSchemeDeclaration]
    public let documentTypeClaims: [DocumentTypeClaim]
    public let exportedTypeDeclarations: [ContentTypeDeclaration]
    public let importedTypeDeclarations: [ContentTypeDeclaration]
    public let warnings: [String]

    public var id: String {
        canonicalApplicationURLIdentity(url)
    }

    public var reference: ApplicationReference {
        ApplicationReference(url: url, bundleIdentifier: bundleIdentifier)
    }

    public init(
        url: URL,
        bundleIdentifier: String? = nil,
        displayName: String,
        bundleVersion: String? = nil,
        shortVersion: String? = nil,
        urlSchemes: [URLSchemeDeclaration] = [],
        documentTypeClaims: [DocumentTypeClaim] = [],
        exportedTypeDeclarations: [ContentTypeDeclaration] = [],
        importedTypeDeclarations: [ContentTypeDeclaration] = [],
        warnings: [String] = []
    ) {
        self.url = url.standardizedFileURL
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.bundleVersion = bundleVersion
        self.shortVersion = shortVersion
        self.urlSchemes = urlSchemes
        self.documentTypeClaims = documentTypeClaims
        self.exportedTypeDeclarations = exportedTypeDeclarations
        self.importedTypeDeclarations = importedTypeDeclarations
        self.warnings = warnings
    }
}
