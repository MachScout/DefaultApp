import CoreServices
import UniformTypeIdentifiers
import XCTest
@testable import DefaultAppCore

final class HandlerBackendTests: XCTestCase, @unchecked Sendable {
    private let app = ApplicationReference(url: URL(fileURLWithPath: "/Applications/Fixture.app"), bundleIdentifier: "test.fixture")

    // These catch validation moving after a read or mutation at the system boundary.
    func testModernRejectsConcreteRolesBeforeEveryWorkspaceOperation() async throws {
        let workspace = FakeModernWorkspace()
        let backend = ModernHandlerBackend(workspace: workspace)
        for association in [try Association.contentType("public.text"), try Association.urlScheme("mailto")] {
            for role: HandlerRole in [.viewer, .editor, .shell, [], [.viewer, .editor]] {
                await XCTAssertThrowsErrorAsync({ try await backend.applications(for: association, role: role) }) {
                    XCTAssertEqual($0 as? DefaultAppError, .unsupportedRole(backend: .modern, associationKind: association.kind))
                }
                await XCTAssertThrowsErrorAsync({ try await backend.defaultApplication(for: association, role: role) }) {
                    XCTAssertEqual($0 as? DefaultAppError, .unsupportedRole(backend: .modern, associationKind: association.kind))
                }
                await XCTAssertThrowsErrorAsync({ try await backend.setDefaultApplication(self.app, for: association, role: role) }) {
                    XCTAssertEqual($0 as? DefaultAppError, .unsupportedRole(backend: .modern, associationKind: association.kind))
                }
            }
        }
        let calls = await workspace.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testModernConvertsAssociationsAndReturnsApplications() async throws {
        let workspace = FakeModernWorkspace(urls: [app.url], defaultURL: app.url)
        let backend: any HandlerBackend = ModernHandlerBackend(workspace: workspace)
        for association in [try Association.contentType("public.text"), try Association.urlScheme("MAILTO:")] {
            let applications = try await backend.applications(for: association, role: .all)
            let selected = try await backend.defaultApplication(for: association, role: .all)
            XCTAssertEqual(applications.map(\.url), [app.url])
            XCTAssertEqual(selected?.url, app.url)
            try await backend.setDefaultApplication(app, for: association, role: .all)
        }
        let calls = await workspace.calls
        XCTAssertEqual(calls, ["applications:type:public.text", "default:type:public.text", "set:type:public.text:/Applications/Fixture.app", "applications:url:mailto:", "default:url:mailto:", "set:url:mailto::/Applications/Fixture.app"])
    }

    func testModernRejectsUnknownTypeBeforeCallingWorkspace() async throws {
        let workspace = FakeModernWorkspace()
        let backend = ModernHandlerBackend(workspace: workspace)
        let association = try Association.contentType("test.defaultapp.nonexistent.725f5f")
        await XCTAssertThrowsErrorAsync({ try await backend.applications(for: association, role: .all) }) {
            XCTAssertEqual($0 as? DefaultAppError, .unknownContentType(identifier: association.identifier))
        }
        await XCTAssertThrowsErrorAsync({ try await backend.defaultApplication(for: association, role: .all) }) {
            XCTAssertEqual($0 as? DefaultAppError, .unknownContentType(identifier: association.identifier))
        }
        await XCTAssertThrowsErrorAsync({ try await backend.setDefaultApplication(self.app, for: association, role: .all) }) {
            XCTAssertEqual($0 as? DefaultAppError, .unknownContentType(identifier: association.identifier))
        }
        let calls = await workspace.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testModernEmptyResultsAndSetterFailure() async throws {
        let workspace = FakeModernWorkspace(failure: NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Denied"]))
        let backend = ModernHandlerBackend(workspace: workspace)
        let association = try Association.urlScheme("mailto")
        let applications = try await backend.applications(for: association, role: .all)
        let selected = try await backend.defaultApplication(for: association, role: .all)
        XCTAssertTrue(applications.isEmpty)
        XCTAssertNil(selected)
        await XCTAssertThrowsErrorAsync({ try await backend.setDefaultApplication(self.app, for: association, role: .all) }) {
            XCTAssertEqual($0 as? DefaultAppError, .modernFailure(operation: "setDefaultApplication", description: "Denied"))
        }
    }

    func testLegacyMapsEveryContentRoleForQueriesAndMutation() async throws {
        let association = try Association.contentType("public.text")
        let app = app
        let fixtures: [(HandlerRole, LSRolesMask)] = [(.viewer, .viewer), (.editor, .editor), (.shell, .shell), ([.viewer, .editor], [.viewer, .editor]), (.all, .all)]
        for (role, expectedMask) in fixtures {
            let api = FakeLegacyAPI(identifiers: ["test.fixture"], defaultIdentifier: "test.fixture")
            let backend: any HandlerBackend = LegacyHandlerBackend(api: api, resolver: { _ in app.url })
            let applications = try await backend.applications(for: association, role: role)
            let selected = try await backend.defaultApplication(for: association, role: role)
            XCTAssertEqual(applications, [app])
            XCTAssertEqual(selected, app)
            try await backend.setDefaultApplication(app, for: association, role: role)
            let calls = await api.calls
            XCTAssertEqual(calls, ["applications:public.text:\(expectedMask.rawValue)", "default:public.text:\(expectedMask.rawValue)", "set:public.text:\(expectedMask.rawValue):test.fixture"])
        }
    }

    func testLegacyRejectsConcreteSchemeRolesBeforeSystemCalls() async throws {
        let api = FakeLegacyAPI()
        let backend = LegacyHandlerBackend(api: api, resolver: { _ in nil })
        let association = try Association.urlScheme("mailto")
        for role: HandlerRole in [.viewer, .editor, .shell, [], [.viewer, .editor]] {
            await XCTAssertThrowsErrorAsync({ try await backend.applications(for: association, role: role) }) {
                XCTAssertEqual($0 as? DefaultAppError, .unsupportedRole(backend: .legacy, associationKind: .urlScheme))
            }
            await XCTAssertThrowsErrorAsync({ try await backend.defaultApplication(for: association, role: role) }) {
                XCTAssertEqual($0 as? DefaultAppError, .unsupportedRole(backend: .legacy, associationKind: .urlScheme))
            }
            await XCTAssertThrowsErrorAsync({ try await backend.setDefaultApplication(self.app, for: association, role: role) }) {
                XCTAssertEqual($0 as? DefaultAppError, .unsupportedRole(backend: .legacy, associationKind: .urlScheme))
            }
        }
        let calls = await api.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testLegacySchemeRoutingResolvesOnlyInstalledHandlers() async throws {
        let app = app
        let api = FakeLegacyAPI(identifiers: ["test.fixture", "test.missing"], defaultIdentifier: "test.fixture")
        let backend = LegacyHandlerBackend(api: api, resolver: { $0 == "test.fixture" ? app.url : nil })
        let association = try Association.urlScheme("MAILTO:")
        let applications = try await backend.applications(for: association, role: .all)
        let selected = try await backend.defaultApplication(for: association, role: .all)
        XCTAssertEqual(applications, [app])
        XCTAssertEqual(selected, app)
        try await backend.setDefaultApplication(app, for: association, role: .all)
        let calls = await api.calls
        XCTAssertEqual(calls, ["applications:mailto", "default:mailto", "set:mailto:test.fixture"])
    }

    func testLegacyMissingAndUnresolvedDefaultsReturnNil() async throws {
        for identifier: String? in [nil, "test.missing"] {
            let backend = LegacyHandlerBackend(api: FakeLegacyAPI(defaultIdentifier: identifier), resolver: { _ in nil })
            for association in [try Association.urlScheme("mailto"), try Association.contentType("public.text")] {
                let selected = try await backend.defaultApplication(for: association, role: .all)
                let applications = try await backend.applications(for: association, role: .all)
                XCTAssertNil(selected)
                XCTAssertTrue(applications.isEmpty)
            }
        }
    }

    func testLegacySetterRejectsMissingBundleIdentifierBeforeMutation() async throws {
        let api = FakeLegacyAPI()
        let backend = LegacyHandlerBackend(api: api, resolver: { _ in nil })
        let application = ApplicationReference(url: app.url)
        await XCTAssertThrowsErrorAsync({ try await backend.setDefaultApplication(application, for: .contentType("public.text"), role: .all) }) {
            XCTAssertEqual($0 as? DefaultAppError, .missingBundleIdentifier(url: application.url))
        }
        let calls = await api.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testLegacySetterMapsNonzeroStatusForBothKinds() async throws {
        let backend = LegacyHandlerBackend(api: FakeLegacyAPI(status: -50), resolver: { _ in nil })
        for (association, operation) in [(try Association.contentType("public.text"), "LSSetDefaultRoleHandlerForContentType"), (try Association.urlScheme("mailto"), "LSSetDefaultHandlerForURLScheme")] {
            await XCTAssertThrowsErrorAsync({ try await backend.setDefaultApplication(self.app, for: association, role: .all) }) {
                XCTAssertEqual($0 as? DefaultAppError, .legacyFailure(operation: operation, status: -50))
            }
        }
    }
}

// Only the external NSWorkspace/LaunchServices boundary is replaced; tests never change actual defaults.
private actor FakeModernWorkspace: ModernWorkspaceProviding {
    var calls: [String] = []
    let urls: [URL]
    let defaultURL: URL?
    let failure: NSError?
    init(urls: [URL] = [], defaultURL: URL? = nil, failure: NSError? = nil) {
        self.urls = urls; self.defaultURL = defaultURL; self.failure = failure
    }
    func applications(for target: ModernHandlerTarget) -> [URL] {
        calls.append("applications:\(key(target))"); return urls
    }
    func defaultApplication(for target: ModernHandlerTarget) -> URL? {
        calls.append("default:\(key(target))"); return defaultURL
    }
    func setDefaultApplication(at url: URL, for target: ModernHandlerTarget) throws {
        calls.append("set:\(key(target)):\(url.path)")
        if let failure { throw failure }
    }
    private func key(_ target: ModernHandlerTarget) -> String {
        switch target {
        case .url(let url): "url:\(url.absoluteString)"
        case .contentType(let type): "type:\(type.identifier)"
        }
    }
}

private actor FakeLegacyAPI: LegacyHandlerAPI {
    var calls: [String] = []
    let identifiers: [String]
    let defaultIdentifier: String?
    let status: OSStatus
    init(identifiers: [String] = [], defaultIdentifier: String? = nil, status: OSStatus = 0) {
        self.identifiers = identifiers; self.defaultIdentifier = defaultIdentifier; self.status = status
    }
    func handlers(forContentType identifier: String, roles: LSRolesMask) -> [String] {
        calls.append("applications:\(identifier):\(roles.rawValue)"); return identifiers
    }
    func defaultHandler(forContentType identifier: String, roles: LSRolesMask) -> String? {
        calls.append("default:\(identifier):\(roles.rawValue)"); return defaultIdentifier
    }
    func setDefaultHandler(_ bundleIdentifier: String, forContentType identifier: String, roles: LSRolesMask) -> OSStatus {
        calls.append("set:\(identifier):\(roles.rawValue):\(bundleIdentifier)"); return status
    }
    func handlers(forURLScheme scheme: String) -> [String] {
        calls.append("applications:\(scheme)"); return identifiers
    }
    func defaultHandler(forURLScheme scheme: String) -> String? {
        calls.append("default:\(scheme)"); return defaultIdentifier
    }
    func setDefaultHandler(_ bundleIdentifier: String, forURLScheme scheme: String) -> OSStatus {
        calls.append("set:\(scheme):\(bundleIdentifier)"); return status
    }
}
