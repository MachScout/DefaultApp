import Foundation
import XCTest
@testable import DefaultAppCore

final class SystemSPITests: XCTestCase {
    func testPrivateSPIPayloadsOnHost() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEFAULTAPP_RUN_SYSTEM_TESTS"] == "1")
        let spi = SilgenLaunchServicesSPI()
        let applications = try spi.applicationURLs()
        let types = try spi.declaredTypeIdentifiers()
        let schemes = try spi.schemesAndHandlerURLs()
        XCTAssertFalse(applications.isEmpty)
        XCTAssertFalse(types.isEmpty)
        print("Read-only SPI ABI smoke test: \(applications.count) applications, \(schemes.count) scheme/handler pairs, \(types.count) declared types.")
    }
}
