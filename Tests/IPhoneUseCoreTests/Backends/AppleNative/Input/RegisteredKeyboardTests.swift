import Foundation
import XCTest
import AppleNativeBridge
@testable import IPhoneUseCore

private final class RegistrationTransport: NativeTransport {
    var services: [[String: Any]] = []
    var creations = 0, removals = 0
    var reports: [Data] = []
    var normalizedProduct: String?
    var loseCreateReply = false
    var closed = false

    func request(_ message: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        guard !closed else { throw KeyboardXPC.invalid }
        let payload = try XCTUnwrap(message["payload"] as? [String: Any])
        if payload["connectedServices"] != nil { return ["connectedServices": services] }
        let create = try XCTUnwrap(payload["createService"] as? [String: Any])
        let service = try XCTUnwrap(create["_0"] as? [String: Any])
        let id = try XCTUnwrap(service["_ServiceID"] as? ASNativeUnsigned).value
        XCTAssertEqual(id, 0x100002001)
        creations += 1
        let product = try XCTUnwrap(service["Product"] as? String)
        services.append(["_ServiceID": id, "Product": normalizedProduct ?? product])
        if loseCreateReply { throw KeyboardXPC.invalid }
        return ["serviceID": id]
    }
    func send(_ message: [String: Any], timeout: TimeInterval) throws {
        guard !closed else { throw KeyboardXPC.invalid }
        let payload = try XCTUnwrap(message["payload"] as? [String: Any])
        if let remove = payload["removeService"] as? [String: Any] {
            XCTAssertEqual((remove["_0"] as? ASNativeUnsigned)?.value, 0x100002001)
            removals += 1; services = []; return
        }
        let send = try XCTUnwrap(payload["send"] as? [String: Any])
        XCTAssertEqual((send["_1"] as? ASNativeUnsigned)?.value, 0x100002001)
        reports.append(try XCTUnwrap(send["_0"] as? Data))
    }
    func cancel() { closed = true }
}

final class RegisteredKeyboardTests: XCTestCase {
    func testPasteSendsModifierShortcutAndReleaseOnRegisteringConnection() throws {
        var now = 0.0, opens = 0
        let builtin = KeyboardTransport(), direct = RegistrationTransport()
        let hid = NativeHIDAdapter(transport: builtin, cancellation: NativeCancellation(),
                                   wait: { now += $0 }, uptime: { now })
        try hid.prepare()
        hid.registeredKeyboard = RegisteredKeyboard { opens += 1; return direct }
        try hid.prepareKeyboard()
        try hid.prepareKeyboard()
        _ = try hid.paste()
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(direct.creations, 1)
        XCTAssertTrue(builtin.reports.isEmpty)
        XCTAssertEqual(direct.reports.map { Array($0.prefix(31)) }, [[0xe3], [0xe3, 0x19], []].map {
            Array(NativeKeyboard.report($0, timestamp: 0).prefix(31))
        })
        XCTAssertEqual(hid.closeKeyboard()["keyboardRemoveAcknowledged"] as? Bool, true)
        _ = hid.closeKeyboard()
        XCTAssertEqual(direct.removals, 1)
        XCTAssertTrue(direct.closed)
    }

    func testCollisionAndReplacementPreserveForeignKeyboard() throws {
        let transport = RegistrationTransport()
        let occupied: [[String: Any]] = [["_ServiceID": UInt64(0x100002001), "Product": "another owner"]]
        transport.services = occupied
        let first = RegisteredKeyboard { transport }
        XCTAssertThrowsError(try first.prepare())
        XCTAssertEqual(transport.creations, 0)
        XCTAssertEqual(first.close()["keyboardRemovalRequired"] as? Bool, false)

        let secondTransport = RegistrationTransport()
        let second = RegisteredKeyboard { secondTransport }
        _ = try second.prepare()
        secondTransport.services = occupied
        XCTAssertEqual(second.close()["keyboardRemoveAcknowledged"] as? Bool, false)
        XCTAssertEqual(secondTransport.removals, 0)
    }

    func testNormalizedInventoryBindsNewIDToCreateReceiptAndRechecksBeforeRemoval() throws {
        let transport = RegistrationTransport()
        transport.normalizedProduct = "Keyboard"
        let keyboard = RegisteredKeyboard { transport }
        XCTAssertEqual(try keyboard.prepare(), RegisteredKeyboard.requestedID)
        XCTAssertFalse(keyboard.inventoryVerified)
        transport.services[0]["Product"] = "replacement"
        XCTAssertEqual(keyboard.close()["keyboardRemoveAcknowledged"] as? Bool, false)
        XCTAssertEqual(transport.removals, 0)
    }

    func testCreateReplyLostNeverRegistersAgainOrSendsKeys() {
        let transport = RegistrationTransport()
        transport.loseCreateReply = true
        let keyboard = RegisteredKeyboard { transport }
        XCTAssertThrowsError(try keyboard.prepare())
        XCTAssertThrowsError(try keyboard.prepare())
        XCTAssertThrowsError(try keyboard.send(NativeKeyboard.report([0xe3, 0x19], timestamp: 0)))
        XCTAssertEqual(transport.creations, 1)
        XCTAssertTrue(transport.reports.isEmpty)
        XCTAssertEqual(keyboard.close()["keyboardRemoveAcknowledged"] as? Bool, false)
        XCTAssertEqual(transport.removals, 0)
    }
}
