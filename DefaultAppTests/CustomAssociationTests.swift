import Foundation
import Testing
@testable import DefaultApp
import DefaultAppCore

struct CustomAssociationTests {
    @Test(arguments: ["My+Scheme", " My+Scheme: ", " My+Scheme:// "])
    func normalizesScheme(_ input: String) throws {
        var draft = NewAssociationDraft(kind: .urlScheme)
        draft.identifier = input
        let record = try draft.validatedRecord()
        #expect(record.association == (try Association.urlScheme("my+scheme")))
        #expect(record.contentTypeRecord == nil)
    }

    @Test(arguments: ["https://example.com", "a b", "1scheme", "file/path"])
    func rejectsFullURLsAndInvalidSchemes(_ input: String) {
        var draft = NewAssociationDraft(kind: .urlScheme)
        draft.identifier = input
        #expect(throws: CustomAssociationValidationError.self) { try draft.validatedRecord() }
    }

    @Test func normalizesFileMetadataAndProjectsCatalogRecord() throws {
        var draft = Self.fileDraft()
        draft.identifier = " ORG.Example.Report "
        draft.name = " Report File "
        draft.filenameExtensions = " .RPT, rpt, .Report "
        draft.mimeType = " Application/X-Report "
        draft.conformsTo = "public.text"
        let record = try draft.validatedRecord()
        #expect(record.association.identifier == "org.example.report")
        #expect(record.name == "Report File")
        #expect(record.filenameExtensions == ["rpt", "report"])
        #expect(record.mimeType == "application/x-report")
        #expect(record.contentTypeRecord?.tags == ["public.filename-extension": ["rpt", "report"], "public.mime-type": ["application/x-report"]])
        #expect(record.contentTypeRecord?.supertypes == ["public.text"])
        #expect(record.contentTypeRecord?.isFileType == true)
    }

    @Test(arguments: ["public.custom", "com.apple.custom", "dyn.custom"])
    func reservedIdentifierCanNavigateButCannotCreate(_ identifier: String) throws {
        var draft = Self.fileDraft()
        draft.identifier = identifier
        #expect(draft.parsedAssociation != nil)
        #expect(throws: CustomAssociationValidationError.self) { try draft.validatedRecord() }
    }

    @Test(arguments: ["report", "org..report", "org.example./report", "org.-example.report"])
    func rejectsNonReverseDomainIdentifiers(_ identifier: String) {
        var draft = Self.fileDraft()
        draft.identifier = identifier
        #expect(throws: CustomAssociationValidationError.self) { try draft.validatedRecord() }
    }

    @Test(arguments: ["", "rpt,", "rpt,,txt", "/rpt", "rpt/path", "*.rpt", "..", "r pt", "rpt\\txt"])
    func rejectsInvalidExtensionTags(_ tags: String) {
        var draft = Self.fileDraft()
        draft.filenameExtensions = tags
        #expect(throws: CustomAssociationValidationError.self) { try draft.validatedRecord() }
    }

    @Test func identifiesInvalidFields() throws {
        var draft = Self.fileDraft()
        draft.name = " "
        do { _ = try draft.validatedRecord(); Issue.record("Missing name was accepted") }
        catch let error as CustomAssociationValidationError { #expect(error.field == .name) }
        draft.name = "Report"
        draft.mimeType = "text/*"
        do { _ = try draft.validatedRecord(); Issue.record("Wildcard MIME was accepted") }
        catch let error as CustomAssociationValidationError { #expect(error.field == .mimeType) }
        draft.mimeType = ""
        draft.conformsTo = "public.image"
        do { _ = try draft.validatedRecord(); Issue.record("Unsupported base was accepted") }
        catch let error as CustomAssociationValidationError { #expect(error.field == .conformsTo) }
    }

    @Test func persistsAndReloadsRecords() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CustomAssociationFileStore(url: directory.appendingPathComponent("records.json"))
        #expect(try await store.load().isEmpty)
        let record = try Self.fileDraft().validatedRecord()
        try await store.save([record])
        #expect(try await store.load() == [record])
    }

    @Test(arguments: ["not json", "[{\"association\":{\"kind\":\"contentType\",\"identifier\":\"public.fake\"},\"name\":\"Fake\",\"filenameExtensions\":[\"fake\"],\"conformsTo\":\"public.data\"}]"])
    func corruptFilesAreNeverOverwritten(_ source: String) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("records.json")
        let data = Data(source.utf8)
        try data.write(to: url)
        let store = CustomAssociationFileStore(url: url)
        await #expect(throws: (any Error).self) { try await store.load() }
        await #expect(throws: (any Error).self) { try await store.save([]) }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func duplicatePersistedRecordsAreRejected() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("records.json")
        let record = try Self.fileDraft().validatedRecord()
        let data = try JSONEncoder().encode([record, record])
        try data.write(to: url)
        let store = CustomAssociationFileStore(url: url)
        await #expect(throws: (any Error).self) { try await store.load() }
        await #expect(throws: (any Error).self) { try await store.save([]) }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func writesDeclarationOnlyBundleAndUsesStablePathOnRetry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registrar = CustomTypeRegistrar(directory: directory, registration: { _ in }, verification: { _ in true })
        var draft = Self.fileDraft()
        draft.mimeType = "application/x-report"
        let record = try draft.validatedRecord()
        try await registrar.register(record)
        try await registrar.register(record)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let bundle = try #require(urls.first)
        #expect(urls.count == 1)
        #expect(bundle.pathExtension == "app")
        let data = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundlePackageType"] as? String == "APPL")
        #expect(plist["CFBundleExecutable"] == nil)
        #expect(plist["CFBundleDocumentTypes"] == nil)
        #expect(plist["CFBundleURLTypes"] == nil)
        let declarations = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try #require(declarations.first)
        #expect(declaration["UTTypeIdentifier"] as? String == "org.example.report")
        #expect(declaration["UTTypeDescription"] as? String == "Report")
        #expect(declaration["UTTypeConformsTo"] as? [String] == ["public.data"])
        #expect(declaration["UTTypeTagSpecification"] as? [String: [String]] == ["public.filename-extension": ["rpt"], "public.mime-type": ["application/x-report"]])
    }

    @Test func failedDeclarationWriteLeavesNoPartialBundleAndCanRetry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try Self.fileDraft().validatedRecord()
        let failingRegistrar = CustomTypeRegistrar(
            directory: directory,
            registration: { _ in throw TestFailure.registration },
            verification: { _ in true },
            declarationWriter: { _, url in
                // Simulate a write that creates bytes before reporting a filesystem failure.
                try Data("partial plist".utf8).write(to: url)
                throw TestFailure.declarationWrite
            }
        )
        await #expect(throws: TestFailure.declarationWrite) { try await failingRegistrar.register(record) }
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)

        let retryRegistrar = CustomTypeRegistrar(directory: directory, registration: { _ in }, verification: { _ in true })
        try await retryRegistrar.register(record)
        let bundles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(bundles.count == 1)
        let bundle = try #require(bundles.first)
        let data = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["DefaultAppCustomTypeIdentifier"] as? String == "org.example.report")
    }

    @Test func preservesAnUnownedIncompleteBundle() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registrar = CustomTypeRegistrar(directory: directory, registration: { _ in }, verification: { _ in true })
        let record = try Self.fileDraft().validatedRecord()
        try await registrar.register(record)
        let bundle = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("Contents/Info.plist"))
        let marker = bundle.appendingPathComponent("external-file")
        try Data("preserve me".utf8).write(to: marker)
        await #expect(throws: (any Error).self) { try await registrar.register(record) }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "preserve me")
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path))
    }

    @Test func unverifiedRegistrationFails() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registrar = CustomTypeRegistrar(directory: directory, registration: { _ in }, verification: { _ in false })
        let record = try Self.fileDraft().validatedRecord()
        await #expect(throws: (any Error).self) { try await registrar.register(record) }
    }

    @Test func registrationErrorIsPropagated() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registrar = CustomTypeRegistrar(directory: directory, registration: { _ in throw TestFailure.registration }, verification: { _ in true })
        let record = try Self.fileDraft().validatedRecord()
        await #expect(throws: TestFailure.registration) { try await registrar.register(record) }
    }

    @Test func refusesToOverwriteUnownedBundle() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registrar = CustomTypeRegistrar(directory: directory, registration: { _ in }, verification: { _ in true })
        let record = try Self.fileDraft().validatedRecord()
        try await registrar.register(record)
        let bundle = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
        let foreignData = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.someone.else"], format: .xml, options: 0)
        try foreignData.write(to: plistURL)
        await #expect(throws: (any Error).self) { try await registrar.register(record) }
        #expect(try Data(contentsOf: plistURL) == foreignData)
    }

    @Test func statusCheckDoesNotCreateFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registrar = CustomTypeRegistrar(directory: directory, registration: { _ in throw TestFailure.registration }, verification: { identifier in identifier == "org.example.report" })
        let record = try Self.fileDraft().validatedRecord()
        #expect(await registrar.isRegistered(record))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func writeFailureLeavesExistingRecordsUntouched() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedParent = directory.appendingPathComponent("plain-file")
        try Data("untouched".utf8).write(to: blockedParent)
        let store = CustomAssociationFileStore(url: blockedParent.appendingPathComponent("records.json"))
        let record = try Self.fileDraft().validatedRecord()
        await #expect(throws: (any Error).self) { try await store.save([record]) }
        #expect(try String(contentsOf: blockedParent, encoding: .utf8) == "untouched")
    }

    private static func fileDraft() -> NewAssociationDraft {
        var draft = NewAssociationDraft(kind: .contentType)
        draft.identifier = "org.example.report"
        draft.name = "Report"
        draft.filenameExtensions = "rpt"
        return draft
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DefaultApp-CustomTests-\(UUID().uuidString)", isDirectory: true)
    }

    private enum TestFailure: Error, Equatable { case registration, declarationWrite }
}
