import Foundation
import XCTest
@testable import DefaultAppCore

final class DynamicTypeDiscoveryTests: XCTestCase {
    func testParsesAllRegisteredDynamicIdentifiers() {
        let dump = """
        claimed UTIs: public.text, dyn.ah62d4rv4ge80425uqk (.mcpb), dyn.ah62d4rv4ge80e7dxr31086a
        claimed UTIs: dyn.ah62d4rv4ge80425uqk, public.data
        """
        XCTAssertEqual(DynamicTypeDiscovery.parse(dump), [
            DynamicTypePreference(identifier: "dyn.ah62d4rv4ge80425uqk", filenameExtension: nil),
            DynamicTypePreference(identifier: "dyn.ah62d4rv4ge80e7dxr31086a", filenameExtension: nil)
        ])
    }

    func testParsesExtensionPreferencesWithoutTreatingDeclaredTypesAsDynamic() throws {
        let dump = """
        handlerpref id:             machscouttestxyz123 (0x1eff48)
        extension:                  machscouttestxyz123
        all roles:                  com.machscout.utiregistrationtest
        mod date:                   2026-09-21 13:39

        --------------------------------------------------------------------------------
        handlerpref id:             public.plain-text (0x2)
        content type:               public.plain-text
        all roles:                  com.apple.TextEdit

        --------------------------------------------------------------------------------
        handlerpref id:             mailto (0x3)
        URL scheme:                 mailto
        all roles:                  com.apple.mail
        """
        let result = DynamicTypeDiscovery.parse(dump)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.filenameExtension, "machscouttestxyz123")
        XCTAssertTrue(result.first?.identifier.hasPrefix("dyn.") == true)
    }

    func testIgnoresExtensionPreferencesWithoutAHandler() {
        let dump = """
        handlerpref id:             orphan (0x4)
        extension:                  orphan
        mod date:                   2026-09-21 13:39
        """
        XCTAssertTrue(DynamicTypeDiscovery.parse(dump).isEmpty)
    }

    func testDoesNotMixPreferenceWithLaterDumpSections() {
        let dump = """
        handlerpref id:             mailto (0x1)
        URL scheme:                 mailto
        all roles:                  com.apple.mail

        --------------------------------------------------------------------------------
        extension:                  defaultappunrelatedxyz123
        """
        XCTAssertTrue(DynamicTypeDiscovery.parse(dump).isEmpty)
    }

    func testParsesRoleSpecificPreference() {
        let dump = """
        handlerpref id:             defaultapprolexyz123 (0x8)
        extension:                  defaultapprolexyz123
        viewer roles:               com.example.reader
        """
        XCTAssertEqual(DynamicTypeDiscovery.parse(dump).first?.filenameExtension,
                       "defaultapprolexyz123")
    }
}
