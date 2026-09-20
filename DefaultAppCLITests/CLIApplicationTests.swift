import Foundation
import XCTest
import DefaultAppCore
@testable import DefaultAppCLIKit

final class CLIApplicationTests: XCTestCase, @unchecked Sendable {
    private let reader = ApplicationRecord(
        url: URL(fileURLWithPath: "/Applications/Reader.app"),
        bundleIdentifier: "test.reader",
        displayName: "Reader",
        shortVersion: "1.0"
    )

    func testEveryReadOnlyCommandUsesTheInjectedServiceAndWritesOnlyStdout() async throws {
        let association = try Association.urlScheme("mailto")
        let snapshot = CatalogSnapshot(
            applications: [reader],
            urlSchemes: [URLSchemeRecord(identifier: "mailto", handlerApplications: [reader.reference])],
            contentTypes: [ContentTypeRecord(identifier: "public.text", localizedDescription: "Text")],
            diagnostics: SPIDiagnostics(applicationCallStatus: 0, schemeCallStatus: 0, contentTypeCallStatus: 0,
                                        applicationCount: 1, schemeCount: 1, contentTypeCount: 1,
                                        expectedSymbolNames: ["_LSCopyAllApplicationURLs"])
        )
        let cases: [([String], FakeCLIService.Call)] = [
            (["apps"], .catalog(false)),
            (["app", "test.reader"], .catalog(false)),
            (["schemes"], .catalog(false)),
            (["types"], .catalog(false)),
            (["handlers", "scheme", "mailto"], .applications(association, .modern, .all)),
            (["get", "scheme", "mailto"], .defaultApplication(association, .modern, .all)),
            (["doctor"], .catalog(true)),
        ]

        for (arguments, expectedCall) in cases {
            let service = FakeCLIService(snapshot: snapshot, applications: [reader], defaultApplication: reader)
            let sink = RecordingSink()

            let status = await CLIApplication().run(arguments: arguments, service: service, output: sink)
            let stdout = await sink.stdout
            let stderr = await sink.stderr
            let calls = await service.calls

            XCTAssertEqual(status, 0, "Failed arguments: \(arguments)")
            XCTAssertFalse(stdout.isEmpty)
            XCTAssertEqual(stderr, "")
            XCTAssertEqual(calls, [expectedCall])
        }
    }

    func testJSONCommandEmitsOneDecodableDocumentAndNoProgressChatter() async throws {
        let snapshot = CatalogSnapshot(applications: [reader])
        let service = FakeCLIService(snapshot: snapshot)
        let sink = RecordingSink()

        let status = await CLIApplication().run(arguments: ["--json", "apps"], service: service, output: sink)
        let stdout = await sink.stdout
        let stderr = await sink.stderr
        let stdoutWriteCount = await sink.stdoutWriteCount

        XCTAssertEqual(status, 0)
        XCTAssertEqual(try JSONDecoder().decode([ApplicationRecord].self, from: Data(stdout.utf8)), [reader])
        XCTAssertEqual(stderr, "")
        XCTAssertEqual(stdoutWriteCount, 1)
    }

    func testMalformedAssociationsExitWithUsageErrorBeforeAnyServiceCall() async {
        for (kind, identifier) in [("scheme", "mαilto"), ("uti", "bad_type"),
                                   ("uti", "public/text"), ("uti", "public:text"), ("uti", "*")] {
            for backend in ["modern", "legacy"] {
                for arguments in [
                    ["get", kind, identifier, "--backend", backend, "--json"],
                    ["handlers", kind, identifier, "--backend", backend, "--json"],
                    ["set", kind, identifier, "--backend", backend, "--app", "test.reader"],
                ] {
                    let service = FakeCLIService(snapshot: CatalogSnapshot(applications: [reader]))
                    let sink = RecordingSink()
                    let status = await CLIApplication().run(arguments: arguments, service: service, output: sink)
                    let stdout = await sink.stdout
                    let stderr = await sink.stderr
                    let calls = await service.calls

                    XCTAssertEqual(status, 2, "Arguments: \(arguments)")
                    XCTAssertEqual(stdout, "", "Arguments: \(arguments)")
                    XCTAssertTrue(stderr.contains("error:"), "Arguments: \(arguments)")
                    XCTAssertFalse(stderr.contains("system confirmation"), "Arguments: \(arguments)")
                    XCTAssertTrue(calls.isEmpty, "Arguments: \(arguments); calls: \(calls)")
                }
            }
        }
    }

    func testGetJSONUsesTheApplicationRecordSchemaDirectly() async throws {
        let service = FakeCLIService(defaultApplication: reader)
        let sink = RecordingSink()

        let status = await CLIApplication().run(
            arguments: ["get", "scheme", "mailto", "--json"],
            service: service,
            output: sink
        )
        let stdout = await sink.stdout

        XCTAssertEqual(status, 0)
        XCTAssertEqual(try JSONDecoder().decode(ApplicationRecord.self, from: Data(stdout.utf8)), reader)
    }

    func testExistingApplicationPathWinsAndWarningPrecedesInjectedSetter() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DefaultAppCLI-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pathRecord = ApplicationRecord(url: directory, bundleIdentifier: "test.path", displayName: "Path App")
        let bundleCollision = ApplicationRecord(
            url: URL(fileURLWithPath: "/Applications/Collision.app"),
            bundleIdentifier: directory.path,
            displayName: "Collision"
        )
        let events = EventRecorder()
        let service = FakeCLIService(snapshot: CatalogSnapshot(applications: [bundleCollision, pathRecord]), events: events)
        let sink = RecordingSink(events: events)

        let status = await CLIApplication(
            applicationReferenceResolver: StubApplicationReferenceResolver(bundleIdentifier: "test.wrong")
        ).run(
            arguments: ["set", "uti", "public.text", "--app", directory.path],
            service: service,
            output: sink
        )

        XCTAssertEqual(status, 0)
        let calls = await service.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first, .catalog(false))
        guard case let .set(application, association, backend, role) = calls.last else {
            return XCTFail("Expected setter call")
        }
        XCTAssertEqual(application, pathRecord.reference)
        XCTAssertEqual(association, try Association.contentType("public.text"))
        XCTAssertEqual(backend, .modern)
        XCTAssertEqual(role, .all)
        let recordedEvents = await events.values
        let stderr = await sink.stderr
        let stdout = await sink.stdout
        XCTAssertEqual(recordedEvents, [.warning, .setter])
        XCTAssertTrue(stderr.contains("system confirmation"))
        XCTAssertTrue(stdout.contains("test.path"))
    }

    func testOutOfCatalogExistingPathUsesInjectedCoreResolver() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DefaultAppCLI-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = FakeCLIService(snapshot: CatalogSnapshot())
        let sink = RecordingSink()
        let application = CLIApplication(
            applicationReferenceResolver: StubApplicationReferenceResolver(bundleIdentifier: "test.resolved")
        )

        let status = await application.run(
            arguments: ["set", "scheme", "mailto", "--app", directory.path],
            service: service,
            output: sink
        )

        XCTAssertEqual(status, 0)
        let calls = await service.calls
        guard case let .set(reference, _, _, _)? = calls.last else {
            return XCTFail("Expected setter call")
        }
        XCTAssertEqual(reference, ApplicationReference(url: directory, bundleIdentifier: "test.resolved"))
    }

    func testNonexistentPathFallsBackToCatalogBundleIdentifier() async throws {
        let service = FakeCLIService(snapshot: CatalogSnapshot(applications: [reader]))
        let sink = RecordingSink()

        let status = await CLIApplication().run(
            arguments: ["set", "scheme", "mailto", "--app", "test.reader"],
            service: service,
            output: sink
        )

        XCTAssertEqual(status, 0)
        let calls = await service.calls
        guard case let .set(application, _, _, _)? = calls.last else {
            return XCTFail("Expected setter call")
        }
        XCTAssertEqual(application, reader.reference)
    }

    func testUsageErrorDoesNotCallServiceAndUsesOnlyStderr() async {
        let service = FakeCLIService()
        let sink = RecordingSink()

        let status = await CLIApplication().run(
            arguments: ["get", "scheme", "mailto", "--role", "viewer"],
            service: service,
            output: sink
        )
        let calls = await service.calls
        let stdout = await sink.stdout
        let stderr = await sink.stderr

        XCTAssertEqual(status, 2)
        XCTAssertEqual(calls, [])
        XCTAssertEqual(stdout, "")
        XCTAssertTrue(stderr.contains("error:"))
    }

    func testTypedFailuresMapToDocumentedExitCategories() async throws {
        let association = try Association.contentType("public.text")
        let failures: [(DefaultAppError, Int32)] = [
            (.privateSPIFailure(symbol: "fixture", status: -1), 3),
            (.applicationNotCapable(application: reader.reference, association: association), 4),
            (.modernFailure(operation: "set", description: "fixture"), 5),
            (.changeNotObserved(requested: reader.reference, observed: nil), 6),
        ]

        for (failure, expectedStatus) in failures {
            let service = FakeCLIService(catalogFailure: failure)
            let sink = RecordingSink()
            let status = await CLIApplication().run(arguments: ["apps"], service: service, output: sink)
            let stdout = await sink.stdout
            let stderr = await sink.stderr
            XCTAssertEqual(status, expectedStatus, "Wrong status for \(failure)")
            XCTAssertEqual(stdout, "")
            XCTAssertTrue(stderr.hasPrefix("error:"))
        }
    }

    func testUnknownApplicationIsUnsupportedAndNeverCallsSetter() async {
        let service = FakeCLIService(snapshot: CatalogSnapshot())
        let sink = RecordingSink()

        let status = await CLIApplication().run(
            arguments: ["set", "uti", "public.text", "--app", "missing.bundle"],
            service: service,
            output: sink
        )
        let calls = await service.calls
        let stderr = await sink.stderr

        XCTAssertEqual(status, 4)
        XCTAssertEqual(calls, [.catalog(false)])
        XCTAssertFalse(stderr.contains("system confirmation"))
    }

    func testReadOnlyDoctorExecutableOnHost() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEFAULTAPP_RUN_SYSTEM_TESTS"] == "1")
        let productsDirectory = Bundle(for: CLIApplicationTests.self).bundleURL.deletingLastPathComponent()
        let executableURL = productsDirectory.appendingPathComponent("defaultapp")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executableURL.path))

        let result = try captureProcess(executableURL: executableURL, arguments: ["doctor", "--json"])

        XCTAssertEqual(result.terminationStatus, 0, String(decoding: result.standardError, as: UTF8.self))
        XCTAssertNoThrow(try JSONDecoder().decode(SPIDiagnostics.self, from: result.standardOutput))
        XCTAssertTrue(result.standardError.isEmpty)
    }

    func testProcessCaptureHandlesMoreThanPipeCapacityOnBothStreams() throws {
        let result = try captureProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "/bin/dd if=/dev/zero bs=70000 count=1 2>/dev/null; " +
                    "/bin/dd if=/dev/zero bs=70000 count=1 1>&2 2>/dev/null",
            ]
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput.count, 70_000)
        XCTAssertEqual(result.standardError.count, 70_000)
    }
}

private struct CapturedProcess {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
}

private struct StubApplicationReferenceResolver: ApplicationReferenceResolving {
    let bundleIdentifier: String?

    func reference(forApplicationAt url: URL) -> ApplicationReference {
        ApplicationReference(url: url, bundleIdentifier: bundleIdentifier)
    }
}

private func captureProcess(executableURL: URL, arguments: [String]) throws -> CapturedProcess {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("DefaultAppProcessCapture-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let outputURL = directory.appendingPathComponent("stdout")
    let errorURL = directory.appendingPathComponent("stderr")
    try Data().write(to: outputURL)
    try Data().write(to: errorURL)
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    let errorHandle = try FileHandle(forWritingTo: errorURL)
    defer {
        try? outputHandle.close()
        try? errorHandle.close()
    }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = outputHandle
    process.standardError = errorHandle
    try process.run()
    process.waitUntilExit()
    try outputHandle.close()
    try errorHandle.close()

    return CapturedProcess(
        terminationStatus: process.terminationStatus,
        standardOutput: try Data(contentsOf: outputURL),
        standardError: try Data(contentsOf: errorURL)
    )
}

private actor FakeCLIService: CLIHandlerServicing {
    enum Call: Equatable {
        case catalog(Bool)
        case applications(Association, Backend, HandlerRole)
        case defaultApplication(Association, Backend, HandlerRole)
        case set(ApplicationReference, Association, Backend, HandlerRole)
    }

    let snapshot: CatalogSnapshot
    let applicationValues: [ApplicationRecord]
    let defaultValue: ApplicationRecord?
    let catalogFailure: DefaultAppError?
    let events: EventRecorder?
    private(set) var calls: [Call] = []

    init(
        snapshot: CatalogSnapshot = CatalogSnapshot(),
        applications: [ApplicationRecord] = [],
        defaultApplication: ApplicationRecord? = nil,
        catalogFailure: DefaultAppError? = nil,
        events: EventRecorder? = nil
    ) {
        self.snapshot = snapshot
        applicationValues = applications
        defaultValue = defaultApplication
        self.catalogFailure = catalogFailure
        self.events = events
    }

    func catalog(forceRefresh: Bool) async throws -> CatalogSnapshot {
        calls.append(.catalog(forceRefresh))
        if let catalogFailure { throw catalogFailure }
        return snapshot
    }

    func applications(capableOf association: Association, backend: Backend, role: HandlerRole) async throws -> [ApplicationRecord] {
        calls.append(.applications(association, backend, role))
        if let catalogFailure { throw catalogFailure }
        return applicationValues
    }

    func defaultApplication(for association: Association, backend: Backend, role: HandlerRole) async throws -> ApplicationRecord? {
        calls.append(.defaultApplication(association, backend, role))
        if let catalogFailure { throw catalogFailure }
        return defaultValue
    }

    func setDefaultApplication(_ application: ApplicationReference, for association: Association,
                               backend: Backend, role: HandlerRole) async throws {
        calls.append(.set(application, association, backend, role))
        await events?.append(.setter)
    }
}

private actor RecordingSink: CLIOutputSink {
    private(set) var stdout = ""
    private(set) var stderr = ""
    private(set) var stdoutWriteCount = 0
    let events: EventRecorder?

    init(events: EventRecorder? = nil) {
        self.events = events
    }

    func writeStdout(_ text: String) async {
        stdout += text
        stdoutWriteCount += 1
    }

    func writeStderr(_ text: String) async {
        stderr += text
        if text.contains("system confirmation") {
            await events?.append(.warning)
        }
    }
}

private actor EventRecorder {
    enum Event: Equatable {
        case warning
        case setter
    }

    private(set) var values: [Event] = []

    func append(_ event: Event) {
        values.append(event)
    }
}
