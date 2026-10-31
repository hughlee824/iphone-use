import XCTest
@testable import IPhoneUseCore

final class NativeTouchSurfaceTests: XCTestCase {
    private func surface(_ id: Int, display: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["PrimaryUsagePage": 13, "PrimaryUsage": 4,
                                   "UniversalControlBuiltIn": true, "_ServiceID": id]
        value["displayUUID"] = display
        return value
    }

    func testSelectsExactDisplayRegardlessOfInventoryOrder() throws {
        let outer = surface(257, display: "outer"), inner = surface(258, display: "inner")
        for inventory in [[outer, inner], [inner, outer]] {
            XCTAssertEqual(try NativeTouchSurface.select(inventory, displayUniqueID: "outer").id, 257)
            XCTAssertEqual(try NativeTouchSurface.select(inventory, displayUniqueID: "inner").id, 258)
            XCTAssertThrowsError(try NativeTouchSurface.select(inventory, displayUniqueID: nil))
            XCTAssertThrowsError(try NativeTouchSurface.select(inventory, displayUniqueID: "missing"))
        }
    }

    func testRejectsAmbiguousForeignAndMalformedSurfaces() throws {
        let outer = surface(257, display: "outer")
        var foreign = surface(258, display: "outer"); foreign["UniversalControlBuiltIn"] = false
        XCTAssertEqual(try NativeTouchSurface.select([outer, foreign], displayUniqueID: "outer").id, 257)
        for inventory in [[outer, surface(258, display: "outer")],
                          [outer, surface(257, display: "inner")],
                          [surface(257), surface(258)], [foreign]] {
            XCTAssertThrowsError(try NativeTouchSurface.select(inventory, displayUniqueID: "outer"))
        }
        for invalid: Any in [true, 0, -1, 1.5, Double.infinity, "257"] {
            var value = outer; value["_ServiceID"] = invalid
            XCTAssertThrowsError(try NativeTouchSurface.select([value], displayUniqueID: "outer"))
        }
        var malformed = outer; malformed["displayUUID"] = 123
        XCTAssertThrowsError(try NativeTouchSurface.select([malformed], displayUniqueID: "outer"))
        XCTAssertThrowsError(try NativeTouchSurface.select([outer, surface(258)], displayUniqueID: "inner"))
    }

    func testLegacySingleSurfaceAndRebindingDoNotSendInput() throws {
        XCTAssertEqual(try NativeTouchSurface.select([surface(987)], displayUniqueID: nil).id, 987)
        let transport = ScriptedTransport()
        var inventory = [surface(257, display: "outer"), surface(258, display: "inner")]
        transport.onRequest = { _ in ["connectedServices": inventory] }
        let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation())
        try hid.prepare(displayUniqueID: "outer")
        XCTAssertEqual(hid.surface, 257)
        try hid.prepare(displayUniqueID: "inner")
        XCTAssertEqual(hid.surface, 258)
        XCTAssertEqual(hid.surfaceDisplayUniqueID, "inner")
        hid.contact = (10, 20)
        XCTAssertThrowsError(try hid.prepare(displayUniqueID: "outer"))
        XCTAssertEqual(hid.surface, 258, "Never reroute a contact's release to another display")
        hid.contact = nil
        inventory = [surface(257, display: "outer")]
        XCTAssertThrowsError(try hid.prepare(displayUniqueID: "inner"))
        XCTAssertNil(hid.surface, "An invalid inventory must not leave a stale routable surface")
        XCTAssertTrue(transport.sends.isEmpty)
    }
}
