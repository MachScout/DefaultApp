import Foundation
import DefaultAppCore

struct CustomAssociationValidationError: Error, LocalizedError, Equatable, Sendable {
    enum Field: String, Hashable, Sendable {
        case identifier, name, filenameExtensions, mimeType, conformsTo
    }

    let field: Field
    let message: String
    var errorDescription: String? { message }
}

struct CustomAssociation: Codable, Hashable, Identifiable, Sendable {
    let association: Association
    let name: String?
    let filenameExtensions: [String]
    let mimeType: String?
    let conformsTo: String?

    var id: Association { association }

    var contentTypeRecord: ContentTypeRecord? {
        guard association.kind == .contentType else { return nil }
        var tags = ["public.filename-extension": filenameExtensions]
        if let mimeType { tags["public.mime-type"] = [mimeType] }
        return ContentTypeRecord(
            identifier: association.identifier,
            localizedDescription: name,
            tags: tags,
            supertypes: conformsTo.map { [$0] } ?? [],
            isFileType: true
        )
    }

    fileprivate init(association: Association, name: String?, filenameExtensions: [String], mimeType: String?, conformsTo: String?) {
        self.association = association
        self.name = name
        self.filenameExtensions = filenameExtensions
        self.mimeType = mimeType
        self.conformsTo = conformsTo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let association = try container.decode(Association.self, forKey: .association)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        let extensions = try container.decode([String].self, forKey: .filenameExtensions)
        let mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        let conformsTo = try container.decodeIfPresent(String.self, forKey: .conformsTo)
        // Reject invalid persisted fields instead of silently discarding them.
        guard association.kind == .contentType || (extensions.isEmpty && mimeType == nil && conformsTo == nil && name == nil) else {
            throw DecodingError.dataCorruptedError(forKey: .association, in: container, debugDescription: "URL schemes cannot contain file type metadata.")
        }
        guard extensions.allSatisfy({ !$0.contains(",") }) else {
            throw DecodingError.dataCorruptedError(forKey: .filenameExtensions, in: container, debugDescription: "Each extension must be a single tag.")
        }
        var draft = NewAssociationDraft(kind: association.kind)
        draft.identifier = association.identifier
        draft.name = name ?? ""
        draft.filenameExtensions = extensions.joined(separator: ",")
        draft.mimeType = mimeType ?? ""
        draft.conformsTo = conformsTo ?? ""
        self = try draft.validatedRecord()
    }
}

struct NewAssociationDraft: Sendable {
    var kind: Association.Kind
    var identifier = ""
    var name = ""
    var filenameExtensions = ""
    var mimeType = ""
    var conformsTo = "public.data"

    init(kind: Association.Kind) {
        self.kind = kind
    }

    /// Parses identity before creation-only checks so existing reserved types can be selected.
    var parsedAssociation: Association? {
        switch kind {
        case .urlScheme:
            var value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasSuffix("://") { value.removeLast(3) }
            return try? .urlScheme(value)
        case .contentType:
            return try? .contentType(identifier)
        }
    }

    func validatedRecord() throws -> CustomAssociation {
        guard let association = parsedAssociation else {
            throw invalid(.identifier, kind == .urlScheme
                ? "Enter a URL scheme such as myapp, without a full URL."
                : "Enter a reverse-domain identifier such as com.example.document.")
        }
        guard kind == .contentType else {
            return CustomAssociation(association: association, name: nil, filenameExtensions: [], mimeType: nil, conformsTo: nil)
        }

        let identifier = association.identifier
        let components = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, components.allSatisfy({ component in
            guard let first = component.utf8.first, let last = component.utf8.last else { return false }
            return Self.isAlphanumeric(first) && Self.isAlphanumeric(last)
                && component.utf8.allSatisfy { Self.isAlphanumeric($0) || $0 == 45 }
        }) else {
            throw invalid(.identifier, "Use a reverse-domain identifier such as com.example.document, with letters, numbers, dots and hyphens.")
        }
        guard !["public", "com.apple", "dyn"].contains(where: { identifier == $0 || identifier.hasPrefix($0 + ".") }) else {
            throw invalid(.identifier, "The public, com.apple and dyn namespaces are reserved. Use your own reverse-domain identifier.")
        }

        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw invalid(.name, "Enter a display name for this file type.")
        }
        var extensions: [String] = []
        for rawTag in filenameExtensions.split(separator: ",", omittingEmptySubsequences: false) {
            var tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if tag.hasPrefix(".") { tag.removeFirst() }
            guard !tag.isEmpty, !tag.hasPrefix("."), !tag.hasSuffix("."),
                  tag.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "." }),
                  !tag.contains("..") else {
                throw invalid(.filenameExtensions, "Enter comma-separated extensions such as report, rpt. Do not include paths, wildcards or empty entries.")
            }
            if !extensions.contains(tag) { extensions.append(tag) }
        }
        let mimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !mimeType.isEmpty {
            let parts = mimeType.split(separator: "/", omittingEmptySubsequences: false)
            let punctuation = Set("!#$&^_.+-".utf8)
            guard parts.count == 2, parts.allSatisfy({ part in
                guard let first = part.utf8.first, Self.isAlphanumeric(first) else { return false }
                return part.utf8.allSatisfy { Self.isAlphanumeric($0) || punctuation.contains($0) }
            }) else {
                throw invalid(.mimeType, "Enter a MIME type such as application/x-report, or leave it empty.")
            }
        }
        let base = conformsTo.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["public.data", "public.text", "com.apple.package"].contains(base) else {
            throw invalid(.conformsTo, "Choose Data, Text or Package as the base type.")
        }
        return CustomAssociation(association: association, name: name, filenameExtensions: extensions,
            mimeType: mimeType.isEmpty ? nil : mimeType, conformsTo: base)
    }

    private func invalid(_ field: CustomAssociationValidationError.Field, _ message: String) -> CustomAssociationValidationError {
        CustomAssociationValidationError(field: field, message: message)
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (97...122).contains(byte) || (48...57).contains(byte)
    }
}
