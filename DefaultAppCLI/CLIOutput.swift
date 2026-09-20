import Foundation
import DefaultAppCore

public struct CLIOutput: Sendable {
    public static let help = """
    Usage:
      defaultapp apps [--json]
      defaultapp app <bundle-id-or-path> [--json]
      defaultapp schemes [--json]
      defaultapp types [--json]
      defaultapp handlers <scheme|uti> <identifier> [--backend modern|legacy] [--role all|viewer|editor|shell] [--json]
      defaultapp get <scheme|uti> <identifier> [--backend modern|legacy] [--role all|viewer|editor|shell] [--json]
      defaultapp set <scheme|uti> <identifier> --app <bundle-id-or-path> [--backend modern|legacy] [--role all|viewer|editor|shell]
      defaultapp doctor [--json]

    Defaults: --backend modern --role all
    Roles other than all require the legacy backend and a uti association.
    """ + "\n"

    public static let setWarning = "warning: macOS may show a system confirmation dialog; waiting for the handler change to finish.\n"

    public init() {}

    public func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
    }

    public func applications(_ applications: [ApplicationRecord]) -> String {
        table(
            headers: ["NAME", "BUNDLE ID", "PATH"],
            rows: applications.map { [$0.displayName, $0.bundleIdentifier ?? "—", $0.url.path] }
        )
    }

    public func application(_ application: ApplicationRecord) -> String {
        let version = application.shortVersion ?? application.bundleVersion ?? "—"
        return table(
            headers: ["FIELD", "VALUE"],
            rows: [
                ["Name", application.displayName],
                ["Bundle ID", application.bundleIdentifier ?? "—"],
                ["Path", application.url.path],
                ["Version", version],
                ["URL schemes", String(application.urlSchemes.count)],
                ["Document types", String(application.documentTypeClaims.count)],
                ["Exported UTIs", String(application.exportedTypeDeclarations.count)],
                ["Imported UTIs", String(application.importedTypeDeclarations.count)],
                ["Warnings", String(application.warnings.count)],
            ]
        )
    }

    public func schemes(_ schemes: [URLSchemeRecord]) -> String {
        table(
            headers: ["SCHEME", "HANDLERS", "DECLARERS"],
            rows: schemes.map {
                [$0.identifier, String($0.handlerApplications.count), String($0.declaringApplications.count)]
            }
        )
    }

    public func types(_ types: [ContentTypeRecord]) -> String {
        table(
            headers: ["UTI", "DESCRIPTION", "DECLARING APP"],
            rows: types.map {
                [$0.identifier, $0.localizedDescription ?? "—", $0.declaringApplication?.bundleIdentifier ?? "—"]
            }
        )
    }

    public func defaultApplication(_ application: ApplicationRecord?) -> String {
        guard let application else { return "No default handler.\n" }
        return self.application(application)
    }

    public func diagnostics(_ diagnostics: SPIDiagnostics) -> String {
        let status: (Int32?) -> String = { value in value.map(String.init) ?? "not called" }
        var rows = [
            ["Application SPI", status(diagnostics.applicationCallStatus), String(diagnostics.applicationCount)],
            ["Scheme SPI", status(diagnostics.schemeCallStatus), String(diagnostics.schemeCount)],
            ["Content-type SPI", status(diagnostics.contentTypeCallStatus), String(diagnostics.contentTypeCount)],
            ["Warnings", "—", String(diagnostics.warnings.count)],
        ]
        rows.append(contentsOf: diagnostics.expectedSymbolNames.map { ["Expected symbol", $0, "—"] })
        rows.append(contentsOf: diagnostics.warnings.map { ["Warning", $0, "—"] })
        return table(headers: ["CHECK", "STATUS", "COUNT"], rows: rows)
    }

    public func setSuccess(application: ApplicationReference, association: Association) -> String {
        let identity = application.bundleIdentifier ?? application.url.path
        return "Set \(association.identifier) default handler to \(identity).\n"
    }

    private func table(headers: [String], rows: [[String]]) -> String {
        let widths = headers.indices.map { column in
            ([headers[column]] + rows.map { $0[column] }).map(\.count).max() ?? 0
        }
        let lines = ([headers] + rows).map { row in
            row.indices.map { column in
                column == row.indices.last ? row[column] : row[column].padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public protocol CLIOutputSink: Sendable {
    func writeStdout(_ text: String) async
    func writeStderr(_ text: String) async
}

public actor StandardCLIOutputSink: CLIOutputSink {
    private let standardOutput: FileHandle
    private let standardError: FileHandle

    public init(standardOutput: FileHandle = .standardOutput, standardError: FileHandle = .standardError) {
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public func writeStdout(_ text: String) {
        standardOutput.write(Data(text.utf8))
    }

    public func writeStderr(_ text: String) {
        standardError.write(Data(text.utf8))
    }
}
