import Darwin
import Foundation
import UniformTypeIdentifiers

private typealias LSDisplayDataFunction = @convention(c) (
    UnsafeMutablePointer<FILE>?, UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?,
    UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?
) -> Int32

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
/// dump exposes all registered dynamic identifiers and extension preferences.
public struct DynamicTypeDiscovery: DynamicTypeDiscovering {
    public init() {}

    public func discover() throws -> [DynamicTypePreference] {
        guard let framework = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW) else {
            throw DynamicTypeDiscoveryError.displayUnavailable
        }
        defer { dlclose(framework) }
        guard let symbol = dlsym(framework, "_LSDisplayData"), let output = tmpfile() else {
            throw DynamicTypeDiscoveryError.displayUnavailable
        }
        defer { fclose(output) }

        let display = unsafeBitCast(symbol, to: LSDisplayDataFunction.self)
        // Current macOS returns 1 even after writing a complete dump.
        _ = display(output, nil, nil, nil, nil, nil, nil)
        guard fflush(output) == 0, fseek(output, 0, SEEK_END) == 0 else {
            throw DynamicTypeDiscoveryError.dumpUnreadable
        }
        let length = ftell(output)
        guard length > 0, fseek(output, 0, SEEK_SET) == 0 else {
            throw DynamicTypeDiscoveryError.dumpUnreadable
        }
        var data = Data(count: Int(length))
        let bytesRead = data.withUnsafeMutableBytes { bytes in
            fread(bytes.baseAddress, 1, Int(length), output)
        }
        guard bytesRead == Int(length) else { throw DynamicTypeDiscoveryError.dumpUnreadable }
        let dump = String(decoding: data, as: UTF8.self)
        guard dump.contains("claimed UTIs:") else { throw DynamicTypeDiscoveryError.incompleteDump }
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
        let expression = try! NSRegularExpression(pattern: #"dyn\.[a-z0-9]+"#)
        let source = dump as NSString
        let range = NSRange(location: 0, length: source.length)
        let represented = Set(result.map(\.identifier))
        for match in expression.matches(in: dump, range: range) {
            let identifier = source.substring(with: match.range)
            if !represented.contains(identifier) {
                result.insert(DynamicTypePreference(identifier: identifier, filenameExtension: nil))
            }
        }
        return result.sorted { $0.identifier == $1.identifier
            ? ($0.filenameExtension ?? "") < ($1.filenameExtension ?? "")
            : $0.identifier < $1.identifier }
    }
}

public enum DynamicTypeDiscoveryError: Error, LocalizedError, Sendable {
    case displayUnavailable
    case dumpUnreadable
    case incompleteDump

    public var errorDescription: String? {
        switch self {
        case .displayUnavailable: "_LSDisplayData is unavailable."
        case .dumpUnreadable: "Launch Services display data could not be read."
        case .incompleteDump: "Launch Services display data contains no claimed content types."
        }
    }
}
