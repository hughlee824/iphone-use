import Foundation
import XCTest
import IPhoneUseRunnerSupport
@testable import IPhoneUseCore

final class AXPObservationTests: XCTestCase {
    func record(_ id: Int, label: String = "", children: [[String: Any]] = []) -> [String: Any] {
        ["element": ["pid": 123, "objectID": String(id), "application": id == 1],
         "attributes": ["2001": label, "3003": "example.test", "5004": id == 1 ? "UIApplication" : "UILabel",
                        "2003": ["x": 0, "y": 0, "width": 390, "height": 844], "2025": false],
         "children": children, "childCount": children.count]
    }

    func payload(tree: [String: Any]? = nil) -> [String: Any] {
        ["version": 1, "deviceID": "device", "rootStable": true, "selectionStable": true,
         "cleanup": ["connectionClosed": true, "tunnelClosed": true, "subscriptionStopAcknowledged": true],
         "startedAt": Date().timeIntervalSince1970, "finishedAt": Date().timeIntervalSince1970,
         "display": ["displayID": 1, "displayUniqueID": "display", "x": 0, "y": 0, "width": 390, "height": 844],
         "tree": tree ?? record(1, children: [record(2, label: "Repeated"), record(3, label: "Repeated")])]
    }

    func screenshot() throws -> CapturedObservation {
        CapturedObservation(nodes: [], metadata: [
            "backend": "apple-native", "deviceID": "device", "sessionGeneration": "generation",
            "displayID": 1, "displayUniqueID": "display", "displayRotation": "rot0", "scope": "screen",
            "screenFrame": ["x": 0, "y": 0, "width": 390, "height": 844],
            "screenContext": try jsonObject(JSONEncoder().encode(screenTestContext())),
            "axStatus": "unavailable", "axError": "not collected"
        ], screenshot: try screenPNG())
    }

    func testAdapterPreservesUnknownStateInvisibleTextAndDuplicateLabels() throws {
        let snapshot = try AXPSnapshot.decode(payload(), device: "device")
        XCTAssertEqual(snapshot.nodes.map(\.parent), [nil, 0, 0])
        XCTAssertEqual(snapshot.nodes.map(\.role), ["application", "text", "text"])
        XCTAssertNil(snapshot.nodes[1].enabled)
        XCTAssertEqual(snapshot.nodes[1].attributes["visible"] as? Bool, false)
        XCTAssertNil(snapshot.nodes[1].attributes["identityToken"])
        let compact = CompactAX.render(snapshot.nodes)
        XCTAssertEqual(compact.filter { $0.contains("Repeated") }.count, 2)
        XCTAssertTrue(compact.allSatisfy { !$0.contains("enabled=") && !$0.contains("disabled") })
    }

    func testOnlyUniqueNativeEditorMatchingAppResponderReportsFocus() throws {
        var editor = record(2)
        var attributes = try XCTUnwrap(editor["attributes"] as? [String: Any])
        attributes["5004"] = "UITextField"
        editor["attributes"] = attributes
        for children in [[editor, record(3)], [editor, editor]] {
            var snapshot = payload(tree: record(1, children: children))
            for token in [["pid": 123, "objectID": "2"], ["pid": 4, "objectID": "2"],
                          ["pid": 123, "objectID": "3"]] as [[String: Any]] {
                snapshot["textResponder"] = token
                let nodes = try AXPSnapshot.decode(snapshot, device: "device").nodes
                let focused = nodes.filter { $0.attributes["keyboardFocus"] as? Bool == true }
                let expected = nodes.last?.role == "text" && token["pid"] as? Int == 123
                    && token["objectID"] as? String == "2"
                XCTAssertEqual(focused.map(\.index), expected ? [1] : [])
            }
        }
    }

    func testRejectsWrongDeviceIncompleteChildrenAndForeignSubtrees() throws {
        XCTAssertThrowsError(try AXPSnapshot.decode(payload(), device: "another"))
        var root = record(1)
        root["childCount"] = 1
        XCTAssertThrowsError(try AXPSnapshot.decode(payload(tree: root), device: "device"))
        var child = record(2)
        child["element"] = ["pid": 456, "objectID": "2", "application": false]
        XCTAssertThrowsError(try AXPSnapshot.decode(payload(tree: record(1, children: [child])), device: "device"))
    }

    func testInvalidGeometryStaysUnavailableAndEmptyValueIsRetained() throws {
        var child = record(2)
        var attributes = try XCTUnwrap(child["attributes"] as? [String: Any])
        attributes["2003"] = NSNull()
        attributes["2006"] = ""
        child["attributes"] = attributes
        let nodes = try AXPSnapshot.decode(payload(tree: record(1, children: [child])), device: "device").nodes
        XCTAssertTrue(nodes[1].attributes["frame"] is NSNull)
        XCTAssertEqual(nodes[1].attributes["value"] as? String, "")
    }

    func testRejectsUnclosedTransportAndInvalidDisplayIdentity() throws {
        var value = payload()
        value["cleanup"] = ["connectionClosed": true, "tunnelClosed": false]
        XCTAssertThrowsError(try AXPSnapshot.decode(value, device: "device"))
        for identity in [true, -1, 1.5] as [Any] {
            value = payload()
            var display = try XCTUnwrap(value["display"] as? [String: Any])
            display["displayID"] = identity
            value["display"] = display
            XCTAssertThrowsError(try AXPSnapshot.decode(value, device: "device"))
        }
    }

    func testOldPayloadFallsBackEvenWhenScreenshotsMatch() throws {
        let initial = try screenshot()
        var old = payload()
        old["startedAt"] = Date().timeIntervalSince1970 - 60
        let result = try AXPObservation.capture(
            device: "device", generation: "generation", read: { _ in old },
            screenshot: { initial }, checkCancellation: {})
        XCTAssertTrue(result.nodes.isEmpty)
        XCTAssertEqual(result.metadata["axErrorCode"] as? String, "axp_context_changed")
    }

    func testReadFailureReturnsLatestScreenshotWithoutNodes() throws {
        let initial = try screenshot()
        var recaptures = 0
        let result = try AXPObservation.capture(
            device: "device", generation: "generation",
            read: { _ in throw IPhoneUseError("test_timeout", "timed out") },
            screenshot: { recaptures += 1; return initial }, checkCancellation: {})
        XCTAssertEqual(recaptures, 1)
        XCTAssertTrue(result.nodes.isEmpty)
        XCTAssertEqual(result.screenshot, initial.screenshot)
        XCTAssertEqual(result.metadata["axStatus"] as? String, "unavailable")
        XCTAssertEqual(result.metadata["axErrorCode"] as? String, "test_timeout")
    }

    func testContextChangeDiscardsTreeAndCancellationDoesNotPublish() throws {
        let initial = try screenshot()
        var changed = initial.metadata
        changed["sessionGeneration"] = "replaced"
        XCTAssertThrowsError(try AXPObservation.capture(
            device: "device", generation: "generation", read: { _ in self.payload() },
            screenshot: { CapturedObservation(nodes: [], metadata: changed, screenshot: initial.screenshot) },
            checkCancellation: {})) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "capture_context_changed")
        }
        XCTAssertThrowsError(try AXPObservation.capture(
            device: "device", generation: "generation", read: { _ in self.payload() }, screenshot: { initial },
            checkCancellation: { throw IPhoneUseError("cancelled", "closed") }))
    }

    func testChangedPixelsKeepAXButInvalidatePreviousReadiness() throws {
        let original = try screenshot()
        var metadata = original.metadata
        metadata["postActionStability"] = ["stable": true, "frameHash": "old"]
        let initial = CapturedObservation(nodes: [], metadata: metadata, screenshot: original.screenshot)
        let changed = CapturedObservation(
            nodes: [], metadata: original.metadata,
            screenshot: try screenPNG(patches: [(CGRect(x: 50, y: 50, width: 80, height: 80), [0, 0, 0])]))
        let result = try AXPObservation.capture(
            device: "device", generation: "generation", previous: initial,
            read: { _ in self.payload() }, screenshot: { changed }, checkCancellation: {})
        XCTAssertEqual(result.nodes.count, 3)
        XCTAssertEqual(result.metadata["axStatus"] as? String, "available")
        XCTAssertNil(result.metadata["axScreenConsistent"])
        XCTAssertEqual(result.screenshot, changed.screenshot)
        let readiness = result.metadata["postActionStability"] as? [String: Any]
        XCTAssertEqual(readiness?["stable"] as? Bool, false)
        XCTAssertNil(readiness?["frameHash"])
    }

    func testSharedCacheQueriesAXButStandardStillRejectsElementActions() throws {
        let initial = try screenshot()
        let capture = try AXPObservation.capture(
            device: "device", generation: "generation", read: { _ in self.payload() },
            screenshot: { initial }, checkCancellation: {})
        XCTAssertEqual(capture.nodes.count, 3)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        let output = try cache.store(capture)
        XCTAssertEqual(output["observation"] as? String, "o1")
        XCTAssertEqual(capture.metadata["axElementActions"] as? Bool, false)
        let query = try cache.inspect(ObservationReference("o1"), offset: 0, query: "Repeated")
        XCTAssertTrue((query["text"] as? String)?.contains("matched_nodes=2") == true)
        for operation in ["tap", "focus", "clear", "type", "press"] {
            var request: [String: Any] = ["reference": "o1:e2"]
            if operation == "type" { request["text"] = "never sent"; request["mode"] = "insert" }
            if operation == "press" { request["key"] = "return" }
            let action = try DeviceAction(operation: operation, request: request)
            XCTAssertThrowsError(try cache.resolveTarget(for: action)) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_action_unsupported")
            }
        }
        let tap = try DeviceAction(operation: "tap", request: ["reference": "o1", "x": 100, "y": 200])
        XCTAssertNotNil(try cache.resolveTarget(for: tap).gesture)
        let protectedTap = try DeviceAction(operation: "tap", request: [
            "reference": "o1", "x": 100, "y": 200, "protect": ["o1:e2"]])
        XCTAssertThrowsError(try cache.resolveTarget(for: protectedTap)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_action_unsupported")
        }
        _ = try cache.store(initial)
        XCTAssertThrowsError(try cache.resolveTarget(for: tap)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "stale_reference")
        }
        XCTAssertTrue((try cache.inspect(ObservationReference("o1"), offset: 0, query: "Repeated")["text"] as? String)?
            .contains("matched_nodes=2") == true)
    }
}
