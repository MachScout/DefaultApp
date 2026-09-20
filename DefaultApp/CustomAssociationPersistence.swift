import CoreServices
import CryptoKit
import Foundation
import UniformTypeIdentifiers

protocol CustomAssociationPersisting: Sendable {
    func load() async throws -> [CustomAssociation]
    func save(_ records: [CustomAssociation]) async throws
}

actor CustomAssociationFileStore: CustomAssociationPersisting {
    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DefaultApp", isDirectory: true)

    private let url: URL

    init(url: URL = CustomAssociationFileStore.defaultDirectory.appendingPathComponent("CustomAssociations.json")) {
        self.url = url
    }

    func load() async throws -> [CustomAssociation] {
        try readRecords()
    }

    func save(_ records: [CustomAssociation]) async throws {
        // A broken existing file is evidence to preserve, including when save is called before load.
        _ = try readRecords()
        try rejectDuplicates(records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func readRecords() throws -> [CustomAssociation] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        let records = try JSONDecoder().decode([CustomAssociation].self, from: data)
        try rejectDuplicates(records)
        return records
    }

    private func rejectDuplicates(_ records: [CustomAssociation]) throws {
        guard Set(records.map(\.association)).count == records.count else {
            throw CustomAssociationStorageError.duplicateRecords
        }
    }
}

protocol CustomTypeRegistering: Sendable {
    func register(_ record: CustomAssociation) async throws
    func isRegistered(_ record: CustomAssociation) async -> Bool
}

actor CustomTypeRegistrar: CustomTypeRegistering {
    private let directory: URL
    private let registration: @Sendable (URL) throws -> Void
    private let verification: @Sendable (String) -> Bool
    private let declarationWriter: @Sendable (Data, URL) throws -> Void

    init(
        directory: URL = CustomAssociationFileStore.defaultDirectory.appendingPathComponent("Type Declarations", isDirectory: true),
        registration: @escaping @Sendable (URL) throws -> Void = { url in
            let status = LSRegisterURL(url as CFURL, true)
            guard status == noErr else { throw CustomAssociationStorageError.registrationFailed(status) }
        },
        verification: @escaping @Sendable (String) -> Bool = { UTType($0)?.isDeclared == true },
        declarationWriter: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.directory = directory
        self.registration = registration
        self.verification = verification
        self.declarationWriter = declarationWriter
    }

    func isRegistered(_ record: CustomAssociation) async -> Bool {
        record.association.kind == .contentType && verification(record.association.identifier)
    }

    func register(_ record: CustomAssociation) async throws {
        guard record.association.kind == .contentType else { return }
        let identifier = record.association.identifier
        let digest = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
        let bundleIdentifier = "app.defaultapp.type-declaration.\(digest)"
        let bundleURL = directory.appendingPathComponent("\(digest).app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let plistURL = contentsURL.appendingPathComponent("Info.plist")
        let manager = FileManager.default
        let bundleExists = manager.fileExists(atPath: bundleURL.path)
        if bundleExists {
            // Never turn an unrelated bundle occupying our deterministic path into our declaration.
            let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
            guard values?["CFBundleIdentifier"] as? String == bundleIdentifier,
                  values?["DefaultAppCustomTypeIdentifier"] as? String == identifier,
                  values?["CFBundleExecutable"] == nil,
                  values?["CFBundleDocumentTypes"] == nil,
                  values?["CFBundleURLTypes"] == nil else {
                throw CustomAssociationStorageError.bundleNotOwned(bundleURL)
            }
        }
        var tags: [String: [String]] = ["public.filename-extension": record.filenameExtensions]
        if let mimeType = record.mimeType { tags["public.mime-type"] = [mimeType] }
        let declaration: [String: Any] = [
            "UTTypeIdentifier": identifier,
            "UTTypeDescription": record.name ?? identifier,
            "UTTypeConformsTo": record.conformsTo.map { [$0] } ?? ["public.data"],
            "UTTypeTagSpecification": tags
        ]
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": record.name ?? identifier,
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleInfoDictionaryVersion": "6.0",
            "DefaultAppCustomTypeIdentifier": identifier,
            "UTExportedTypeDeclarations": [declaration]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        if bundleExists {
            try declarationWriter(data, plistURL)
        } else {
            // Publish only a complete bundle. Failed writes and interrupted preparation
            // must not occupy the deterministic destination and prevent a later retry.
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let stagingURL = directory.appendingPathComponent(".type-declaration-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            defer { try? manager.removeItem(at: stagingURL) }
            let stagedContents = stagingURL.appendingPathComponent("Contents", isDirectory: true)
            try manager.createDirectory(at: stagedContents, withIntermediateDirectories: false)
            try declarationWriter(data, stagedContents.appendingPathComponent("Info.plist"))
            try manager.moveItem(at: stagingURL, to: bundleURL)
        }
        try registration(bundleURL)
        // Launch Services returning success alone is insufficient. A stale negative lookup
        // conservatively surfaces a retryable failure; it must never authorize setting a default.
        guard verification(identifier) else {
            throw CustomAssociationStorageError.registrationUnverified(identifier)
        }
    }
}

enum CustomAssociationStorageError: Error, LocalizedError, Sendable {
    case duplicateRecords
    case bundleNotOwned(URL)
    case registrationFailed(OSStatus)
    case registrationUnverified(String)

    var errorDescription: String? {
        switch self {
        case .duplicateRecords:
            "The custom associations file contains duplicate identifiers. The existing file has been preserved."
        case .bundleNotOwned(let url):
            "The type declaration bundle at \(url.path) belongs to another definition and was not changed."
        case .registrationFailed(let status):
            "Launch Services could not register the custom file type (status \(status)). Your saved definition is available for retry."
        case .registrationUnverified(let identifier):
            "The definition was saved, but macOS has not confirmed registration of \(identifier). Retry, or reopen DefaultApp and try again."
        }
    }
}
