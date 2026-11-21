import XCTest
@testable import IPhoneUseCore

final class PresentedAXTests: XCTestCase {
    private func node(
        _ index: Int, parent: Int? = 0, role: String = "button", label: String = "",
        frame: CGRect = CGRect(x: 10, y: 10, width: 80, height: 20),
        visible: Bool? = nil
    ) -> AXNode {
        var attributes: [String: Any] = [
            "index": index, "parent": parent as Any? ?? NSNull(), "label": label,
            "enabled": true, "identifier": "", "value": "",
            "frame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
        ]
        attributes["visible"] = visible
        return AXNode(index: index, parent: parent, role: role, attributes: attributes)
    }

    private func capture(_ nodes: [AXNode]) -> CapturedObservation {
        CapturedObservation(nodes: nodes, metadata: [
            "screenFrame": ["x": 0.0, "y": 0.0, "width": 390.0, "height": 844.0],
            "axStatus": "available", "scope": "app"
        ], screenshot: Data())
    }

    func testSourceHiddenNodesAreOmittedButRemainQueryableInCapture() throws {
        var nodes = [node(0, parent: nil, role: "application")]
        nodes += (1...100).map { node($0, label: "Background \($0)", visible: false) }
        nodes.append(node(101, role: "text_field", label: "Last name"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        let result = try cache.store(capture(nodes))
        let text = try XCTUnwrap(result["text"] as? String)
        XCTAssertTrue(text.contains("[e102] text_field \"Last name\""))
        XCTAssertFalse(text.contains("Background"))
        let query = try cache.inspect(ObservationReference("o1"), offset: 0, query: "Background 99")
        XCTAssertTrue((query["text"] as? String)?.contains("o1:e100") == true)
        XCTAssertEqual(try cache.resolveCurrent(ObservationReference("o1:e100")).label, "Background 99")
    }

    func testViewportAndScrollableAncestorsClipOffscreenDescendants() {
        let nodes = [
            node(0, parent: nil, role: "application"),
            node(1, role: "scroll_view", frame: CGRect(x: 0, y: 100, width: 390, height: 200)),
            node(2, parent: 1, label: "In viewport", frame: CGRect(x: 10, y: 110, width: 80, height: 20)),
            node(3, parent: 1, label: "Below scroll viewport", frame: CGRect(x: 10, y: 400, width: 80, height: 20)),
            node(4, label: "Offscreen", frame: CGRect(x: 10, y: 900, width: 80, height: 20)),
            node(5, label: "Partially onscreen", frame: CGRect(x: 10, y: 830, width: 80, height: 30)),
            node(6, label: "Hidden by source", visible: false)
        ]
        XCTAssertEqual(PresentedAX.project(capture(nodes)).indices, [0, 1, 2, 5])
    }

    func testUnknownHierarchyDoesNotInventOcclusionOrDropBackgroundByOrder() {
        let nodes = [node(0, parent: nil, role: "application"),
                     node(1, label: "First"), node(2, label: "Second")]
        let projection = PresentedAX.project(capture(nodes))
        XCTAssertFalse(projection.hierarchyKnown)
        XCTAssertEqual(projection.indices, [0, 1, 2])
    }

    func testCompactTreeHasNoSixtyLineCutoff() throws {
        var nodes = [node(0, parent: nil, role: "application")]
        nodes += (1...75).map { node($0, label: "Visible \($0)") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try ObservationCache(directory: directory).store(capture(nodes))
        let text = try XCTUnwrap(result["text"] as? String)
        XCTAssertTrue(text.contains("Visible 75"))
        XCTAssertGreaterThan(text.split(separator: "\n").count, 60)
        XCTAssertFalse(text.contains("unexpanded="))
    }
}
