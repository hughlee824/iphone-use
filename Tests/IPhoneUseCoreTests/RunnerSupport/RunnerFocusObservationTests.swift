import XCTest
@testable import IPhoneUseCore

final class RunnerFocusObservationTests: XCTestCase {
    func testFocusStateRendersWithoutInferringFromKeyboardOrEnabled() throws {
        for value: Any in [true, false, NSNull()] {
            let attributes: [String: Any] = [
                "label": "Note", "value": "", "enabled": true, "keyboardFocus": value
            ]
            let node = AXNode(index: 0, parent: nil, role: "text_view", attributes: attributes)
            let text = CompactAX.render([node]).joined(separator: "\n")
            if let expected = value as? Bool {
                XCTAssertTrue(text.contains("keyboard_focus=\(expected)"))
            } else {
                XCTAssertFalse(text.contains("keyboard_focus="))
            }
        }
        let old = AXNode(index: 0, parent: nil, role: "text_view", attributes: ["enabled": true])
        XCTAssertFalse(CompactAX.render([old])[0].contains("keyboard_focus="))
    }

    func testOnlyVerifiedFocusNoOpMayOmitStability() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input: [String: Any] = [
            "eventAttempted": false, "eventAcknowledged": false,
            "verification": "confirmed", "automaticReplayAllowed": false
        ]
        let result: [String: Any] = [
            "kind": "focus", "noOp": true, "resultVerified": true, "inputAction": input
        ]
        let response: [String: Any] = [
            "ok": true, "result": result,
            "execution": ["started": false, "completed": true, "inputCompleted": true]
        ]
        let decoded = try XCTestCapture.actionResponse(response, directory: directory, expectedFocus: true)
        let facts = try XCTUnwrap(decoded["result"] as? [String: Any])
        XCTAssertNil(facts["observationError"])
        XCTAssertNil(facts["frame"])
        XCTAssertNil(facts["stability"])
        let wrongCommand = try XCTestCapture.actionResponse(response, directory: directory)
        XCTAssertNotNil((wrongCommand["result"] as? [String: Any])?["observationError"])
        for (key, value): (String, Any) in [
            ("eventAttempted", true), ("eventAcknowledged", true),
            ("verification", "unconfirmed"), ("verification", "unavailable"),
            ("automaticReplayAllowed", true)
        ] {
            var changedInput = input; changedInput[key] = value
            var changedResult = result; changedResult["inputAction"] = changedInput
            var changed = response; changed["result"] = changedResult
            let decoded = try XCTestCapture.actionResponse(changed, directory: directory, expectedFocus: true)
            XCTAssertNotNil((decoded["result"] as? [String: Any])?["observationError"], key)
        }
    }
}
