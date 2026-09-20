import XCTest
import DefaultAppCore
@testable import DefaultAppCLIKit

final class CLIParserTests: XCTestCase {
    func testParsesLegacySetWithViewerRole() throws {
        let command = try CLIParser().parse([
            "set", "uti", "public.text", "--app", "com.apple.TextEdit",
            "--backend", "legacy", "--role", "viewer",
        ])

        XCTAssertEqual(command, .set(
            kind: .uti,
            identifier: "public.text",
            app: "com.apple.TextEdit",
            backend: .legacy,
            role: .viewer
        ))
    }

    func testRejectsRoleForScheme() {
        XCTAssertThrowsError(try CLIParser().parse([
            "get", "scheme", "mailto", "--role", "viewer",
        ]))
    }

    func testRejectsInvalidAssociationSyntaxForEveryAssociationCommandAndBackend() {
        for (kind, identifier) in [("scheme", "mαilto"), ("scheme", "K-mail"),
                                   ("uti", "bad_type"), ("uti", "public/text"), ("uti", "public:text"),
                                   ("uti", "*"), ("uti", "public..text")] {
            for backend in ["modern", "legacy"] {
                for arguments in [
                    ["get", kind, identifier, "--backend", backend],
                    ["handlers", kind, identifier, "--backend", backend],
                    ["set", kind, identifier, "--backend", backend, "--app", "test.reader"],
                ] {
                    XCTAssertThrowsError(try CLIParser().parse(arguments), "Expected rejection for \(arguments)")
                }
            }
        }
    }

    func testNormalizesValidAssociationSyntaxWithoutRequiringRegistration() throws {
        XCTAssertEqual(try CLIParser().parse(["get", "scheme", " X-Test+9.0: "]),
                       .get(kind: .scheme, identifier: "x-test+9.0", backend: .modern, role: .all, json: false))
        XCTAssertEqual(try CLIParser().parse(["get", "uti", " COM.Example.ÉTUDE "]),
                       .get(kind: .uti, identifier: "com.example.étude", backend: .modern, role: .all, json: false))
    }

    func testJSONFlagIsAcceptedBeforeOrAfterSubcommandArguments() throws {
        XCTAssertTrue(try CLIParser().parse(["--json", "apps"]).usesJSON)
        XCTAssertTrue(try CLIParser().parse(["apps", "--json"]).usesJSON)
    }

    func testParsesEveryReadOnlyCommandAndDefaults() throws {
        XCTAssertEqual(try CLIParser().parse([]), .help)
        XCTAssertEqual(try CLIParser().parse(["help"]), .help)
        XCTAssertEqual(try CLIParser().parse(["apps"]), .apps(json: false))
        XCTAssertEqual(try CLIParser().parse(["app", "com.apple.TextEdit"]), .app(app: "com.apple.TextEdit", json: false))
        XCTAssertEqual(try CLIParser().parse(["schemes"]), .schemes(json: false))
        XCTAssertEqual(try CLIParser().parse(["types"]), .types(json: false))
        XCTAssertEqual(
            try CLIParser().parse(["handlers", "scheme", "mailto"]),
            .handlers(kind: .scheme, identifier: "mailto", backend: .modern, role: .all, json: false)
        )
        XCTAssertEqual(
            try CLIParser().parse(["get", "uti", "public.text", "--backend", "legacy", "--role", "editor", "--json"]),
            .get(kind: .uti, identifier: "public.text", backend: .legacy, role: .editor, json: true)
        )
        XCTAssertEqual(try CLIParser().parse(["doctor", "--json"]), .doctor(json: true))
    }

    func testRejectsUnsupportedOrMalformedArgumentsBeforeDispatch() {
        let invalidArguments = [
            ["set", "uti", "public.text", "--app", "TextEdit", "--json"],
            ["handlers", "uti", "public.text", "--role", "viewer"],
            ["get", "uti", "public.text", "--backend", "future"],
            ["get", "file", "public.text"],
            ["set", "uti", "public.text"],
            ["apps", "--backend", "legacy"],
            ["apps", "--json", "--json"],
            ["set", "uti", "public.text", "--app", "--json"],
            ["unknown"],
        ]

        for arguments in invalidArguments {
            XCTAssertThrowsError(try CLIParser().parse(arguments), "Expected rejection for \(arguments)")
        }
    }
}
