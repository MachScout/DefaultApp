import Foundation

public struct URLSchemeRecord: Hashable, Codable, Identifiable, Sendable {
    public let identifier: String
    public let handlerApplications: [ApplicationReference]
    public let declaringApplications: [ApplicationReference]

    public var id: String { identifier }

    public init(
        identifier: String,
        handlerApplications: [ApplicationReference] = [],
        declaringApplications: [ApplicationReference] = []
    ) {
        self.identifier = identifier
        self.handlerApplications = handlerApplications
        self.declaringApplications = declaringApplications
    }
}

public struct ContentTypeRecord: Hashable, Codable, Identifiable, Sendable {
    public let identifier: String
    public let localizedDescription: String?
    public let tags: [String: [String]]
    public let supertypes: [String]
    public let declaringApplication: ApplicationReference?
    /// nil supports snapshots produced before filesystem classification was recorded.
    public let isFileType: Bool?
    /// True when macOS generated the identifier from a tag without a declaration.
    public let isDynamic: Bool?

    public var id: String { identifier }

    public init(
        identifier: String,
        localizedDescription: String? = nil,
        tags: [String: [String]] = [:],
        supertypes: [String] = [],
        declaringApplication: ApplicationReference? = nil,
        isFileType: Bool? = nil,
        isDynamic: Bool? = nil
    ) {
        self.identifier = identifier
        self.localizedDescription = localizedDescription
        self.tags = tags
        self.supertypes = supertypes
        self.declaringApplication = declaringApplication
        self.isFileType = isFileType
        self.isDynamic = isDynamic
    }
}

public struct SPIDiagnostics: Hashable, Codable, Sendable {
    public let applicationCallStatus: Int32?
    public let schemeCallStatus: Int32?
    public let contentTypeCallStatus: Int32?
    public let applicationCount: Int
    public let schemeCount: Int
    public let contentTypeCount: Int
    public let warnings: [String]
    public let expectedSymbolNames: [String]

    public init(
        applicationCallStatus: Int32? = nil,
        schemeCallStatus: Int32? = nil,
        contentTypeCallStatus: Int32? = nil,
        applicationCount: Int = 0,
        schemeCount: Int = 0,
        contentTypeCount: Int = 0,
        warnings: [String] = [],
        expectedSymbolNames: [String] = []
    ) {
        self.applicationCallStatus = applicationCallStatus
        self.schemeCallStatus = schemeCallStatus
        self.contentTypeCallStatus = contentTypeCallStatus
        self.applicationCount = applicationCount
        self.schemeCount = schemeCount
        self.contentTypeCount = contentTypeCount
        self.warnings = warnings
        self.expectedSymbolNames = expectedSymbolNames
    }
}

public struct CatalogSnapshot: Hashable, Codable, Sendable {
    public let applications: [ApplicationRecord]
    public let urlSchemes: [URLSchemeRecord]
    public let contentTypes: [ContentTypeRecord]
    public let diagnostics: SPIDiagnostics

    public init(
        applications: [ApplicationRecord] = [],
        urlSchemes: [URLSchemeRecord] = [],
        contentTypes: [ContentTypeRecord] = [],
        diagnostics: SPIDiagnostics = SPIDiagnostics()
    ) {
        self.applications = applications
        self.urlSchemes = urlSchemes
        self.contentTypes = contentTypes
        self.diagnostics = diagnostics
    }
}
