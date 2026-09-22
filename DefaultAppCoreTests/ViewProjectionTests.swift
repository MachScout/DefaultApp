import XCTest
@testable import DefaultAppCore

final class ViewProjectionTests: XCTestCase {
    private let mail = ApplicationRecord(
        url: URL(fileURLWithPath: "/Applications/Mail.app"),
        bundleIdentifier: "com.example.postbox", displayName: "Postbox"
    )

    func testSchemeSearchMatchesIdentifierAndResolvedDefaultIdentity() throws {
        let snapshot = CatalogSnapshot(urlSchemes: [
            URLSchemeRecord(identifier: "https"), URLSchemeRecord(identifier: "mailto"),
        ])
        let defaults: [Association: DefaultHandlerState] = [try .urlScheme("mailto"): .application(mail)]
        for query in [" MAIL ", "postbox", "com.example.postbox"] {
            let rows = AssociationProjection.schemeRows(from: snapshot, defaults: defaults, search: query)
            XCTAssertEqual(rows.map(\.identifier), ["mailto"])
        }
    }

    func testRegisteredHandlerDoesNotMasqueradeAsDefault() {
        let snapshot = CatalogSnapshot(urlSchemes: [
            URLSchemeRecord(identifier: "mailto", handlerApplications: [mail.reference]),
        ])
        let rows = AssociationProjection.schemeRows(from: snapshot, search: "")
        XCTAssertEqual(rows.first?.defaultHandler, .notLoaded)
        XCTAssertTrue(AssociationProjection.schemeRows(from: snapshot, search: "Postbox").isEmpty)
    }

    func testTypeSearchMatchesMetadataAndKeepsStableIdentifier() throws {
        let snapshot = CatalogSnapshot(contentTypes: [
            ContentTypeRecord(identifier: "public.text", localizedDescription: "Plain text",
                              tags: ["public.filename-extension": ["txt"]]),
            ContentTypeRecord(identifier: "public.json"),
        ])
        let rows = AssociationProjection.typeRows(from: snapshot, search: "TXT")
        XCTAssertEqual(rows.map(\.identifier), ["public.text"])
        XCTAssertEqual(rows.first?.id, try Association.contentType("public.text"))
    }

    func testExtensionsAreVisibleAndSearchableWithLeadingDot() {
        let snapshot = CatalogSnapshot(contentTypes: [
            ContentTypeRecord(identifier: "public.plain-text", tags: ["public.filename-extension": ["txt", "text", "txt"]]),
        ])
        let rows = AssociationProjection.typeRows(from: snapshot, search: ".TXT")
        XCTAssertEqual(rows.first?.filenameExtensions, ["text", "txt"])
    }

    func testOnlyDynamicFilterUsesSystemClassification() {
        let snapshot = CatalogSnapshot(contentTypes: [
            ContentTypeRecord(identifier: "public.text", isFileType: true, isDynamic: false),
            ContentTypeRecord(identifier: "dyn.ah62d4rv4ge", tags: ["public.filename-extension": ["examplexyz"]],
                              isFileType: true, isDynamic: true),
        ])
        let rows = AssociationListIndex(snapshot: snapshot, kind: .contentType)
            .rows(defaults: [:], search: "", filters: .init(onlyDynamic: true))
        XCTAssertEqual(rows.map(\.identifier), ["dyn.ah62d4rv4ge"])
        XCTAssertEqual(rows.first?.filenameExtensions, ["examplexyz"])
    }

    func testContentTypeFiltersHideRowsWithoutExtensionsOrResolvedDefaults() throws {
        let text = try Association.contentType("public.text")
        let data = try Association.contentType("public.data")
        let image = try Association.contentType("public.image")
        let snapshot = CatalogSnapshot(contentTypes: [
            ContentTypeRecord(identifier: text.identifier,
                              tags: ["public.filename-extension": ["txt"]]),
            ContentTypeRecord(identifier: data.identifier),
            ContentTypeRecord(identifier: image.identifier,
                              tags: ["public.filename-extension": ["png"]]),
        ])
        let index = AssociationListIndex(snapshot: snapshot, kind: .contentType)
        let defaults: [Association: DefaultHandlerState] = [
            text: .application(mail),
            data: .application(mail),
            image: .none,
        ]

        XCTAssertEqual(
            index.rows(defaults: defaults, search: "",
                       filters: .init(hideWithoutExtensions: true)).map(\.identifier),
            ["public.image", "public.text"]
        )
        XCTAssertEqual(
            index.rows(defaults: defaults, search: "",
                       filters: .init(hideWithoutDefaultApplication: true)).map(\.identifier),
            ["public.data", "public.text"]
        )
        XCTAssertEqual(
            index.rows(defaults: defaults, search: "",
                       filters: .init(hideWithoutExtensions: true,
                                      hideWithoutDefaultApplication: true)).map(\.identifier),
            ["public.text"]
        )
    }

    func testAssociationRowsSortByEveryVisibleColumnInBothDirections() throws {
        let alpha = ApplicationRecord(url: mail.url, displayName: "Alpha")
        let zulu = ApplicationRecord(url: mail.url, displayName: "Zulu")
        let snapshot = CatalogSnapshot(contentTypes: [
            ContentTypeRecord(identifier: "type.c",
                              tags: ["public.filename-extension": ["aaa"]]),
            ContentTypeRecord(identifier: "type.a",
                              tags: ["public.filename-extension": ["zzz"]]),
            ContentTypeRecord(identifier: "type.b",
                              tags: ["public.filename-extension": ["mmm"]]),
        ])
        let defaults: [Association: DefaultHandlerState] = [
            try .contentType("type.c"): .application(zulu),
            try .contentType("type.a"): .application(alpha),
            try .contentType("type.b"): .none,
        ]
        let index = AssociationListIndex(snapshot: snapshot, kind: .contentType)

        XCTAssertEqual(index.rows(defaults: defaults, search: "",
                                  sort: .init(column: .identifier)).map(\.identifier),
                       ["type.a", "type.b", "type.c"])
        XCTAssertEqual(index.rows(defaults: defaults, search: "",
                                  sort: .init(column: .filenameExtensions)).map(\.identifier),
                       ["type.c", "type.b", "type.a"])
        XCTAssertEqual(index.rows(defaults: defaults, search: "",
                                  sort: .init(column: .defaultApplication)).map(\.identifier),
                       ["type.a", "type.b", "type.c"])
        XCTAssertEqual(index.rows(defaults: defaults, search: "",
                                  sort: .init(column: .defaultApplication,
                                              ascending: false)).map(\.identifier),
                       ["type.c", "type.b", "type.a"])
    }

    func testApplicationFiltersClassifyPathsWithoutHidingRealUtilities() {
        func record(_ path: String) -> ApplicationRecord {
            ApplicationRecord(url: URL(fileURLWithPath: path), displayName: "App")
        }
        for path in ["/System/Library/PrivateFrameworks/Chinese.framework/CIMFindInputCodeTool.app",
                     "/System/Library/Input Methods/TCIM.app",
                     "/Applications/Foo.app/Contents/Helpers/Helper.app", "/Library/Services/Test.service",
                     "/Applications/Xcode.app/Contents/Applications/Instruments.app/Contents/Helpers/Worker.app"] {
            XCTAssertNotNil(ApplicationVisibility(record: record(path)).auxiliaryReason, path)
        }
        for path in ["/Applications/Foo.app", "/System/Applications/Mail.app",
                     "/System/Library/CoreServices/Finder.app",
                     "/System/Library/CoreServices/Applications/Archive Utility.app",
                     "/Applications/Xcode.app/Contents/Applications/Instruments.app",
                     "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"] {
            XCTAssertNil(ApplicationVisibility(record: record(path)).auxiliaryReason, path)
        }
        for path in ["/tmp/Foo.app", "/private/var/folders/ab/cd/T/Foo.app",
                     "/Users/me/Library/Developer/Xcode/DerivedData/Foo/Build/Products/Debug/Foo.app",
                     "/Users/me/project/build/Debug/Foo.app"] {
            XCTAssertNotNil(ApplicationVisibility(record: record(path)).developmentReason, path)
        }
        XCTAssertNil(ApplicationVisibility(record: record("/Applications/Debug Tools.app")).developmentReason)
        XCTAssertNil(ApplicationVisibility(record: record("/tmp-apps/Foo.app")).developmentReason)
    }

    func testEmptyAssociationFilterKeepsExtensionOnlyAndDeclarationOnlyApplications() {
        let empty = ApplicationRecord(url: mail.url, displayName: "Empty")
        let extensionOnly = ApplicationRecord(url: mail.url, displayName: "Extensions",
            documentTypeClaims: [.init(filenameExtensions: ["txt"])])
        let declarationOnly = ApplicationRecord(url: mail.url, displayName: "Declarations",
            importedTypeDeclarations: [.init(identifier: "public.text", provenance: .imported)])
        XCTAssertTrue(ApplicationVisibility(record: empty).hasNoAssociations)
        XCTAssertFalse(ApplicationVisibility(record: extensionOnly).hasNoAssociations)
        XCTAssertFalse(ApplicationVisibility(record: declarationOnly).hasNoAssociations)
        let snapshot = CatalogSnapshot(applications: [empty, extensionOnly, declarationOnly])
        XCTAssertEqual(ApplicationProjection.records(from: snapshot, search: "",
            filters: .init(hideAuxiliary: false, hideDevelopment: false, hideWithoutAssociations: true)).map(\.displayName),
            ["Extensions", "Declarations"])
    }

    func testFailedAndMissingDefaultsHaveDifferentPresentation() {
        XCTAssertNotEqual(DefaultHandlerState.none.label, DefaultHandlerState.notLoaded.label)
        XCTAssertEqual(DefaultHandlerState.failed("Cannot query").errorMessage, "Cannot query")
        XCTAssertNil(DefaultHandlerState.none.errorMessage)
    }

    func testApplicationProjectionKeepsHandledImportedAndExportedTypesSeparate() {
        let record = ApplicationRecord(
            url: mail.url, displayName: "Sample",
            documentTypeClaims: [
                DocumentTypeClaim(contentTypeIdentifiers: ["public.text"], role: .viewer),
                DocumentTypeClaim(contentTypeIdentifiers: ["public.text"], role: .editor),
            ],
            exportedTypeDeclarations: [.init(identifier: "com.example.document", provenance: .exported)],
            importedTypeDeclarations: [.init(identifier: "public.json", provenance: .imported)]
        )
        let projection = ApplicationProjection(record: record)
        XCTAssertEqual(projection.handledTypes.map(\.identifier), ["public.text"])
        XCTAssertEqual(projection.handledTypes.first?.role, [.viewer, .editor])
        XCTAssertEqual(projection.exportedTypes.map(\.identifier), ["com.example.document"])
        XCTAssertEqual(projection.importedTypes.map(\.identifier), ["public.json"])
    }

    func testHandledTypeProjectionMergesAndFormatsExtensionsAcrossRepeatedClaims() throws {
        let record = ApplicationRecord(
            url: mail.url, displayName: "Archive Tool",
            documentTypeClaims: [
                DocumentTypeClaim(contentTypeIdentifiers: ["public.archive"],
                                  filenameExtensions: ["zip"], role: .viewer),
                DocumentTypeClaim(contentTypeIdentifiers: ["public.archive"],
                                  filenameExtensions: ["jar", "zip"], role: .editor),
                DocumentTypeClaim(contentTypeIdentifiers: ["public.data"], role: .viewer),
            ]
        )

        let handledTypes = ApplicationProjection(record: record).handledTypes
        let archive = try XCTUnwrap(handledTypes.first { $0.identifier == "public.archive" })
        let data = try XCTUnwrap(handledTypes.first { $0.identifier == "public.data" })

        XCTAssertEqual(archive.filenameExtensions, ["jar", "zip"])
        XCTAssertEqual(archive.filenameExtensionLabel, ".jar, .zip")
        XCTAssertNil(data.filenameExtensionLabel)
    }

    func testHandledTypeProjectionUsesExtensionsFromMatchingTypeDeclaration() throws {
        let record = ApplicationRecord(
            url: mail.url, displayName: "Image Viewer",
            documentTypeClaims: [
                DocumentTypeClaim(contentTypeIdentifiers: ["public.jpeg"], role: .viewer),
            ],
            importedTypeDeclarations: [
                ContentTypeDeclaration(
                    identifier: "public.jpeg",
                    provenance: .imported,
                    tags: ["public.filename-extension": ["jpeg", "jpg"]]
                ),
            ]
        )

        let type = try XCTUnwrap(ApplicationProjection(record: record).handledTypes.first)

        XCTAssertEqual(type.filenameExtensionLabel, ".jpeg, .jpg")
    }

    func testApplicationProjectionUsesCatalogExtensionsForDeclaredAndAdditionalTypes() throws {
        let record = ApplicationRecord(
            url: mail.url, displayName: "Image Viewer",
            documentTypeClaims: [
                DocumentTypeClaim(contentTypeIdentifiers: ["public.jpeg"], role: .viewer),
            ]
        )
        let catalogTypes = [
            ContentTypeRecord(
                identifier: "public.jpeg",
                tags: ["public.filename-extension": ["jpeg", "jpg"]]
            ),
            ContentTypeRecord(
                identifier: "public.png",
                tags: ["public.filename-extension": ["png"]]
            ),
        ]

        let projection = ApplicationProjection(record: record, contentTypes: catalogTypes)

        XCTAssertEqual(projection.handledTypes.first?.filenameExtensionLabel, ".jpeg, .jpg")
        XCTAssertEqual(projection.filenameExtensionLabel(for: "public.png"), ".png")
    }

    func testApplicationSearchMatchesPathAndBundleIdentifier() {
        let snapshot = CatalogSnapshot(applications: [mail])
        XCTAssertEqual(ApplicationProjection.records(from: snapshot, search: "MAIL.APP"), [mail])
        XCTAssertEqual(ApplicationProjection.records(from: snapshot, search: "com.example"), [mail])
        XCTAssertTrue(ApplicationProjection.records(from: snapshot, search: "missing").isEmpty)
    }

    func testParsedApplicationDeclarationsHaveUniqueForEachIdentities() throws {
        let record = try BundleDeclarationParser().parse(
            applicationURL: mail.url, infoDictionary: repeatedDeclarationFixture()
        )
        let projection = ApplicationProjection(record: record)

        XCTAssertEqual(record.urlSchemes.count, Set(record.urlSchemes.map(\.id)).count)
        XCTAssertEqual(projection.importedTypes.count, Set(projection.importedTypes.map(\.id)).count)
        XCTAssertEqual(projection.exportedTypes.count, Set(projection.exportedTypes.map(\.id)).count)
        XCTAssertEqual(projection.importedTypes.map(\.identifier), ["com.apple.font-suitcase", "public.patch-file"])
        XCTAssertEqual(projection.exportedTypes.map(\.identifier), ["com.apple.font-suitcase"])
    }

    func testRoleAvailabilityIsLimitedToLegacyContentTypes() throws {
        XCTAssertTrue(AssociationProjection.showsRoles(for: try .contentType("public.text"), backend: .legacy))
        XCTAssertFalse(AssociationProjection.showsRoles(for: try .contentType("public.text"), backend: .modern))
        XCTAssertFalse(AssociationProjection.showsRoles(for: try .urlScheme("mailto"), backend: .legacy))
    }

    func testDiagnosticsDistinguishesUnknownStatusAndPreservesWarnings() {
        let snapshot = CatalogSnapshot(diagnostics: SPIDiagnostics(
            applicationCallStatus: 0, schemeCallStatus: -50, applicationCount: 42,
            warnings: ["An unreadable bundle"], expectedSymbolNames: ["_LSCopyAllApplicationURLs"]
        ))
        let projection = DiagnosticsProjection(snapshot: snapshot, backend: .legacy,
                                               osVersion: "Test OS", refreshDuration: 1.25)
        XCTAssertTrue(projection.text.contains("Test OS"))
        XCTAssertTrue(projection.text.contains("Legacy"))
        XCTAssertTrue(projection.text.contains("42"))
        XCTAssertTrue(projection.text.contains("-50"))
        XCTAssertTrue(projection.text.contains("Not reported"))
        XCTAssertTrue(projection.text.contains("1.25 s"))
        XCTAssertTrue(projection.text.contains("_LSCopyAllApplicationURLs"))
        XCTAssertTrue(projection.text.contains("An unreadable bundle"))
    }
}
