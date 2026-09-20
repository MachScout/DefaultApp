import Foundation
import XCTest
@testable import DefaultAppCore

final class ApplicationCatalogTests: XCTestCase, @unchecked Sendable {
    private let mailURL = URL(fileURLWithPath: "/Applications/Mail.app")
    private let sampleURL = URL(fileURLWithPath: "/Applications/Sample.app")

    func testCatalogMergesDirectoryURLSpellingsAcrossApplicationsAndSchemeHandlers() async throws {
        let directory = URL(fileURLWithPath: "/Fixture/Reader.app", isDirectory: true)
        let alternate = URL(fileURLWithPath: "/Fixture/Reader.app", isDirectory: false)
        let spi = FakeSPI(applications: [directory, alternate], schemeHandlers: [("reader", alternate), ("reader", directory)])
        let catalog = ApplicationCatalog(spi: spi, infoDictionary: { _ in
            ["CFBundleIdentifier": "test.reader", "CFBundleURLTypes": [["CFBundleURLSchemes": ["reader"]]]]
        })
        let snapshot = try await catalog.loadCatalog()
        XCTAssertEqual(snapshot.applications.count, 1)
        XCTAssertEqual(snapshot.applications.first?.url, directory)
        let scheme = try XCTUnwrap(snapshot.urlSchemes.first)
        XCTAssertEqual(scheme.handlerApplications.count, 1)
        XCTAssertEqual(scheme.declaringApplications.count, 1)
        XCTAssertEqual(scheme.handlerApplications, scheme.declaringApplications)
        XCTAssertEqual(scheme.handlerApplications.first?.id, "file:///Fixture/Reader.app")
        XCTAssertEqual(snapshot.diagnostics.applicationCount, 2)
        XCTAssertEqual(snapshot.diagnostics.schemeCount, 2)
    }

    func testCatalogDeduplicatesURLsAndMergesPrivateAndBundleSchemes() async throws {
        let spi = FakeSPI(
            applications: [sampleURL, URL(fileURLWithPath: "/Applications/Other/../Sample.app")],
            schemeHandlers: [("MAILTO:", mailURL), ("sample", sampleURL), ("sample", sampleURL)],
            typeIdentifiers: ["public.text", " PUBLIC.TEXT "]
        )
        let sampleURL = sampleURL
        let catalog = ApplicationCatalog(spi: spi, infoDictionary: { url in
            url == sampleURL ? [
                "CFBundleIdentifier": "test.sample",
                "CFBundleURLTypes": [["CFBundleURLSchemes": ["sample", "sample-secure"]]]
            ] : ["CFBundleIdentifier": "test.mail"]
        })
        let snapshot = try await catalog.loadCatalog()
        XCTAssertEqual(snapshot.applications.map(\.url), [mailURL, sampleURL])
        XCTAssertEqual(snapshot.urlSchemes.map(\.identifier), ["mailto", "sample", "sample-secure"])
        XCTAssertEqual(snapshot.contentTypes.map(\.identifier), ["public.text"])
        XCTAssertEqual(snapshot.urlSchemes[1].handlerApplications, [ApplicationReference(url: sampleURL, bundleIdentifier: "test.sample")])
        XCTAssertEqual(snapshot.urlSchemes[1].declaringApplications, snapshot.urlSchemes[1].handlerApplications)
        XCTAssertTrue(snapshot.urlSchemes[2].handlerApplications.isEmpty)
        XCTAssertEqual(snapshot.urlSchemes[2].declaringApplications.map(\.url), [sampleURL])
        XCTAssertEqual(snapshot.diagnostics.applicationCount, 2)
        XCTAssertEqual(snapshot.diagnostics.schemeCount, 3)
        XCTAssertEqual(snapshot.diagnostics.contentTypeCount, 2)
    }

    func testUnreadableBundlePreservesPartialRecordAndOtherDeclarations() async throws {
        let mailURL = mailURL
        let catalog = ApplicationCatalog(spi: FakeSPI(applications: [sampleURL, mailURL]), infoDictionary: { url in
            if url == mailURL { throw DefaultAppError.unreadableBundleMetadata(url: url) }
            return ["CFBundleURLTypes": [["CFBundleURLSchemes": ["sample", "bad scheme"]]]]
        })
        let snapshot = try await catalog.loadCatalog()
        XCTAssertEqual(snapshot.applications.map(\.displayName), ["Mail", "Sample"])
        XCTAssertNil(snapshot.applications[0].bundleIdentifier)
        XCTAssertEqual(snapshot.applications[0].warnings.count, 1)
        XCTAssertEqual(snapshot.urlSchemes.map(\.identifier), ["sample"])
        XCTAssertEqual(snapshot.diagnostics.warnings.count, 2)
    }

    func testBundleTypesAndClaimsMergeWithSystemIdentifiers() async throws {
        let catalog = ApplicationCatalog(spi: FakeSPI(applications: [sampleURL], typeIdentifiers: ["public.text"]), infoDictionary: { _ in
            [
                "CFBundleIdentifier": "test.sample",
                "CFBundleDocumentTypes": [["LSItemContentTypes": ["test.claim"]]],
                "UTExportedTypeDeclarations": [[
                    "UTTypeIdentifier": "test.exported",
                    "UTTypeDescription": "Sample document",
                    "UTTypeConformsTo": ["public.data"],
                    "UTTypeTagSpecification": ["public.filename-extension": ["sample"]]
                ]],
                "UTImportedTypeDeclarations": [["UTTypeIdentifier": "test.imported"]]
            ]
        })
        let snapshot = try await catalog.loadCatalog()
        XCTAssertEqual(snapshot.contentTypes.map(\.identifier), ["public.text", "test.claim", "test.exported", "test.imported"])
        let exported = try XCTUnwrap(snapshot.contentTypes.first { $0.identifier == "test.exported" })
        XCTAssertEqual(exported.localizedDescription, "Sample document")
        XCTAssertEqual(exported.tags["public.filename-extension"], ["sample"])
        XCTAssertEqual(exported.supertypes, ["public.data"])
        XCTAssertEqual(exported.declaringApplication?.url, sampleURL)
        XCTAssertNotNil(snapshot.contentTypes[0].localizedDescription)
    }

    func testCacheRetainsSnapshotUntilRefreshOrInvalidation() async throws {
        let metadata = MutableMetadata()
        let catalog = ApplicationCatalog(spi: FakeSPI(applications: [sampleURL]), infoDictionary: { _ in metadata.read() })
        let first = try await catalog.loadCatalog()
        metadata.setName("Changed")
        let cached = try await catalog.loadCatalog()
        XCTAssertEqual(cached, first)
        let refreshed = try await catalog.loadCatalog(forceRefresh: true)
        XCTAssertEqual(refreshed.applications.first?.displayName, "Changed")
        metadata.setName("Invalidated")
        await catalog.invalidate()
        let invalidated = try await catalog.loadCatalog()
        XCTAssertEqual(invalidated.applications.first?.displayName, "Invalidated")
    }

    func testRefreshReusesUnchangedBundleAndSelectedRefreshReadsOnlyChangedBundle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First.app")
        let second = root.appendingPathComponent("Second.app")
        for url in [first, second] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try Data("initial".utf8).write(to: url.appendingPathComponent("Contents/Info.plist"))
        }
        let metadata = MutableMetadata()
        let spi = CountingSPI(base: FakeSPI(applications: [first, second]))
        let catalog = ApplicationCatalog(spi: spi, infoDictionary: { _ in metadata.read() })
        let initial = try await catalog.loadCatalog()
        XCTAssertEqual(metadata.readCount, 2)
        let refreshed = try await catalog.loadCatalog(forceRefresh: true)
        XCTAssertEqual(refreshed, initial)
        XCTAssertEqual(metadata.readCount, 2, "Unchanged plists must not be parsed again")
        let discoveries = spi.callCount
        metadata.setName("Changed")
        try Data("changed metadata".utf8).write(to: first.appendingPathComponent("Contents/Info.plist"), options: .atomic)
        let selected = try await catalog.refreshApplication(at: first)
        XCTAssertEqual(selected.applications.first { $0.id == ApplicationReference(url: first).id }?.displayName, "Changed")
        XCTAssertEqual(selected.applications.first { $0.id == ApplicationReference(url: second).id }?.displayName, "Initial")
        XCTAssertEqual(metadata.readCount, 3)
        XCTAssertEqual(spi.callCount, discoveries, "Selecting a bundle must not rediscover all registrations")
        _ = try await catalog.refreshContentType("public.text")
        XCTAssertEqual(spi.callCount, discoveries)
        XCTAssertEqual(metadata.readCount, 3)
    }

    func testSelectedBundleRefreshUpdatesAndRemovesItsDeclarations() async throws {
        let metadata = MutableMetadata()
        let catalog = ApplicationCatalog(spi: FakeSPI(applications: [sampleURL]), infoDictionary: { _ in
            let name = metadata.read()["CFBundleName"] as! String
            return ["CFBundleName": name,
                    "CFBundleURLTypes": [["CFBundleURLSchemes": [name.lowercased()]]],
                    "UTExportedTypeDeclarations": [["UTTypeIdentifier": "test." + name.lowercased()]]]
        })
        _ = try await catalog.loadCatalog()
        metadata.setName("Changed")
        let result = try await catalog.refreshApplication(at: sampleURL)
        XCTAssertEqual(result.urlSchemes.map(\.identifier), ["changed"])
        XCTAssertEqual(result.contentTypes.map(\.identifier), ["test.changed"])
        let cached = try await catalog.loadCatalog()
        XCTAssertEqual(cached, result)
    }

    func testCatalogClassifiesFileTypesSeparatelyFromHardwareAndUnknownDeclarations() async throws {
        let catalog = ApplicationCatalog(spi: FakeSPI(typeIdentifiers: ["public.text", "public.directory", "public.device", "test.defaultapp.unknown"]))
        let snapshot = try await catalog.loadCatalog()
        let classifications = Dictionary(uniqueKeysWithValues: snapshot.contentTypes.map { ($0.identifier, $0.isFileType) })
        XCTAssertEqual(classifications["public.text"], true)
        XCTAssertEqual(classifications["public.directory"], true)
        XCTAssertEqual(classifications["public.device"], false)
        XCTAssertEqual(classifications["test.defaultapp.unknown"], false)
    }

    func testSPIFailureIsPropagated() async {
        let error = DefaultAppError.privateSPIFailure(symbol: "_LSCopyAllApplicationURLs", status: -50)
        let catalog = ApplicationCatalog(spi: FakeSPI(failure: error))
        await XCTAssertThrowsErrorAsync({ try await catalog.loadCatalog() }) {
            XCTAssertEqual($0 as? DefaultAppError, error)
        }
    }

    func testMismatchedSchemeArraysBecomeDiagnosticFailure() async {
        let catalog = ApplicationCatalog(spi: FakeSPI(rawSchemes: ["mailto", "http"], rawHandlerURLs: [mailURL]))
        await XCTAssertThrowsErrorAsync({ try await catalog.loadCatalog() }) {
            XCTAssertEqual($0 as? DefaultAppError, .malformedSPIPayload(symbol: "_LSCopySchemesAndHandlerURLs"))
        }
    }

    func testWildcardRegistrationRemainsAnApplicationButNotAConcreteScheme() async throws {
        let pairs = try SilgenLaunchServicesSPI.schemePairs(schemes: ["*", "mailto"], handlerURLs: [sampleURL, mailURL], status: 0)
        let catalog = ApplicationCatalog(spi: FakeSPI(schemeHandlers: pairs), infoDictionary: { _ in [:] })
        let snapshot = try await catalog.loadCatalog()
        XCTAssertEqual(snapshot.applications.map(\.url), [mailURL, sampleURL])
        XCTAssertEqual(snapshot.urlSchemes.map(\.identifier), ["mailto"])
        XCTAssertEqual(snapshot.diagnostics.schemeCount, 2)
        XCTAssertEqual(snapshot.diagnostics.warnings.count, 1)
    }

    func testBridgeRejectsMissingWrongTypeAndNonFilePayloads() throws {
        for payload: NSArray? in [nil, ["/Applications/Mail.app"], [URL(string: "https://example.com/app")!], [1]] {
            XCTAssertThrowsError(try SilgenLaunchServicesSPI.applicationURLs(from: payload, status: 0)) {
                XCTAssertEqual($0 as? DefaultAppError, .malformedSPIPayload(symbol: "_LSCopyAllApplicationURLs"))
            }
        }
        for payload: NSArray? in [nil, [1], ["bad type"]] {
            XCTAssertThrowsError(try SilgenLaunchServicesSPI.typeIdentifiers(from: payload)) {
                XCTAssertEqual($0 as? DefaultAppError, .malformedSPIPayload(symbol: "_UTCopyDeclaredTypeIdentifiers"))
            }
        }
        for (schemes, urls): (NSArray?, NSArray?) in [(nil, []), ([], nil), ([1], [mailURL]), (["mailto"], ["invalid"]), (["bad scheme"], [mailURL])] {
            XCTAssertThrowsError(try SilgenLaunchServicesSPI.schemePairs(schemes: schemes, handlerURLs: urls, status: 0)) {
                XCTAssertEqual($0 as? DefaultAppError, .malformedSPIPayload(symbol: "_LSCopySchemesAndHandlerURLs"))
            }
        }
        XCTAssertThrowsError(try SilgenLaunchServicesSPI.applicationURLs(from: nil, status: -50)) {
            XCTAssertEqual($0 as? DefaultAppError, .privateSPIFailure(symbol: "_LSCopyAllApplicationURLs", status: -50))
        }
        XCTAssertThrowsError(try SilgenLaunchServicesSPI.schemePairs(schemes: nil, handlerURLs: nil, status: -50)) {
            XCTAssertEqual($0 as? DefaultAppError, .privateSPIFailure(symbol: "_LSCopySchemesAndHandlerURLs", status: -50))
        }
    }

    func testBridgeAcceptsEmptyArraysAndNormalizesValidPayloads() throws {
        XCTAssertEqual(try SilgenLaunchServicesSPI.applicationURLs(from: [], status: 0), [])
        XCTAssertEqual(try SilgenLaunchServicesSPI.typeIdentifiers(from: []), [])
        XCTAssertTrue(try SilgenLaunchServicesSPI.schemePairs(schemes: [], handlerURLs: [], status: 0).isEmpty)
        XCTAssertEqual(try SilgenLaunchServicesSPI.applicationURLs(from: [sampleURL], status: 0), [sampleURL])
        XCTAssertEqual(try SilgenLaunchServicesSPI.typeIdentifiers(from: [" PUBLIC.TEXT "]), ["public.text"])
        let pairs = try SilgenLaunchServicesSPI.schemePairs(schemes: ["MAILTO:"], handlerURLs: [mailURL], status: 0)
        XCTAssertEqual(pairs.first?.scheme, "mailto")
        XCTAssertEqual(pairs.first?.handlerURL, mailURL)
    }
}

private struct FakeSPI: PrivateLaunchServicesProviding {
    var applications: [URL] = []
    var schemeHandlers: [(scheme: String, handlerURL: URL)] = []
    var typeIdentifiers: [String] = []
    var failure: DefaultAppError?
    var rawSchemes: [String]?
    var rawHandlerURLs: [URL]?

    func applicationURLs() throws -> [URL] {
        if let failure { throw failure }
        return applications
    }
    func schemesAndHandlerURLs() throws -> [(scheme: String, handlerURL: URL)] {
        if let rawSchemes, let rawHandlerURLs {
            // Exercise the production decoder; the fake does not implement parallel-array validation.
            return try SilgenLaunchServicesSPI.schemePairs(schemes: NSArray(array: rawSchemes), handlerURLs: NSArray(array: rawHandlerURLs), status: 0)
        }
        return schemeHandlers
    }
    func declaredTypeIdentifiers() throws -> [String] { typeIdentifiers }
}

private final class MutableMetadata: @unchecked Sendable {
    private let lock = NSLock()
    private var name = "Initial"
    private var reads = 0
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func read() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return ["CFBundleName": name]
    }
    func setName(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        name = value
    }
}

// A lock protects only synchronous test instrumentation; production state is actor isolated.
private final class CountingSPI: PrivateLaunchServicesProviding, @unchecked Sendable {
    let base: FakeSPI
    private let lock = NSLock()
    private var calls = 0
    init(base: FakeSPI) { self.base = base }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    private func note() { lock.lock(); defer { lock.unlock() }; calls += 1 }
    func applicationURLs() throws -> [URL] { note(); return try base.applicationURLs() }
    func schemesAndHandlerURLs() throws -> [(scheme: String, handlerURL: URL)] { note(); return try base.schemesAndHandlerURLs() }
    func declaredTypeIdentifiers() throws -> [String] { note(); return try base.declaredTypeIdentifiers() }
}
