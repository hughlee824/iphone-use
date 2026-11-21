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
        XCTAssertTrue(text.contains("\n[app] example.test @0,0,390,844\n"))
        XCTAssertTrue(text.contains("Security, WPA2"))
        XCTAssertEqual(PresentedAX.project(capture).omittedKeyboardCharacters, 1)
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

    func testUnknownCandidateStaysInspectableWithoutAVisibleTarget() throws {
        var payload = keyboardPayload()
        var supplements = try XCTUnwrap(payload["supplementalElements"] as? [[String: Any]])
        var native = try XCTUnwrap(supplements[0]["attributes"] as? [String: Any])
        native["2025"] = NSNull()
        supplements[0]["attributes"] = native
        payload["supplementalElements"] = supplements
        let initial = try screenshot()
        let capture = try AXPObservation.capture(
            device: "device", generation: "generation", read: { _ in payload },
            screenshot: { initial }, checkCancellation: {})
        let collection = try XCTUnwrap(capture.metadata["axCollection"] as? [String: Any])
        XCTAssertEqual(collection["unknownVisibilityCandidateCount"] as? Int, 1)
        let node = try XCTUnwrap(capture.nodes.last)
        XCTAssertNil(node.attributes["visible"])
        XCTAssertEqual(node.attributes["candidateVisibilityUnknown"] as? Bool, true)
        XCTAssertFalse(PresentedAX.project(capture).indices.contains(node.index))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        _ = try cache.store(capture)
        let ref = try ObservationReference("o1:e6")
        let detail = try cache.inspect(ref, offset: 0)
        XCTAssertTrue((detail["text"] as? String)?.contains("Security, WPA2") == true)
        XCTAssertEqual(try cache.resolveCurrent(ref).label, "Security, WPA2")
        let action = try DeviceAction(operation: "tap", request: ["reference": "o1:e6"])
        XCTAssertThrowsError(try cache.resolveTarget(for: action)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_action_unsupported")
        }
    }

    func testOmittedSupplementReportsPartialSourceAndPreservesCollectedControls() throws {
        var value = keyboardPayload()
        value["candidateCount"] = 5
        value["keyboardWindowProbed"] = true
        value["omittedSupplementalCandidateCount"] = 1
        value["keyboardWindowMatchedCount"] = 0
        let initial = try screenshot()
        let capture = try AXPObservation.capture(
            device: "device", generation: "generation", read: { _ in value },
            screenshot: { initial }, checkCancellation: {})
        XCTAssertEqual(capture.metadata["axStatus"] as? String, "available")
        XCTAssertEqual(capture.metadata["sourceTruncated"] as? Bool, true)
        XCTAssertEqual(capture.nodes.count, 6)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try ObservationCache(directory: directory).store(capture)
        let text = try XCTUnwrap(output["text"] as? String)
        XCTAssertTrue(text.contains("ax_omitted_supplemental_candidates=1"))
        XCTAssertTrue(text.contains("truncated=true"))
        XCTAssertTrue(text.contains("Security, WPA2"))
        for malformed in [0, -1, 2, 6] {
            value["omittedSupplementalCandidateCount"] = malformed
            let bad = try AXPObservation.capture(
                device: "device", generation: "generation", read: { _ in value },
                screenshot: { initial }, checkCancellation: {})
            XCTAssertEqual(bad.metadata["axErrorCode"] as? String, "axp_invalid_snapshot")
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
