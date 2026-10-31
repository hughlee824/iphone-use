import XCTest
@testable import IPhoneUseCore

final class NativeDisplayTests: XCTestCase {
    // Sanitized iPhone 12 Pro topology while its native media stream is open.
    func legacyMediaInventory() -> [String: Any] {
        ["backlightState": "activeOn", "displays": [
            ["primary": true, "displayId": 1, "type": ["integrated": [:]],
             "bounds": [[0, 0], [1170, 2532]], "pointScale": 3,
             "currentOrientation": "rot0", "nativeOrientation": "rot0", "backlightState": "activeOn"],
            ["primary": false, "displayId": 2, "type": ["wireless": [:]], "uniqueId": "wireless",
             "bounds": [[0, 0], [1184, 2544]], "pointScale": 1,
             "currentOrientation": "rot0", "nativeOrientation": "rot0", "backlightState": "off"]
        ]]
    }

    func testLegacyMediaDisplayDoesNotChangePhysicalScreenIdentity() throws {
        let facts = legacyMediaInventory()
        let rows = try XCTUnwrap(facts["displays"] as? [[String: Any]])
        let before = try NativeDisplay(["displays": [rows[0]]])
        let during = try NativeDisplay(facts)
        XCTAssertEqual(before, during)
        XCTAssertEqual(during.screen.width, 390)
        XCTAssertEqual(during.screen.height, 844)
        XCTAssertEqual(during.screenshotArguments(destination: URL(fileURLWithPath: "/tmp/screen.png")),
                       ["device", "capture", "screenshot", "--destination", "/tmp/screen.png"])
    }

    func testLegacyFallbackRejectsUnknownOrPotentiallyActiveAdditionalDisplays() throws {
        for change: [String: Any] in [
            ["backlightState": "activeOn"], ["backlightState": "unknown"],
            ["active": true], ["active": false], ["primary": true],
            ["type": ["integrated": [:]]], ["type": ["unknown": [:]]]
        ] {
            var facts = legacyMediaInventory()
            var rows = try XCTUnwrap(facts["displays"] as? [[String: Any]])
            rows[1].merge(change) { _, new in new }
            facts["displays"] = rows
            XCTAssertThrowsError(try NativeDisplay(facts))
        }
    }

    // Sanitized topology observed on a foldable: primary stays on the outer screen.
    func inventory(inner: Bool) -> [String: Any] {
        ["backlightState": "activeOn", "displays": [
            ["primary": true, "active": !inner, "displayId": 1, "uniqueId": "outer",
             "bounds": [[0, 0], [1398, 2034]], "pointScale": 3,
             "currentOrientation": "rot0", "nativeOrientation": "rot0",
             "backlightState": inner ? "off" : "activeOn"],
            ["primary": false, "active": inner, "displayId": 2, "uniqueId": "inner",
             "bounds": [[0, 0], [2007, 2853]], "pointScale": 3,
             "currentOrientation": "rot90", "nativeOrientation": "rot0",
             "backlightState": inner ? "activeOn" : "off"]
        ]]
    }

    func testFoldSelectsActiveSurfaceAndBindsScreenshotIdentity() throws {
        let outer = try NativeDisplay(inventory(inner: false))
        let inner = try NativeDisplay(inventory(inner: true))
        XCTAssertEqual(outer.id, 1)
        XCTAssertEqual(inner.id, 2)
        XCTAssertTrue(inner.backlightOn)
        XCTAssertEqual(inner.screen.width, 951)
        XCTAssertEqual(inner.screen.height, 669)
        XCTAssertNotEqual(outer.geometry, inner.geometry)
        XCTAssertEqual(inner.screenshotArguments(destination: URL(fileURLWithPath: "/tmp/screen.png")),
                       ["device", "capture", "screenshot", "--display-unique-id", "inner",
                        "--destination", "/tmp/screen.png"])
    }

    func testAmbiguousOrIncompleteActivityIsRejected() throws {
        for activity: [Bool?] in [[true, true], [false, false], [nil, true]] {
            var facts = inventory(inner: true)
            var rows = try XCTUnwrap(facts["displays"] as? [[String: Any]])
            for index in rows.indices { rows[index]["active"] = activity[index] }
            facts["displays"] = rows
            XCTAssertThrowsError(try NativeDisplay(facts))
        }
    }

    func testInnerRequiresIdentityAndUsesOwnBacklight() throws {
        var facts = inventory(inner: true)
        var rows = try XCTUnwrap(facts["displays"] as? [[String: Any]])
        rows[1]["uniqueId"] = nil
        facts["displays"] = rows
        XCTAssertThrowsError(try NativeDisplay(facts))
        rows[1]["uniqueId"] = "inner"
        for backlight: String? in [nil, "off", "futureState"] {
            rows[1]["backlightState"] = backlight
            facts["displays"] = rows
            XCTAssertFalse(try NativeDisplay(facts).backlightOn)
        }
    }
}
