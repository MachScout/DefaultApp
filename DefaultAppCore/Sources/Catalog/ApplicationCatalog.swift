import Foundation
import UniformTypeIdentifiers

public protocol ApplicationCatalogProviding: Sendable {
    func loadCatalog(forceRefresh: Bool) async throws -> CatalogSnapshot
    func invalidate() async
    func refreshApplication(at url: URL) async throws -> CatalogSnapshot
    func refreshContentType(_ identifier: String) async throws -> CatalogSnapshot
}

public extension ApplicationCatalogProviding {
    func refreshApplication(at url: URL) async throws -> CatalogSnapshot { try await loadCatalog() }
    func refreshContentType(_ identifier: String) async throws -> CatalogSnapshot { try await loadCatalog() }

    func loadCatalog() async throws -> CatalogSnapshot {
        try await loadCatalog(forceRefresh: false)
    }
}

public actor ApplicationCatalog: ApplicationCatalogProviding {
    private let spi: any PrivateLaunchServicesProviding
    private let dynamicTypeDiscovery: any DynamicTypeDiscovering
    private let parser: BundleDeclarationParser
    private let infoDictionary: @Sendable (URL) throws -> [String: Any]
    private var cachedSnapshot: CatalogSnapshot?
    private struct Fingerprint: Equatable {
        let modified: Date
        let created: Date
        let size: UInt64
        let inode: UInt64
    }
    private var bundleCache: [String: (Fingerprint, ApplicationRecord)] = [:]
    private var discovery: (applications: [URL], schemes: [(scheme: String, handlerURL: URL)], types: [String], dynamicTypes: [DynamicTypePreference], warning: String?)?

    public init(
        spi: any PrivateLaunchServicesProviding = SilgenLaunchServicesSPI(),
        dynamicTypeDiscovery: any DynamicTypeDiscovering = DynamicTypeDiscovery(),
        parser: BundleDeclarationParser = BundleDeclarationParser(),
        infoDictionary: @escaping @Sendable (URL) throws -> [String: Any] = { url in
            let plistURL = url.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plistURL) else {
                throw DefaultAppError.unreadableBundleMetadata(url: url)
            }
            guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw DefaultAppError.malformedBundleMetadata(url: url, reason: "Info.plist is not a dictionary.")
            }
            return dictionary
        }
    ) {
        self.spi = spi
        self.dynamicTypeDiscovery = dynamicTypeDiscovery
        self.parser = parser
        self.infoDictionary = infoDictionary
    }

    public func invalidate() {
        cachedSnapshot = nil
        bundleCache.removeAll()
        discovery = nil
    }

    public func loadCatalog(forceRefresh: Bool = false) async throws -> CatalogSnapshot {
        if !forceRefresh, let cachedSnapshot { return cachedSnapshot }

        // No suspension during construction: refresh and invalidation cannot publish out of order.
        // This actor is independent of MainActor, including synchronous bundle reads.
        let rawApplications = try spi.applicationURLs()
        let rawSchemes = try spi.schemesAndHandlerURLs()
        let rawTypes = try spi.declaredTypeIdentifiers()
        let dynamicTypes: [DynamicTypePreference]
        let dynamicWarning: String?
        do {
            dynamicTypes = try dynamicTypeDiscovery.discover()
            dynamicWarning = nil
        } catch {
            dynamicTypes = []
            dynamicWarning = "Dynamic type preferences could not be read: \(error.localizedDescription)"
        }
        var urlsByIdentity: [String: URL] = [:]
        for url in rawApplications + rawSchemes.map(\.handlerURL) {
            let identity = canonicalApplicationURLIdentity(url)
            urlsByIdentity[identity] = urlsByIdentity[identity] ?? url.standardizedFileURL
        }
        let applications = urlsByIdentity.values.map { readApplication(at: $0) }.sorted(by: Self.applicationOrder)
        try Task.checkCancellation()
        let snapshot = try buildSnapshot(applications: applications, rawApplications: rawApplications,
                                         rawSchemes: rawSchemes, rawTypes: rawTypes,
                                         dynamicTypes: dynamicTypes, dynamicWarning: dynamicWarning)
        discovery = (rawApplications, rawSchemes, rawTypes, dynamicTypes, dynamicWarning)
        bundleCache = bundleCache.filter { urlsByIdentity[$0.key] != nil }
        return snapshot
    }

    public func refreshApplication(at url: URL) async throws -> CatalogSnapshot {
        guard let snapshot = cachedSnapshot, let discovery else { return try await loadCatalog() }
        try Task.checkCancellation()
        let id = canonicalApplicationURLIdentity(url)
        guard let old = snapshot.applications.first(where: { $0.id == id }) else { return snapshot }
        let updated = readApplication(at: url)
        guard old != updated else { return snapshot }
        let applications = snapshot.applications.map { $0.id == id ? updated : $0 }.sorted(by: Self.applicationOrder)
        let changedTypes = Set((old.exportedTypeDeclarations + old.importedTypeDeclarations
                               + updated.exportedTypeDeclarations + updated.importedTypeDeclarations).map(\.identifier)
                              + (old.documentTypeClaims + updated.documentTypeClaims).flatMap(\.contentTypeIdentifiers))
        return try buildSnapshot(applications: applications, rawApplications: discovery.applications,
                             rawSchemes: discovery.schemes, rawTypes: discovery.types,
                             dynamicTypes: discovery.dynamicTypes, dynamicWarning: discovery.warning,
                             refreshedTypes: changedTypes)
    }

    public func refreshContentType(_ identifier: String) async throws -> CatalogSnapshot {
        guard let snapshot = cachedSnapshot, let discovery else { return try await loadCatalog() }
        try Task.checkCancellation()
        if let url = snapshot.contentTypes.first(where: { $0.identifier == identifier })?.declaringApplication?.url {
            _ = try await refreshApplication(at: url)
        }
        return try buildSnapshot(applications: cachedSnapshot?.applications ?? snapshot.applications,
                             rawApplications: discovery.applications, rawSchemes: discovery.schemes,
                             rawTypes: discovery.types, dynamicTypes: discovery.dynamicTypes,
                             dynamicWarning: discovery.warning, refreshedTypes: [identifier])
    }

    private func readApplication(at url: URL) -> ApplicationRecord {
        let id = canonicalApplicationURLIdentity(url)
        let fingerprint = fingerprint(at: url)
        if let fingerprint, let cached = bundleCache[id], cached.0 == fingerprint { return cached.1 }
        do {
            let record = try parser.parse(applicationURL: url, infoDictionary: infoDictionary(url))
            // Do not cache failures or a file that changed while it was being read.
            if let fingerprint, fingerprint == self.fingerprint(at: url) {
                bundleCache[id] = (fingerprint, record)
            } else { bundleCache[id] = nil }
            return record
        } catch {
            bundleCache[id] = nil
            return ApplicationRecord(url: url, displayName: url.deletingPathExtension().lastPathComponent,
                                     warnings: [error.localizedDescription])
        }
    }

    private func fingerprint(at url: URL) -> Fingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("Contents/Info.plist").path),
              let modified = attributes[.modificationDate] as? Date,
              let created = attributes[.creationDate] as? Date,
              let size = attributes[.size] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return Fingerprint(modified: modified, created: created, size: size.uint64Value, inode: inode.uint64Value)
    }

    private static func applicationOrder(_ lhs: ApplicationRecord, _ rhs: ApplicationRecord) -> Bool {
        if lhs.displayName != rhs.displayName { return ordered(lhs.displayName, rhs.displayName) }
        return lhs.id < rhs.id
    }

    private func buildSnapshot(applications: [ApplicationRecord], rawApplications: [URL],
                               rawSchemes: [(scheme: String, handlerURL: URL)], rawTypes: [String],
                               dynamicTypes: [DynamicTypePreference], dynamicWarning: String?,
                               refreshedTypes: Set<String>? = nil) throws -> CatalogSnapshot {
        var warnings: [String] = []
        if let dynamicWarning { warnings.append(dynamicWarning) }
        for application in applications {
            warnings.append(contentsOf: application.warnings.map { "\(application.url.path): \($0)" })
        }
        let references = Dictionary(uniqueKeysWithValues: applications.map { ($0.id, $0.reference) })
        var handlers: [String: Set<ApplicationReference>] = [:]
        var declarers: [String: Set<ApplicationReference>] = [:]
        for pair in rawSchemes {
            if pair.scheme == "*" {
                warnings.append("LaunchServices wildcard registration at \(pair.handlerURL.path) is not a concrete URL scheme.")
                continue
            }
            let identifier = try Association.urlScheme(pair.scheme).identifier
            if let reference = references[canonicalApplicationURLIdentity(pair.handlerURL)] {
                handlers[identifier, default: []].insert(reference)
            }
        }
        for application in applications {
            for declaration in application.urlSchemes {
                declarers[declaration.scheme, default: []].insert(application.reference)
            }
        }
        let schemes = Set(handlers.keys).union(declarers.keys).sorted(by: Self.ordered).map { identifier in
            URLSchemeRecord(
                identifier: identifier,
                handlerApplications: (handlers[identifier] ?? []).sorted { $0.id < $1.id },
                declaringApplications: (declarers[identifier] ?? []).sorted { $0.id < $1.id }
            )
        }

        var identifiers = Set(try rawTypes.map { try Association.contentType($0).identifier })
        identifiers.formUnion(dynamicTypes.map(\.identifier))
        let dynamicExtensions = Dictionary(grouping: dynamicTypes, by: \.identifier)
        var declarations: [String: (ContentTypeDeclaration, ApplicationReference)] = [:]
        for application in applications {
            for claim in application.documentTypeClaims {
                identifiers.formUnion(claim.contentTypeIdentifiers)
            }
            for declaration in application.exportedTypeDeclarations + application.importedTypeDeclarations {
                identifiers.insert(declaration.identifier)
                // Prefer an exporting bundle; the sorted application order resolves equal provenance.
                if declarations[declaration.identifier] == nil ||
                    (declarations[declaration.identifier]?.0.provenance == .imported && declaration.provenance == .exported) {
                    declarations[declaration.identifier] = (declaration, application.reference)
                }
            }
        }
        let existingTypes = Dictionary(uniqueKeysWithValues: (cachedSnapshot?.contentTypes ?? []).map { ($0.id, $0) })
        let types = identifiers.sorted(by: Self.ordered).map { identifier in
            if let refreshedTypes, !refreshedTypes.contains(identifier), let cached = existingTypes[identifier] { return cached }
            let systemType = UTType(identifier)
            let declaration = declarations[identifier]
            var tags = declaration?.0.tags ?? [:]
            let extensions = dynamicExtensions[identifier]?.compactMap(\.filenameExtension) ?? []
            if !extensions.isEmpty {
                tags["public.filename-extension"] = Set((tags["public.filename-extension"] ?? []) + extensions).sorted(by: Self.ordered)
            }
            for (tagClass, values) in systemType?.tags ?? [:] {
                tags[tagClass.rawValue] = Set((tags[tagClass.rawValue] ?? []) + values).sorted(by: Self.ordered)
            }
            return ContentTypeRecord(
                identifier: identifier,
                localizedDescription: systemType?.localizedDescription ?? declaration?.0.typeDescription,
                tags: tags,
                supertypes: Set((systemType?.supertypes.map(\.identifier) ?? []) + (declaration?.0.conformanceIdentifiers ?? [])).sorted(by: Self.ordered),
                declaringApplication: declaration?.1,
                isFileType: systemType?.conforms(to: .item) ?? false,
                isDynamic: systemType?.isDynamic ?? false
            )
        }
        let snapshot = CatalogSnapshot(
            applications: applications, urlSchemes: schemes, contentTypes: types,
            diagnostics: SPIDiagnostics(
                applicationCallStatus: 0, schemeCallStatus: 0,
                applicationCount: rawApplications.count, schemeCount: rawSchemes.count,
                contentTypeCount: rawTypes.count, warnings: warnings,
                expectedSymbolNames: SilgenLaunchServicesSPI.expectedSymbolNames
            )
        )
        cachedSnapshot = snapshot
        return snapshot
    }

    private static func ordered(_ lhs: String, _ rhs: String) -> Bool {
        let comparison = lhs.localizedStandardCompare(rhs)
        return comparison == .orderedSame ? lhs < rhs : comparison == .orderedAscending
    }
}
