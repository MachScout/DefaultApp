import Foundation

public struct Association: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case urlScheme
        case contentType
    }

    public let kind: Kind
    public let identifier: String

    private init(kind: Kind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }

    public static func urlScheme(_ rawValue: String) throws -> Self {
        var identifier = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if identifier.hasSuffix(":") {
            identifier.removeLast()
        }
        // Validate before lowercasing: Unicode letters such as K can lowercase
        // to ASCII, but RFC URL schemes permit ASCII input only.
        guard
            let first = identifier.unicodeScalars.first,
            isASCIILetter(first),
            identifier.unicodeScalars.allSatisfy({
                isASCIILetter($0) || isASCIIDigit($0) || $0 == "+" || $0 == "-" || $0 == "."
            })
        else {
            throw DefaultAppError.malformedAssociationIdentifier(
                kind: .urlScheme,
                value: rawValue
            )
        }

        return Association(kind: .urlScheme, identifier: identifier.lowercased())
    }

    public static func contentType(_ rawValue: String) throws -> Self {
        let identifier = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard
            !identifier.isEmpty,
            identifier.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
            identifier.unicodeScalars.allSatisfy({
                isASCIILetter($0) || isASCIIDigit($0) || $0 == "." || $0 == "-" || $0.value > 0x7F
            })
        else {
            throw DefaultAppError.malformedAssociationIdentifier(
                kind: .contentType,
                value: rawValue
            )
        }

        return Association(kind: .contentType, identifier: identifier)
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let identifier = try container.decode(String.self, forKey: .identifier)

        switch kind {
        case .urlScheme:
            self = try Association.urlScheme(identifier)
        case .contentType:
            self = try Association.contentType(identifier)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(identifier, forKey: .identifier)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case identifier
    }
}

public enum Backend: String, Codable, CaseIterable, Sendable {
    case modern
    case legacy
}

public struct HandlerRole: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let viewer = HandlerRole(rawValue: 1 << 1)
    public static let editor = HandlerRole(rawValue: 1 << 2)
    public static let shell = HandlerRole(rawValue: 1 << 3)
    public static let all: HandlerRole = [.viewer, .editor, .shell]
}
