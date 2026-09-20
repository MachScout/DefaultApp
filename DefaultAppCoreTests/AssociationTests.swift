import Foundation
import XCTest
@testable import DefaultAppCore

final class AssociationTests: XCTestCase {
    func testApplicationReferenceResolverUsesInjectedBundleIdentifierReader() {
        let url = URL(fileURLWithPath: "/Fixture/Resolved.app", isDirectory: true)
        let resolver = BundleApplicationReferenceResolver { candidate in
            XCTAssertEqual(candidate, url)
            return "test.resolved"
        }

        XCTAssertEqual(
            resolver.reference(forApplicationAt: url),
            ApplicationReference(url: url, bundleIdentifier: "test.resolved")
        )
    }

    func testApplicationIdentityIgnoresDirectoryHintAndDotSegmentsButPreservesStoredURL() {
        let directory = URL(fileURLWithPath: "/Fixture/Reader.app", isDirectory: true)
        let alternate = URL(fileURLWithPath: "/Fixture/Other/../Reader.app", isDirectory: false)
        let reference = ApplicationReference(url: directory)
        let alternateReference = ApplicationReference(url: alternate)
        let record = ApplicationRecord(url: directory, displayName: "Reader")
        XCTAssertEqual(reference.id, "file:///Fixture/Reader.app")
        XCTAssertEqual(alternateReference.id, "file:///Fixture/Reader.app")
        XCTAssertEqual(record.id, "file:///Fixture/Reader.app")
        XCTAssertEqual(reference.url, directory)
        XCTAssertEqual(record.url, directory)
        XCTAssertNotEqual(reference.id, ApplicationReference(url: URL(fileURLWithPath: "/Other/Reader.app")).id)
    }

    func testSchemeNormalizationRemovesColonAndLowercases() throws {
        XCTAssertEqual(try Association.urlScheme(" MailTo: ").identifier, "mailto")
    }

    func testContentTypeRejectsWhitespace() {
        XCTAssertThrowsError(try Association.contentType("public plain-text"))
    }

    func testSchemeRejectsNonASCIIAndMalformedSyntaxWithTypedError() {
        for value in ["mαilto", "mａilto", "mail²", "K-mail", "1mail", "mail_to", "mail/to", "mail::", "*", ""] {
            XCTAssertThrowsError(try Association.urlScheme(value), "Expected rejection for \(value)") {
                XCTAssertEqual($0 as? DefaultAppError, .malformedAssociationIdentifier(kind: .urlScheme, value: value))
            }
        }
    }

    func testSchemeAcceptsEveryASCIISyntaxClassAndNormalizes() throws {
        XCTAssertEqual(try Association.urlScheme(" A: ").identifier, "a")
        XCTAssertEqual(try Association.urlScheme(" X-Test+9.0: ").identifier, "x-test+9.0")
    }

    func testContentTypeRejectsIllegalASCIIAndEmptyComponentsWithTypedError() {
        for value in ["bad_type", "public/text", "public:text", "*", "public.+text", "public.@text",
                      "public.#text", "public.\u{0000}text", "public.\u{007F}text", "public.\ttext",
                      "", ".public", "public.", "public..text", "."] {
            XCTAssertThrowsError(try Association.contentType(value), "Expected rejection for \(value.debugDescription)") {
                XCTAssertEqual($0 as? DefaultAppError, .malformedAssociationIdentifier(kind: .contentType, value: value))
            }
        }
    }

    func testContentTypeAcceptsDocumentedUnicodeAndUnregisteredSyntax() throws {
        for (value, expected) in [
            (" COM.Example.Unregistered-Type42 ", "com.example.unregistered-type42"),
            ("com.例子.类型", "com.例子.类型"),
            ("com.example.ÉTUDE", "com.example.étude"),
            ("com.example.🧪", "com.example.🧪"),
            ("com.example.\u{0080}", "com.example.\u{0080}"),
        ] {
            XCTAssertEqual(try Association.contentType(value).identifier, expected)
        }
    }

    func testDecodingRejectsInvalidAssociationSyntaxWithTypedError() throws {
        let cases: [(Association.Kind, String)] = [
            (.urlScheme, "mαilto"), (.urlScheme, "K-mail"),
            (.contentType, "bad_type"), (.contentType, "public/text"), (.contentType, "public:text"),
            (.contentType, "*"), (.contentType, "public..text"),
        ]
        for (kind, value) in cases {
            let data = try JSONSerialization.data(withJSONObject: ["kind": kind.rawValue, "identifier": value])
            XCTAssertThrowsError(try JSONDecoder().decode(Association.self, from: data), "Expected rejection for \(value)") {
                XCTAssertEqual($0 as? DefaultAppError, .malformedAssociationIdentifier(kind: kind, value: value))
            }
        }
    }

    func testDecodingNormalizesValidAssociationSyntax() throws {
        let scheme = Data(#"{"kind":"urlScheme","identifier":" X-Test+9.0: "}"#.utf8)
        let type = Data(#"{"kind":"contentType","identifier":" COM.Example.ÉTUDE "}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Association.self, from: scheme).identifier, "x-test+9.0")
        XCTAssertEqual(try JSONDecoder().decode(Association.self, from: type).identifier, "com.example.étude")
    }

    func testRoleAllContainsEveryConcreteRole() {
        XCTAssertTrue(HandlerRole.all.contains(.viewer))
        XCTAssertTrue(HandlerRole.all.contains(.editor))
        XCTAssertTrue(HandlerRole.all.contains(.shell))
    }

    func testDecodingContentTypeRejectsWhitespaceWithTypedError() throws {
        let data = Data(#"{"kind":"contentType","identifier":"public plain-text"}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(Association.self, from: data)) {
            XCTAssertEqual(
                $0 as? DefaultAppError,
                .malformedAssociationIdentifier(
                    kind: .contentType,
                    value: "public plain-text"
                )
            )
        }
    }
}
