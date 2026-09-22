import Foundation
import UniformTypeIdentifiers

public struct BundleDeclarationParser: Sendable {
    public init() {}

    public func parse(
        applicationURL: URL,
        infoDictionary: [String: Any]
    ) throws -> ApplicationRecord {
        var warnings: [String] = []
        let bundleIdentifier = string(from: infoDictionary["CFBundleIdentifier"])
        let displayName = string(from: infoDictionary["CFBundleDisplayName"])
            ?? string(from: infoDictionary["CFBundleName"])
            ?? applicationURL.deletingPathExtension().lastPathComponent

        return ApplicationRecord(
            url: applicationURL,
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            bundleVersion: string(from: infoDictionary["CFBundleVersion"]),
            shortVersion: string(from: infoDictionary["CFBundleShortVersionString"]),
            urlSchemes: parseURLSchemes(infoDictionary["CFBundleURLTypes"], warnings: &warnings),
            documentTypeClaims: parseDocumentTypeClaims(
                infoDictionary["CFBundleDocumentTypes"],
                warnings: &warnings
            ),
            exportedTypeDeclarations: parseTypeDeclarations(
                infoDictionary["UTExportedTypeDeclarations"],
                provenance: .exported,
                declaringBundleIdentifier: bundleIdentifier,
                warnings: &warnings
            ),
            importedTypeDeclarations: parseTypeDeclarations(
                infoDictionary["UTImportedTypeDeclarations"],
                provenance: .imported,
                declaringBundleIdentifier: bundleIdentifier,
                warnings: &warnings
            ),
            warnings: warnings
        )
    }

    private func parseURLSchemes(_ value: Any?, warnings: inout [String]) -> [URLSchemeDeclaration] {
        guard let value else { return [] }
        guard let entries = value as? [Any] else {
            warnings.append("CFBundleURLTypes is not an array.")
            return []
        }

        var declarations: [URLSchemeDeclaration] = []
        for (index, entry) in entries.enumerated() {
            guard let entry = dictionary(from: entry) else {
                warnings.append("CFBundleURLTypes entry \(index) is not a dictionary.")
                continue
            }
            guard let values = strictStringArray(from: entry["CFBundleURLSchemes"]) else {
                warnings.append("CFBundleURLTypes entry \(index) has no valid CFBundleURLSchemes array.")
                continue
            }

            let name = string(from: entry["CFBundleURLName"])
            for value in values {
                do {
                    declarations.append(
                        URLSchemeDeclaration(
                            scheme: try Association.urlScheme(value).identifier,
                            name: name
                        )
                    )
                } catch {
                    warnings.append("CFBundleURLTypes entry \(index) contains an invalid URL scheme: \(value)")
                }
            }
        }
        return Dictionary(grouping: declarations, by: \.scheme).map { scheme, entries in
            URLSchemeDeclaration(
                scheme: scheme,
                name: entries.compactMap(\.name).min(),
                role: entries.reduce(into: HandlerRole()) { $0.formUnion($1.role) }
            )
        }.sorted { $0.scheme < $1.scheme }
    }

    private func parseDocumentTypeClaims(_ value: Any?, warnings: inout [String]) -> [DocumentTypeClaim] {
        guard let value else { return [] }
        guard let entries = value as? [Any] else {
            warnings.append("CFBundleDocumentTypes is not an array.")
            return []
        }

        var claims: [DocumentTypeClaim] = []
        for (index, entry) in entries.enumerated() {
            guard let entry = dictionary(from: entry) else {
                warnings.append("CFBundleDocumentTypes entry \(index) is not a dictionary.")
                continue
            }

            var identifiers = normalizedContentTypeIdentifiers(
                entry["LSItemContentTypes"],
                field: "CFBundleDocumentTypes entry \(index) LSItemContentTypes",
                warnings: &warnings
            )
            let extensions = normalizedStrings(
                entry["CFBundleTypeExtensions"],
                field: "CFBundleDocumentTypes entry \(index) CFBundleTypeExtensions",
                warnings: &warnings
            )
            let mimeTypes = normalizedStrings(
                entry["CFBundleTypeMIMETypes"],
                field: "CFBundleDocumentTypes entry \(index) CFBundleTypeMIMETypes",
                warnings: &warnings
            )
            let osTypes = typeCodes(
                entry["CFBundleTypeOSTypes"],
                field: "CFBundleDocumentTypes entry \(index) CFBundleTypeOSTypes",
                warnings: &warnings
            )
            if identifiers.isEmpty {
                // Declared-type enumeration omits identifiers synthesized from legacy document tags.
                let supertype: UTType = (entry["LSTypeIsPackage"] as? Bool) == true ? .package : .data
                let osTypeClass = UTTagClass(rawValue: "com.apple.ostype")
                identifiers = Set(
                    extensions.filter { !$0.contains("*") }.compactMap {
                        UTType(filenameExtension: $0, conformingTo: supertype)?.identifier
                    } + mimeTypes.filter { !$0.contains("*") }.compactMap {
                        UTType(mimeType: $0, conformingTo: supertype)?.identifier
                    } + osTypes.compactMap {
                        UTType(tag: $0, tagClass: osTypeClass, conformingTo: supertype)?.identifier
                    }
                ).sorted()
            }

            claims.append(
                DocumentTypeClaim(
                    name: string(from: entry["CFBundleTypeName"]),
                    contentTypeIdentifiers: identifiers,
                    filenameExtensions: extensions,
                    mimeTypes: mimeTypes,
                    rank: string(from: entry["LSHandlerRank"]),
                    role: role(from: entry["CFBundleTypeRole"], field: "CFBundleDocumentTypes entry \(index)", warnings: &warnings)
                )
            )
        }
        return claims
    }

    private func parseTypeDeclarations(
        _ value: Any?,
        provenance: ContentTypeDeclarationProvenance,
        declaringBundleIdentifier: String?,
        warnings: inout [String]
    ) -> [ContentTypeDeclaration] {
        guard let value else { return [] }
        let key = provenance == .exported ? "UTExportedTypeDeclarations" : "UTImportedTypeDeclarations"
        guard let entries = value as? [Any] else {
            warnings.append("\(key) is not an array.")
            return []
        }

        var declarations: [ContentTypeDeclaration] = []
        for (index, entry) in entries.enumerated() {
            guard let entry = dictionary(from: entry) else {
                warnings.append("\(key) entry \(index) is not a dictionary.")
                continue
            }
            guard let rawIdentifier = string(from: entry["UTTypeIdentifier"]) else {
                warnings.append("\(key) entry \(index) has no UTTypeIdentifier.")
                continue
            }

            let identifier: String
            do {
                identifier = try Association.contentType(rawIdentifier).identifier
            } catch {
                warnings.append("\(key) entry \(index) has an invalid UTTypeIdentifier: \(rawIdentifier)")
                continue
            }

            declarations.append(
                ContentTypeDeclaration(
                    identifier: identifier,
                    provenance: provenance,
                    typeDescription: string(from: entry["UTTypeDescription"]),
                    tags: tags(entry["UTTypeTagSpecification"], field: "\(key) entry \(index)", warnings: &warnings),
                    conformanceIdentifiers: normalizedContentTypeIdentifiers(
                        entry["UTTypeConformsTo"],
                        field: "\(key) entry \(index) UTTypeConformsTo",
                        warnings: &warnings
                    ),
                    declaringBundleIdentifier: declaringBundleIdentifier
                )
            )
        }
        // Merge only within this application's provenance. Sorted unions retain
        // metadata, and the smallest non-nil scalar is independent of plist order.
        return Dictionary(grouping: declarations, by: \.identifier).map { identifier, entries in
            var mergedTags: [String: Set<String>] = [:]
            for entry in entries {
                for (key, values) in entry.tags {
                    mergedTags[key, default: []].formUnion(values)
                }
            }
            return ContentTypeDeclaration(
                identifier: identifier,
                provenance: provenance,
                typeDescription: entries.compactMap(\.typeDescription).min(),
                tags: mergedTags.mapValues { $0.sorted() },
                conformanceIdentifiers: Set(entries.flatMap(\.conformanceIdentifiers)).sorted(),
                declaringBundleIdentifier: declaringBundleIdentifier
            )
        }.sorted { $0.identifier < $1.identifier }
    }

    private func normalizedContentTypeIdentifiers(
        _ value: Any?,
        field: String,
        warnings: inout [String]
    ) -> [String] {
        guard let value else { return [] }
        guard let values = stringOrArray(from: value) else {
            warnings.append("\(field) is not a string or array of strings.")
            return []
        }

        return values.compactMap { value in
            do {
                return try Association.contentType(value).identifier
            } catch {
                warnings.append("\(field) contains an invalid content type identifier: \(value)")
                return nil
            }
        }
    }

    private func normalizedStrings(_ value: Any?, field: String, warnings: inout [String]) -> [String] {
        guard let value else { return [] }
        let values: [Any]
        if let string = value as? String {
            values = [string]
        } else if let array = value as? [Any] {
            values = array
        } else {
            warnings.append("\(field) is not a string or array of strings.")
            return []
        }
        return values.compactMap { element in
            guard let string = string(from: element) else {
                warnings.append("\(field) contains an invalid string.")
                return nil
            }
            return string.lowercased()
        }
    }

    private func typeCodes(_ value: Any?, field: String, warnings: inout [String]) -> [String] {
        guard let value else { return [] }
        let codes: [String]
        if let string = value as? String {
            codes = [string]
        } else if let strings = value as? [String] {
            codes = strings
        } else {
            warnings.append("\(field) is not a string or array of strings.")
            return []
        }
        return codes.compactMap { code in
            guard !code.isEmpty, code.utf8.allSatisfy({ $0 < 0x80 }) else {
                warnings.append("\(field) contains an invalid type code: \(code)")
                return nil
            }
            // LaunchServices treats legacy OSTypes as four bytes, truncating or NUL-padding strings.
            let prefix = String(decoding: code.utf8.prefix(4), as: UTF8.self)
            if prefix == "****" || prefix == "????" { return nil }
            return prefix + String(repeating: "\0", count: 4 - prefix.utf8.count)
        }
    }

    private func tags(_ value: Any?, field: String, warnings: inout [String]) -> [String: [String]] {
        guard let value else { return [:] }
        guard let dictionary = dictionary(from: value) else {
            warnings.append("\(field) UTTypeTagSpecification is not a dictionary.")
            return [:]
        }

        var tags: [String: [String]] = [:]
        for (key, value) in dictionary {
            guard let values = stringOrArray(from: value) else {
                warnings.append("\(field) tag \(key) is not a string or array of strings.")
                continue
            }
            tags[key] = values
        }
        return tags
    }

    private func role(from value: Any?, field: String, warnings: inout [String]) -> HandlerRole {
        guard let value else { return [] }
        guard let value = string(from: value) else {
            warnings.append("\(field) has a non-string CFBundleTypeRole.")
            return []
        }

        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "viewer":
            return .viewer
        case "editor":
            return .editor
        case "shell":
            return .shell
        case "none":
            return []
        default:
            warnings.append("\(field) has an unknown CFBundleTypeRole: \(value)")
            return []
        }
    }

    private func dictionary(from value: Any) -> [String: Any]? {
        value as? [String: Any]
    }

    private func string(from value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private func strictStringArray(from value: Any?) -> [String]? {
        guard let values = value as? [Any] else { return nil }
        let strings = values.compactMap { string(from: $0) }
        return strings.count == values.count ? strings : nil
    }

    private func stringOrArray(from value: Any) -> [String]? {
        if let value = string(from: value) {
            return [value]
        }
        return strictStringArray(from: value)
    }
}
