import Foundation
import XCTest
@testable import DefaultAppCore

final class BundleDeclarationParserTests: XCTestCase {
    private let parser = BundleDeclarationParser()
    private let appURL = URL(fileURLWithPath: "/Applications/Sample.app")

    func testParsesSchemesDocumentClaimsAndTypeDeclarations() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: BundleDeclarationParserTests.self)
                .url(forResource: "CompleteAppInfo", withExtension: "plist")
        )
        let fixture = try XCTUnwrap(NSDictionary(contentsOf: fixtureURL) as? [String: Any])

        let record = try parser.parse(applicationURL: appURL, infoDictionary: fixture)

        XCTAssertEqual(record.bundleIdentifier, "com.example.Sample")
        XCTAssertEqual(record.urlSchemes.map(\.scheme), ["sample", "sample-secure"])
        XCTAssertEqual(record.documentTypeClaims.first?.contentTypeIdentifiers,
                       ["com.example.sample-document"])
        XCTAssertEqual(record.documentTypeClaims.first?.role, .viewer)
        XCTAssertEqual(record.exportedTypeDeclarations.map(\.identifier),
                       ["com.example.sample-document"])
        XCTAssertEqual(record.importedTypeDeclarations.map(\.identifier),
                       ["public.json"])
    }

    func testLegacyDocumentTagsSynthesizeDynamicIdentifiers() throws {
        let record = try parser.parse(applicationURL: appURL, infoDictionary: [
            "CFBundleDocumentTypes": [[
                "CFBundleTypeExtensions": ["", "mcpb", "*"],
                "CFBundleTypeMIMETypes": ["application/x-rdp"],
                "CFBundleTypeOSTypes": ["pptr", "SVG ", "****"]
            ]]
        ])
        XCTAssertEqual(Set(record.documentTypeClaims[0].contentTypeIdentifiers), [
            "dyn.ah62d4rv4ge80425uqk",
            "dyn.ah62d4rv4gq80c6durvy0g2pyrf106p52fz3gk6a",
            "dyn.ah62d4rv4gk81a6dysk",
            "dyn.ah62d4rv4gk8zgzwhea"
        ])
    }

    func testLegacyPackageAndOSTypeCodesUseLaunchServicesConformanceAndWidth() throws {
        let record = try parser.parse(applicationURL: appURL, infoDictionary: [
            "CFBundleDocumentTypes": [
                ["CFBundleTypeExtensions": ["dvdmedia"], "LSTypeIsPackage": true],
                ["CFBundleTypeOSTypes": ["AISVG", "skp", "gcx", "*"]]
            ]
        ])
        XCTAssertEqual(record.documentTypeClaims[0].contentTypeIdentifiers,
                       ["dyn.ah62d4qmuhk2x43d0qv00n3dmqe"])
        XCTAssertEqual(Set(record.documentTypeClaims[1].contentTypeIdentifiers), [
            "dyn.ah62d4rv4gk8ycwnxn2", "dyn.ah62d4rv4gk81g45upuaa",
            "dyn.ah62d4rv4gk80s252puaa", "dyn.ah62d4rv4gk8wy1aapuaf2aa"
        ])
    }

    func testMalformedNestedDeclarationsProduceWarningsNotFailure() throws {
        let record = try parser.parse(
            applicationURL: appURL,
            infoDictionary: ["CFBundleName": "Partial", "CFBundleURLTypes": [42]]
        )

        XCTAssertEqual(record.displayName, "Partial")
        XCTAssertEqual(record.urlSchemes, [])
        XCTAssertEqual(record.warnings.count, 1)
    }

    func testMapsDocumentRolesCaseInsensitively() throws {
        let record = try parser.parse(
            applicationURL: appURL,
            infoDictionary: [
                "CFBundleDocumentTypes": [
                    ["CFBundleTypeRole": "EDITOR"],
                    ["CFBundleTypeRole": "shell"],
                    ["CFBundleTypeRole": "None"]
                ]
            ]
        )

        XCTAssertEqual(record.documentTypeClaims.map(\.role), [.editor, .shell, []])
    }

    func testRepeatedSchemesHaveUniqueSortedIdentitiesAndDeterministicNames() throws {
        let record = try parser.parse(applicationURL: appURL, infoDictionary: repeatedDeclarationFixture())
        let reordered = try parser.parse(applicationURL: appURL, infoDictionary: repeatedDeclarationFixture(reversed: true))

        XCTAssertEqual(record.urlSchemes.map(\.id), ["sample", "x-xcode-documentation"])
        XCTAssertEqual(record.urlSchemes.last?.name, "Documentation")
        XCTAssertEqual(record.urlSchemes, reordered.urlSchemes)
    }

    func testInvalidSchemeSyntaxIsSkippedWithWarnings() throws {
        let record = try parser.parse(applicationURL: appURL, infoDictionary: [
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["sample", "mαilto", "K-mail"]]],
        ])
        XCTAssertEqual(record.urlSchemes.map(\.id), ["sample"])
        XCTAssertEqual(record.warnings.count, 2)
        XCTAssertTrue(record.warnings.allSatisfy { $0.contains("CFBundleURLTypes") })
    }

    func testInvalidContentTypeSyntaxIsSkippedInDeclarationsClaimsAndConformance() throws {
        for invalid in ["bad_type", "public/text", "public:text", "*", "public..text"] {
            let record = try parser.parse(applicationURL: appURL, infoDictionary: [
                "CFBundleDocumentTypes": [["LSItemContentTypes": [invalid, "public.text"]]],
                "UTExportedTypeDeclarations": [["UTTypeIdentifier": invalid]],
                "UTImportedTypeDeclarations": [
                    ["UTTypeIdentifier": invalid],
                    ["UTTypeIdentifier": "com.example.valid", "UTTypeConformsTo": [invalid, "public.data"]],
                ],
            ])
            XCTAssertEqual(record.documentTypeClaims.first?.contentTypeIdentifiers, ["public.text"], invalid)
            XCTAssertTrue(record.exportedTypeDeclarations.isEmpty, invalid)
            XCTAssertEqual(record.importedTypeDeclarations.map(\.id), ["com.example.valid"], invalid)
            XCTAssertEqual(record.importedTypeDeclarations.first?.conformanceIdentifiers, ["public.data"], invalid)
            XCTAssertEqual(record.warnings.count, 4, invalid)
            XCTAssertTrue(record.warnings.contains { $0.contains("LSItemContentTypes") }, invalid)
            XCTAssertTrue(record.warnings.contains { $0.contains("UTTypeConformsTo") }, invalid)
            XCTAssertTrue(record.warnings.contains { $0.contains("UTExportedTypeDeclarations") }, invalid)
            XCTAssertTrue(record.warnings.contains { $0.contains("UTImportedTypeDeclarations") }, invalid)
        }
    }

    func testRepeatedContentTypesMergeMetadataWithinEachProvenance() throws {
        let record = try parser.parse(applicationURL: appURL, infoDictionary: repeatedDeclarationFixture())
        let reordered = try parser.parse(applicationURL: appURL, infoDictionary: repeatedDeclarationFixture(reversed: true))

        XCTAssertEqual(record.importedTypeDeclarations.map(\.id), ["com.apple.font-suitcase", "public.patch-file"])
        XCTAssertEqual(record.exportedTypeDeclarations.map(\.id), ["com.apple.font-suitcase"])
        let imported = try XCTUnwrap(record.importedTypeDeclarations.first)
        XCTAssertEqual(imported.provenance, .imported)
        XCTAssertEqual(imported.typeDescription, "Font suitcase")
        XCTAssertEqual(imported.declaringBundleIdentifier, "test.declarations")
        XCTAssertEqual(imported.tags, [
            "public.filename-extension": ["dfont", "suit"],
            "public.mime-type": ["application/x-font", "font/sfnt"],
            "com.apple.ostype": ["FFIL"],
        ])
        XCTAssertEqual(imported.conformanceIdentifiers, ["public.data", "public.font"])
        XCTAssertEqual(record.importedTypeDeclarations.last?.tags, ["public.filename-extension": ["diff", "patch"]])
        let exported = try XCTUnwrap(record.exportedTypeDeclarations.first)
        XCTAssertEqual(exported.provenance, .exported)
        XCTAssertEqual(exported.typeDescription, "Exported font")
        XCTAssertEqual(exported.tags, ["public.filename-extension": ["export-one", "export-two"]])
        XCTAssertEqual(exported.conformanceIdentifiers, ["public.content", "public.item"])
        XCTAssertEqual(record.importedTypeDeclarations, reordered.importedTypeDeclarations)
        XCTAssertEqual(record.exportedTypeDeclarations, reordered.exportedTypeDeclarations)
        XCTAssertTrue(record.warnings.isEmpty)
    }
}

/// Reduced examples of repeated Font Book/TextMate UTIs and Xcode schemes, with
/// deliberately different metadata to catch dropping a duplicate instead of merging it.
func repeatedDeclarationFixture(reversed: Bool = false) -> [String: Any] {
    let schemes: [[String: Any]] = [
        ["CFBundleURLSchemes": ["X-XCODE-DOCUMENTATION", "sample"], "CFBundleURLName": "Xcode"],
        ["CFBundleURLSchemes": ["x-xcode-documentation"], "CFBundleURLName": "Documentation"],
        ["CFBundleURLSchemes": ["x-xcode-documentation"]],
    ]
    let imported: [[String: Any]] = [
        ["UTTypeIdentifier": "COM.APPLE.FONT-SUITCASE", "UTTypeDescription": "Suitcase",
         "UTTypeConformsTo": ["public.font", "public.data"],
         "UTTypeTagSpecification": ["public.filename-extension": ["suit", "suit"], "public.mime-type": "font/sfnt"]],
        ["UTTypeIdentifier": "com.apple.font-suitcase", "UTTypeDescription": "Font suitcase",
         "UTTypeConformsTo": "PUBLIC.DATA",
         "UTTypeTagSpecification": ["public.filename-extension": ["dfont", "suit"], "public.mime-type": "application/x-font"]],
        ["UTTypeIdentifier": "com.apple.font-suitcase", "UTTypeTagSpecification": ["com.apple.ostype": "FFIL"]],
        ["UTTypeIdentifier": "public.patch-file", "UTTypeTagSpecification": ["public.filename-extension": "patch"]],
        ["UTTypeIdentifier": "PUBLIC.PATCH-FILE", "UTTypeTagSpecification": ["public.filename-extension": "diff"]],
    ]
    let exported: [[String: Any]] = [
        ["UTTypeIdentifier": "com.apple.font-suitcase", "UTTypeDescription": "Exported font",
         "UTTypeConformsTo": "public.item", "UTTypeTagSpecification": ["public.filename-extension": "export-two"]],
        ["UTTypeIdentifier": "COM.APPLE.FONT-SUITCASE", "UTTypeConformsTo": "public.content",
         "UTTypeTagSpecification": ["public.filename-extension": "export-one"]],
    ]
    return [
        "CFBundleIdentifier": "test.declarations",
        "CFBundleURLTypes": reversed ? Array(schemes.reversed()) : schemes,
        "UTImportedTypeDeclarations": reversed ? Array(imported.reversed()) : imported,
        "UTExportedTypeDeclarations": reversed ? Array(exported.reversed()) : exported,
    ]
}
