import Foundation
import XCTest
import DefaultAppCore
@testable import DefaultAppCLIKit

final class CLIOutputTests: XCTestCase {
    private let reader = ApplicationRecord(
        url: URL(fileURLWithPath: "/Applications/Reader.app"),
        bundleIdentifier: "test.reader",
        displayName: "Reader"
    )

    func testJSONIsOnePrettySortedDocumentWithUnescapedSlashes() throws {
        let text = try CLIOutput().json(reader)
        let data = try XCTUnwrap(text.data(using: .utf8))

        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertTrue(text.contains("file:///Applications/Reader.app"))
        XCTAssertFalse(text.contains("\\/"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"bundleIdentifier\"")?.lowerBound),
                          try XCTUnwrap(text.range(of: "\"displayName\"")?.lowerBound))
    }

    func testApplicationTableHasStableAlignedColumns() {
        XCTAssertEqual(
            CLIOutput().applications([reader]),
            "NAME    BUNDLE ID    PATH\n" +
            "Reader  test.reader  /Applications/Reader.app\n"
        )
    }

    func testHelpListsEveryDocumentedCommand() {
        let help = CLIOutput.help
        for command in ["apps", "app", "schemes", "types", "handlers", "get", "set", "doctor"] {
            XCTAssertTrue(help.contains("defaultapp \(command)"), "Missing \(command) from help")
        }
    }
}
