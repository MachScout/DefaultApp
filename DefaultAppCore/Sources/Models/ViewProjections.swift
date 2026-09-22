import Foundation

/// A missing or failed lookup must not be presented as an absent system default.
public enum DefaultHandlerState: Hashable, Sendable {
    case notLoaded
    case application(ApplicationRecord)
    case none
    case failed(String)

    public var application: ApplicationRecord? {
        if case .application(let record) = self { return record }
        return nil
    }

    public var label: String {
        switch self {
        case .notLoaded: "Loading…"
        case .application(let record): record.displayName
        case .none: "No default application"
        case .failed: "Lookup unavailable"
        }
    }

    public var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

public struct AssociationRow: Identifiable, Hashable, Sendable {
    public let association: Association
    public let description: String?
    public let defaultHandler: DefaultHandlerState
    public var filenameExtensions: [String] = []
    public var isDynamic = false
    public var id: Association { association }
    public var identifier: String { association.identifier }
    public var filenameExtensionsSortValue: String { filenameExtensions.joined(separator: ", ") }
    public var defaultApplicationSortValue: String { defaultHandler.label }
}

public struct ContentTypeFilters: Hashable, Sendable {
    public var hideWithoutExtensions: Bool
    public var hideWithoutDefaultApplication: Bool
    public var onlyDynamic: Bool

    public init(hideWithoutExtensions: Bool = false,
                hideWithoutDefaultApplication: Bool = false,
                onlyDynamic: Bool = false) {
        self.hideWithoutExtensions = hideWithoutExtensions
        self.hideWithoutDefaultApplication = hideWithoutDefaultApplication
        self.onlyDynamic = onlyDynamic
    }
}

public enum AssociationSortColumn: String, Sendable {
    case identifier
    case filenameExtensions
    case defaultApplication
}

public struct AssociationSort: Equatable, Sendable {
    public var column: AssociationSortColumn
    public var ascending: Bool

    public init(column: AssociationSortColumn = .identifier, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}

/// Immutable identifier/tag work is prepared once per catalog revision. Only default
/// states and search filtering are evaluated when a batch of handler results arrives.
public struct AssociationListIndex: Sendable {
    private struct Entry: Sendable {
        let row: AssociationRow
        let searchTerms: [String]
    }
    private let entries: [Entry]

    public init(snapshot: CatalogSnapshot, kind: Association.Kind, includeNonFileTypes: Bool = true) {
        switch kind {
        case .urlScheme:
            entries = snapshot.urlSchemes.compactMap { record in
                guard let association = try? Association.urlScheme(record.identifier) else { return nil }
                return Entry(row: AssociationRow(association: association, description: nil, defaultHandler: .notLoaded),
                             searchTerms: [record.identifier])
            }
        case .contentType:
            entries = snapshot.contentTypes.compactMap { record in
                guard includeNonFileTypes || record.isFileType != false else { return nil }
                guard let association = try? Association.contentType(record.identifier) else { return nil }
                let extensions = Set(record.tags["public.filename-extension"] ?? []).sorted()
                return Entry(row: AssociationRow(association: association, description: record.localizedDescription,
                                                 defaultHandler: .notLoaded, filenameExtensions: extensions,
                                                 isDynamic: record.isDynamic == true),
                             searchTerms: [record.identifier, record.localizedDescription ?? ""]
                                + extensions.map { "." + $0 } + record.tags.values.flatMap { $0 } + record.supertypes)
            }
        }
    }

    public func rows(defaults: [Association: DefaultHandlerState], search: String,
                     filters: ContentTypeFilters = .init(),
                     sort: AssociationSort = .init()) -> [AssociationRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = entries.compactMap { entry -> AssociationRow? in
            let state = defaults[entry.row.association] ?? .notLoaded
            if filters.hideWithoutExtensions && entry.row.filenameExtensions.isEmpty { return nil }
            if filters.onlyDynamic && !entry.row.isDynamic { return nil }
            if filters.hideWithoutDefaultApplication && state.application == nil { return nil }
            if !query.isEmpty {
                let matchesMetadata = entry.searchTerms.contains { $0.localizedStandardContains(query) }
                let application = state.application
                let matchesDefault = application?.displayName.localizedStandardContains(query) == true
                    || application?.bundleIdentifier?.localizedStandardContains(query) == true
                guard matchesMetadata || matchesDefault else { return nil }
            }
            return AssociationRow(association: entry.row.association, description: entry.row.description,
                                  defaultHandler: state, filenameExtensions: entry.row.filenameExtensions,
                                  isDynamic: entry.row.isDynamic)
        }
        return rows.sorted { left, right in
            let comparison: ComparisonResult
            switch sort.column {
            case .identifier:
                comparison = left.identifier.localizedStandardCompare(right.identifier)
            case .filenameExtensions:
                comparison = left.filenameExtensionsSortValue.localizedStandardCompare(right.filenameExtensionsSortValue)
            case .defaultApplication:
                comparison = left.defaultApplicationSortValue.localizedStandardCompare(right.defaultApplicationSortValue)
            }
            if comparison == .orderedSame {
                let tieBreak = left.identifier.localizedStandardCompare(right.identifier)
                return sort.ascending ? tieBreak == .orderedAscending : tieBreak == .orderedDescending
            }
            return sort.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }
}

public enum AssociationProjection {
    public static func schemeRows(
        from snapshot: CatalogSnapshot,
        defaults: [Association: DefaultHandlerState] = [:],
        search: String
    ) -> [AssociationRow] {
        AssociationListIndex(snapshot: snapshot, kind: .urlScheme).rows(defaults: defaults, search: search)
    }

    public static func typeRows(
        from snapshot: CatalogSnapshot,
        defaults: [Association: DefaultHandlerState] = [:],
        search: String
    ) -> [AssociationRow] {
        AssociationListIndex(snapshot: snapshot, kind: .contentType).rows(defaults: defaults, search: search)
    }

    public static func showsRoles(for association: Association, backend: Backend) -> Bool {
        association.kind == .contentType && backend == .legacy
    }
}

private func matches(_ search: String, values: [String]) -> Bool {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty || values.contains { $0.localizedStandardContains(query) }
}

public struct HandledTypeProjection: Identifiable, Hashable, Sendable {
    public let identifier: String
    public let role: HandlerRole
    public let filenameExtensions: [String]
    public var id: String { identifier }

    public var filenameExtensionLabel: String? {
        ApplicationProjection.filenameExtensionLabel(for: filenameExtensions)
    }
}

public struct ApplicationProjection: Sendable {
    public let handledTypes: [HandledTypeProjection]
    public let exportedTypes: [ContentTypeDeclaration]
    public let importedTypes: [ContentTypeDeclaration]
    private let filenameExtensionsByIdentifier: [String: [String]]

    public init(record: ApplicationRecord, contentTypes: [ContentTypeRecord] = []) {
        var roles: [String: HandlerRole] = [:]
        var filenameExtensions: [String: Set<String>] = [:]
        for claim in record.documentTypeClaims {
            for identifier in claim.contentTypeIdentifiers {
                roles[identifier, default: []].formUnion(claim.role)
                filenameExtensions[identifier, default: []].formUnion(claim.filenameExtensions)
            }
        }

        for declaration in record.exportedTypeDeclarations + record.importedTypeDeclarations {
            filenameExtensions[declaration.identifier, default: []].formUnion(
                declaration.tags["public.filename-extension"] ?? []
            )
        }
        for contentType in contentTypes {
            filenameExtensions[contentType.identifier, default: []].formUnion(
                contentType.tags["public.filename-extension"] ?? []
            )
        }

        let resolvedFilenameExtensions = filenameExtensions.mapValues { values in
            Set(values.map { $0.lowercased() }).sorted()
        }
        filenameExtensionsByIdentifier = resolvedFilenameExtensions
        handledTypes = roles.keys.sorted().map {
            HandledTypeProjection(identifier: $0, role: roles[$0] ?? [],
                                  filenameExtensions: resolvedFilenameExtensions[$0, default: []])
        }
        exportedTypes = record.exportedTypeDeclarations
        importedTypes = record.importedTypeDeclarations
    }

    public func filenameExtensionLabel(for identifier: String) -> String? {
        Self.filenameExtensionLabel(for: filenameExtensionsByIdentifier[identifier.lowercased(), default: []])
    }

    fileprivate static func filenameExtensionLabel(for extensions: [String]) -> String? {
        guard !extensions.isEmpty else { return nil }
        return extensions.map { $0 == "*" ? $0 : "." + $0 }.joined(separator: ", ")
    }

    public static func records(from snapshot: CatalogSnapshot, search: String,
                               filters: ApplicationFilters = .init()) -> [ApplicationRecord] {
        snapshot.applications.filter {
            ApplicationVisibility(record: $0).isVisible(using: filters)
                && matches(search, values: [$0.displayName, $0.bundleIdentifier ?? "", $0.url.path])
        }
    }
}

public extension HandlerRole {
    var displayName: String {
        if self == .all { return "All" }
        if isEmpty { return "None" }
        return [(Self.viewer, "Viewer"), (.editor, "Editor"), (.shell, "Shell")]
            .compactMap { contains($0.0) ? $0.1 : nil }.joined(separator: ", ")
    }
}

public struct DiagnosticRow: Identifiable, Hashable, Sendable {
    public let label: String
    public let value: String
    public var id: String { label }
}

public struct DiagnosticsProjection: Sendable {
    public let rows: [DiagnosticRow]
    public let symbols: [String]
    public let warnings: [String]
    public let text: String

    public init(snapshot: CatalogSnapshot?, backend: Backend, osVersion: String, refreshDuration: TimeInterval?) {
        let diagnostics = snapshot?.diagnostics
        func status(_ value: Int32?) -> String {
            guard let value else { return "Not reported" }
            return value == 0 ? "Success (0)" : "Failed (\(value))"
        }
        rows = [
            DiagnosticRow(label: "Operating system", value: osVersion),
            DiagnosticRow(label: "Active backend", value: backend == .modern ? "Modern" : "Legacy"),
            DiagnosticRow(label: "Catalog", value: snapshot == nil ? "Not loaded" : "Loaded"),
            DiagnosticRow(label: "Refresh duration", value: refreshDuration.map { String(format: "%.2f s", $0) } ?? "Not recorded"),
            DiagnosticRow(label: "Application SPI status", value: status(diagnostics?.applicationCallStatus)),
            DiagnosticRow(label: "Scheme SPI status", value: status(diagnostics?.schemeCallStatus)),
            DiagnosticRow(label: "Content type SPI status", value: status(diagnostics?.contentTypeCallStatus)),
            DiagnosticRow(label: "SPI applications returned", value: diagnostics.map { String($0.applicationCount) } ?? "Not reported"),
            DiagnosticRow(label: "SPI schemes returned", value: diagnostics.map { String($0.schemeCount) } ?? "Not reported"),
            DiagnosticRow(label: "SPI content types returned", value: diagnostics.map { String($0.contentTypeCount) } ?? "Not reported"),
            DiagnosticRow(label: "Catalog applications", value: snapshot.map { String($0.applications.count) } ?? "Not loaded"),
            DiagnosticRow(label: "Catalog URL schemes", value: snapshot.map { String($0.urlSchemes.count) } ?? "Not loaded"),
            DiagnosticRow(label: "Catalog content types", value: snapshot.map { String($0.contentTypes.count) } ?? "Not loaded"),
        ]
        symbols = diagnostics?.expectedSymbolNames ?? []
        warnings = diagnostics?.warnings ?? []
        text = (["DefaultApp diagnostics"] + rows.map { "\($0.label): \($0.value)" }
                + ["", "Private symbols:"] + symbols
                + ["", "Warnings:"] + (warnings.isEmpty ? ["None reported"] : warnings))
            .joined(separator: "\n")
    }
}
