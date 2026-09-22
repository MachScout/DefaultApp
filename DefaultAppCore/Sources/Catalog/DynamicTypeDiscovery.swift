import Foundation
import UniformTypeIdentifiers

public struct DynamicTypePreference: Hashable, Sendable {
    public let identifier: String
    public let filenameExtension: String?

    public init(identifier: String, filenameExtension: String?) {
        self.identifier = identifier
        self.filenameExtension = filenameExtension
    }
}

public protocol DynamicTypeDiscovering: Sendable {
    func discover() throws -> [DynamicTypePreference]
}

/// The public Launch Services APIs query one identifier at a time. The diagnostic
/// dump also exposes preferences keyed by an extension with no declared UTI.
public struct DynamicTypeDiscovery: DynamicTypeDiscovering {
    private static let executable = URL(fileURLWithPath:
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")

    public init() {}

    public func discover() throws -> [DynamicTypePreference] {
        // TODO: Replace the lsregister subprocess with _LSDisplayData after
        // verifying its private calling convention and output format.
        let process = Process()
        process.executableURL = Self.executable
        process.arguments = ["-dump"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DynamicTypeDiscoveryError.dumpFailed(process.terminationStatus)
        }
        guard let dump = String(data: data, encoding: .utf8) else {
            throw DynamicTypeDiscoveryError.invalidUTF8
        }
        return Self.parse(dump)
    }

    static func parse(_ dump: String) -> [DynamicTypePreference] {
        var result: Set<DynamicTypePreference> = []
        var fields: [String: String] = [:]

        func finish() {
            guard fields["handlerpref id"] != nil else { return }
            guard fields.keys.contains(where: {
                ["all roles", "viewer roles", "editor roles", "shell roles"].contains($0)
            }) else { return }
            if let extensionTag = fields["extension"],
               let type = UTType(filenameExtension: extensionTag), type.isDynamic {
                result.insert(DynamicTypePreference(identifier: type.identifier, filenameExtension: extensionTag))
            } else if let identifier = fields["content type"],
                      let type = UTType(identifier), type.isDynamic {
                result.insert(DynamicTypePreference(identifier: type.identifier,
                                                    filenameExtension: type.preferredFilenameExtension))
            }
        }

        for line in dump.components(separatedBy: .newlines) {
            if line.hasPrefix("--------") {
                finish()
                fields = [:]
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key == "handlerpref id" {
                finish()
                fields = [:]
            }
            if ["handlerpref id", "extension", "content type", "all roles", "viewer roles", "editor roles", "shell roles"].contains(key) {
                fields[key] = value
            }
        }
        finish()
        return result.sorted { $0.identifier == $1.identifier
            ? ($0.filenameExtension ?? "") < ($1.filenameExtension ?? "")
            : $0.identifier < $1.identifier }
    }
}

public enum DynamicTypeDiscoveryError: Error, LocalizedError, Sendable {
    case dumpFailed(Int32)
    case invalidUTF8

    public var errorDescription: String? {
        switch self {
        case .dumpFailed(let status): "lsregister -dump failed with status \(status)."
        case .invalidUTF8: "lsregister -dump returned text that is not UTF-8."
        }
    }
}
