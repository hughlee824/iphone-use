import Foundation
import XCTest
@testable import IPhoneUseCore

extension AXPObservationTests {
    func keyboardRecord(_ id: Int, type: String, label: String, children: [[String: Any]] = []) -> [String: Any] {
        var node = record(id, label: label, children: children)
        var native = node["attributes"] as? [String: Any] ?? [:]
        native["5003"] = type
        native["2025"] = true
        node["attributes"] = native
        return node
    }

    func keyboardPayload() -> [String: Any] {
        let letter = keyboardRecord(3, type: "UIAccessibilityElementKBKey", label: "q")
        let next = keyboardRecord(4, type: "UIAccessibilityElementKBKey", label: "next")
        var keys = keyboardRecord(2, type: "UIKeyboardLayoutStar", label: "Keyboard", children: [letter, next])
        var keyboardAttributes = keys["attributes"] as? [String: Any] ?? [:]
        keyboardAttributes.removeValue(forKey: "2025")
        keys["attributes"] = keyboardAttributes
        let field = keyboardRecord(5, type: "UITextField", label: "Name")
        var root = record(1, children: [keys, field])
        var rootAttributes = root["attributes"] as? [String: Any] ?? [:]
        rootAttributes.removeValue(forKey: "2025")
        root["attributes"] = rootAttributes
        var value = payload(tree: root)
        let extra = keyboardRecord(6, type: "UITableTextAccessibilityElement", label: "Security, WPA2")
        value["collectionStrategy"] = "full_tree_candidate_visibility_keyboard_batch_v1"
        value["visibilityCoverage"] = "semantic_candidates"
        value["candidateCount"] = 4
        value["keyboardBatchedCandidateCount"] = 2
        value["supplementalElements"] = [[
            "element": extra["element"]!, "attributes": extra["attributes"]!, "reportedChildCount": 2,
            "parent": NSNull(), "hierarchyKnown": false, "childrenTraversed": false
        ]]
        return value
    }

    func testCombinedCollectionKeepsRawKeyboardAndSeparateCompositeInSharedCache() throws {
        let initial = try screenshot()
        let capture = try AXPObservation.capture(
            device: "device", generation: "generation", read: { _ in self.keyboardPayload() },
            screenshot: { initial }, checkCancellation: {})
        XCTAssertEqual(capture.nodes.count, 6)
        XCTAssertEqual(capture.nodes.map(\.parent), [nil, 0, 1, 1, 0, nil])
        XCTAssertEqual(capture.nodes[2].attributes["visible"] as? Bool, true)
        XCTAssertEqual(capture.nodes[5].attributes["hierarchyKnown"] as? Bool, false)
        XCTAssertEqual(capture.nodes[5].attributes["reportedChildCount"] as? Int, 2)
        XCTAssertNil(capture.nodes[5].attributes["identityToken"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        let output = try cache.store(capture)
        let text = try XCTUnwrap(output["text"] as? String)
        XCTAssertFalse(text.contains("\"q\""))
        XCTAssertTrue(text.contains("\"next\""))
        XCTAssertTrue(text.contains("keyboard \"Keyboard\""))
        XCTAssertTrue(text.contains("presentation_selection=semantic_candidates_and_keyboard_context"))
        XCTAssertTrue(text.contains("Security, WPA2"))
        XCTAssertTrue(text.contains("keyboard_character_keys_omitted=1"))
        let query = try cache.inspect(ObservationReference("o1"), offset: 0, query: "q")
        XCTAssertTrue((query["text"] as? String)?.contains("o1:e3") == true)
        let raw = try jsonObject(Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(output["snapshot"] as? String))))
        let saved = try XCTUnwrap(raw["nodes"] as? [[String: Any]])
        XCTAssertEqual(saved.count, 6)
        XCTAssertEqual(saved[2]["label"] as? String, "q")
        XCTAssertEqual((saved[2]["nativeAttributes"] as? [String: Any])?["2025"] as? Bool, true)
        XCTAssertEqual((saved[2]["nativeElement"] as? [String: Any])?["objectID"] as? String, "3")
        XCTAssertEqual(try cache.resolveCurrent(ObservationReference("o1:e3")).parent, 1)
        let action = try DeviceAction(operation: "tap", request: ["reference": "o1:e3"])
        XCTAssertThrowsError(try cache.resolveTarget(for: action)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_action_unsupported")
        }
    }

    func testInvalidSupplementCannotPublishPartialAX() throws {
        for mutation in 0..<7 {
            var value = keyboardPayload()
            var supplement = try XCTUnwrap(value["supplementalElements"] as? [[String: Any]]).first!
            switch mutation {
            case 0: supplement["parent"] = 0
            case 1: supplement["childrenTraversed"] = true
            case 2: supplement["element"] = ["pid": 999, "objectID": "6", "application": false]
            case 3: supplement["element"] = ["pid": 123, "objectID": "3", "application": false]
            case 4: supplement["reportedChildCount"] = -1
            case 5:
                var fields = try XCTUnwrap(supplement["attributes"] as? [String: Any])
                fields["2025"] = 1
                supplement["attributes"] = fields
            default: value["candidateCount"] = true
            }
            value["supplementalElements"] = [supplement]
            let initial = try screenshot()
            let captured = try AXPObservation.capture(
                device: "device", generation: "generation", read: { _ in value },
                screenshot: { initial }, checkCancellation: {})
            XCTAssertTrue(captured.nodes.isEmpty, "case \(mutation)")
            XCTAssertEqual(captured.metadata["axErrorCode"] as? String, "axp_invalid_snapshot")
            XCTAssertEqual(captured.screenshot, initial.screenshot)
        }
    }
}
