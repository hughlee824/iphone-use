import XCTest
@testable import IPhoneUseCore

final class ExplicitRunnerActionTests: XCTestCase {
    func testExplicitOperationsRejectImplicitEditsAndStandardTargets() throws {
        for operation in ["focus", "clear", "double-tap", "long-press"] {
            XCTAssertNoThrow(try DeviceAction(operation: operation, request: ["reference": "o1:e1"]))
            XCTAssertThrowsError(try DeviceAction(operation: operation, request: ["reference": "o1:e1"],
                                                 allowScreenText: true))
        }
        for mode in ["replace", "append"] {
            XCTAssertThrowsError(try DeviceAction(operation: "type", request: [
                "reference": "o1:e1", "mode": mode, "text": "new"
            ])) { XCTAssertEqual(($0 as? IPhoneUseError)?.code, "explicit_edit_required") }
        }
        for key in ["select-all", "end"] {
            XCTAssertNoThrow(try DeviceAction(operation: "press", request: ["reference": "o1:e1", "key": key]))
        }
    }

    func testImageGuardDefaultsArePerBackendAndCannotSilentlyApplyToElements() throws {
        let point: [String: Any] = ["reference": "o1", "x": 100, "y": 200]
        XCTAssertEqual(try DeviceAction(operation: "tap", request: point).guardPolicy.maxScreenChange, 1)
        XCTAssertEqual(try DeviceAction(operation: "tap", request: point,
                                       allowScreenText: true).guardPolicy.maxScreenChange, 0.01)
        XCTAssertThrowsError(try DeviceAction(operation: "tap", request: [
            "reference": "o1:e1", "maxScreenChange": 0.01
        ])) { XCTAssertEqual(($0 as? IPhoneUseError)?.code, "coordinate_guard_required") }
    }

    func testOnlyVerifiedFocusAndClearNoOpsCanCompleteWithoutDispatch() throws {
        for kind in ["focus", "clear", "type", "press", "tap"] {
            for verification in ["confirmed", "unconfirmed", "unavailable"] {
                let reply: [String: Any] = ["ok": true,
                    "execution": ["started": false, "completed": true],
                    "result": ["kind": kind, "noOp": true, "inputAction": [
                        "eventAttempted": false, "eventAcknowledged": false, "verification": verification
                    ]]]
                if ["focus", "clear"].contains(kind), verification == "confirmed" {
                    XCTAssertNoThrow(try ActionReply.decode(reply))
                } else {
                    XCTAssertThrowsError(try ActionReply.decode(reply))
                }
            }
        }
    }
}
