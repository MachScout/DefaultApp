import Foundation
import DefaultAppCore

public protocol CLIHandlerServicing: Sendable {
    func catalog(forceRefresh: Bool) async throws -> CatalogSnapshot
    func applications(capableOf association: Association, backend: Backend, role: HandlerRole) async throws -> [ApplicationRecord]
    func defaultApplication(for association: Association, backend: Backend, role: HandlerRole) async throws -> ApplicationRecord?
    func setDefaultApplication(_ application: ApplicationReference, for association: Association,
                               backend: Backend, role: HandlerRole) async throws
}

extension HandlerService: CLIHandlerServicing {}

public enum CLIApplicationError: Error, Equatable, LocalizedError, Sendable {
    case applicationNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .applicationNotFound(value):
            "No registered application matches \(value)."
        }
    }
}

public struct CLIApplication: Sendable {
    private let parser: CLIParser
    private let renderer: CLIOutput
    private let currentDirectoryURL: URL
    private let pathExists: @Sendable (String) -> Bool
    private let applicationReferenceResolver: any ApplicationReferenceResolving

    public init(
        parser: CLIParser = CLIParser(),
        renderer: CLIOutput = CLIOutput(),
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        pathExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        applicationReferenceResolver: any ApplicationReferenceResolving = BundleApplicationReferenceResolver()
    ) {
        self.parser = parser
        self.renderer = renderer
        self.currentDirectoryURL = currentDirectoryURL
        self.pathExists = pathExists
        self.applicationReferenceResolver = applicationReferenceResolver
    }

    public func run(
        arguments: [String],
        service: any CLIHandlerServicing,
        output: any CLIOutputSink
    ) async -> Int32 {
        let command: CLICommand
        do {
            command = try parser.parse(arguments)
        } catch {
            await output.writeStderr("error: \(description(of: error))\n\n\(CLIOutput.help)")
            return 2
        }

        do {
            let text = try await execute(command, service: service, output: output)
            await output.writeStdout(text)
            return 0
        } catch {
            await output.writeStderr("error: \(description(of: error))\n")
            return exitStatus(for: error)
        }
    }

    private func execute(
        _ command: CLICommand,
        service: any CLIHandlerServicing,
        output: any CLIOutputSink
    ) async throws -> String {
        switch command {
        case .help:
            return CLIOutput.help
        case let .apps(json):
            let values = try await service.catalog(forceRefresh: false).applications
            return try json ? renderer.json(values) : renderer.applications(values)
        case let .app(value, json):
            let snapshot = try await service.catalog(forceRefresh: false)
            let application = try resolveRecord(value, in: snapshot)
            return try json ? renderer.json(application) : renderer.application(application)
        case let .schemes(json):
            let values = try await service.catalog(forceRefresh: false).urlSchemes
            return try json ? renderer.json(values) : renderer.schemes(values)
        case let .types(json):
            let values = try await service.catalog(forceRefresh: false).contentTypes
            return try json ? renderer.json(values) : renderer.types(values)
        case let .handlers(kind, identifier, backend, role, json):
            let association = try kind.association(identifier: identifier)
            let values = try await service.applications(capableOf: association, backend: backend, role: role)
            return try json ? renderer.json(values) : renderer.applications(values)
        case let .get(kind, identifier, backend, role, json):
            let association = try kind.association(identifier: identifier)
            let value = try await service.defaultApplication(for: association, backend: backend, role: role)
            return try json ? renderer.json(value) : renderer.defaultApplication(value)
        case let .set(kind, identifier, app, backend, role):
            let association = try kind.association(identifier: identifier)
            let snapshot = try await service.catalog(forceRefresh: false)
            let application = try resolveReference(app, in: snapshot)
            await output.writeStderr(CLIOutput.setWarning)
            try await service.setDefaultApplication(application, for: association, backend: backend, role: role)
            return renderer.setSuccess(application: application, association: association)
        case let .doctor(json):
            let diagnostics = try await service.catalog(forceRefresh: true).diagnostics
            return try json ? renderer.json(diagnostics) : renderer.diagnostics(diagnostics)
        }
    }

    private func resolveRecord(_ value: String, in snapshot: CatalogSnapshot) throws -> ApplicationRecord {
        if let fileURL = existingFileURL(value) {
            guard let record = snapshot.applications.first(where: { normalizedPath($0.url) == normalizedPath(fileURL) }) else {
                throw CLIApplicationError.applicationNotFound(value)
            }
            return record
        }
        guard let record = snapshot.applications.first(where: { $0.bundleIdentifier == value }) else {
            throw CLIApplicationError.applicationNotFound(value)
        }
        return record
    }

    private func resolveReference(_ value: String, in snapshot: CatalogSnapshot) throws -> ApplicationReference {
        if let fileURL = existingFileURL(value) {
            if let record = snapshot.applications.first(where: { normalizedPath($0.url) == normalizedPath(fileURL) }) {
                return record.reference
            }
            return applicationReferenceResolver.reference(forApplicationAt: fileURL)
        }
        guard let record = snapshot.applications.first(where: { $0.bundleIdentifier == value }) else {
            throw CLIApplicationError.applicationNotFound(value)
        }
        return record.reference
    }

    private func existingFileURL(_ value: String) -> URL? {
        let expanded = (value as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : currentDirectoryURL.appendingPathComponent(expanded)
        let normalized = url.standardizedFileURL
        return pathExists(normalized.path) ? normalized : nil
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func exitStatus(for error: Error) -> Int32 {
        if error is CLIUsageError { return 2 }
        if error is CLIApplicationError { return 4 }
        guard let error = error as? DefaultAppError else { return 5 }
        switch error {
        case .malformedAssociationIdentifier:
            return 2
        case .privateSPIFailure, .malformedSPIPayload, .unreadableBundleMetadata, .malformedBundleMetadata:
            return 3
        case .unknownContentType, .missingBundleIdentifier, .applicationNotRegistered,
             .applicationNotCapable, .unsupportedRole:
            return 4
        case .modernFailure, .legacyFailure, .changeRejected:
            return 5
        case .changeNotObserved:
            return 6
        }
    }

    private func description(of error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
