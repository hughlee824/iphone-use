import XCTest
@testable import IPhoneUseCore

extension StandardCompactAXTests {
    private func changed(_ node: AXNode, _ attributes: [String: Any]) -> AXNode {
        AXNode(index: node.index, parent: node.parent, role: node.role,
               attributes: node.attributes.merging(attributes) { _, new in new })
    }

    func testClippedNativeListCellRestoresOnlyOwnedStaticText() {
        let leaf = node(3, 2, ("unknown", ""), "General", (188, 28))
        let cellType = ["nativeAttributes": ["5004": "UICollectionViewListCell"]]
        let input = capture([
            node(0, nil, ("collection_view", ""), "", (0, 200), visible: true),
            changed(node(1, 0, ("unknown", ""), "", (180, 50)), cellType),
            changed(node(2, 1, ("unknown", ""), "Wrapper", (180, 50)), ["nativeAttributes": ["2004": 0x41]]),
            changed(leaf, ["nativeAttributes": ["2004": 0x40]]),
            changed(node(4, 1, ("unknown", ""), "Action", (188, 12)), ["nativeAttributes": ["2004": 0x41]]),
            changed(node(5, 0, ("unknown", ""), "", (220, 50)), cellType),
            node(6, 5, ("text", ""), "Recycled", (188, 12)),
            node(7, 0, ("group", ""), "", (140, 30)),
            node(8, 7, ("text", ""), "Unowned", (142, 15))
        ])
        let lines = StandardCompactAX.lines(input, id: "o1")
        XCTAssertEqual(Array(lines.suffix(2)), [
            "  [e2?] row @0,180,100,50 clip=0,180,100,20",
            "    [e4?] text \"General\" @0,188,100,28 clip=0,188,100,12"
        ])
        XCTAssertEqual(PresentedAX.project(input).indices, [0])
        XCTAssertNil(input.nodes[3].attributes["visible"])
        XCTAssertEqual(input.nodes[3].role, "unknown")
    }

    func testUnnamedButtonOwnsOnlyDirectTextInItsExposedFrame() {
        let button = node(0, nil, ("button", ""), "", (12, 40), visible: true)
        let source = capture([
            changed(button, ["value": "4 unread"]),
            node(1, 0, ("text", ""), "Messages", (46, 12)),
            node(2, 0, ("text", ""), "Outside", (60, 12)),
            node(3, 0, ("text", ""), "Hidden", (20, 12), visible: false),
            node(4, 0, ("group", ""), "", (12, 40)),
            node(5, 4, ("text", ""), "Nested", (20, 12)),
            node(6, nil, ("button", ""), "", (80, 40)),
            node(7, 6, ("text", ""), "Unknown owner", (84, 12))
        ])
        XCTAssertEqual(Array(StandardCompactAX.lines(source, id: "o1").dropFirst()), [
            "[e1] button ax_value=\"4 unread\" @0,12,100,40",
            "  [e2?] text \"Messages\" @0,46,100,12 clip=0,46,100,6"
        ])
        XCTAssertEqual(PresentedAX.project(source).indices, [0])
    }

    func testRowControlOnlyFoldsFullyRepresentedTextOrValue() {
        let source = capture([
            node(0, nil, ("table", ""), "", (0, 200), visible: true),
            node(1, 0, ("cell", ""), "Unread", (10, 80)),
            node(2, 1, ("button", ""), "Done, Here, now", (12, 30), visible: true),
            node(3, 2, ("text", ""), "Done", (12, 12)),
            node(4, 2, ("text", ""), "Here, now", (25, 12)),
            changed(node(5, 1, ("button", ""), "Title", (48, 30), visible: true), ["value": "2"]),
            changed(node(6, 5, ("text", ""), "Title", (48, 12)), ["value": "2"]),
            node(7, 5, ("text", ""), "2", (62, 12)),
            changed(node(8, 5, ("text", ""), "Title", (49, 12)), ["value": "Unique status"]),
            node(9, 5, ("text", ""), "Tit", (51, 12)),
            node(10, 0, ("cell", ""), "", (100, 40)),
            node(11, 10, ("text", ""), "Here, now", (105, 12))
        ])
        let lines = StandardCompactAX.lines(source, id: "o1")
        for hidden in ["[e4?]", "[e5?]", "[e7?]", "[e8?]"] { XCTAssertFalse(lines.contains { $0.contains(hidden) }) }
        for kept in ["Unread", "Unique status", "\"Tit\"", "[e12?] text \"Here, now\""] {
            XCTAssertTrue(lines.contains { $0.contains(kept) }, kept)
        }
    }

    func testUnknownImagesRequireUnbrokenGeometryToRow() throws {
        let source = capture([
            node(0, nil, ("table", ""), "", (0, 200), visible: true),
            node(1, 0, ("cell", ""), "", (10, 60)),
            node(2, 1, ("group", ""), "", (25, 15)),
            node(3, 2, ("image", ""), "Badge", (34, 12)),
            node(4, 2, ("image", ""), "Outside", (42, 12)),
            AXNode(index: 5, parent: 1, role: "group", attributes: [:]),
            node(6, 5, ("image", ""), "Unproven", (34, 12)),
            node(7, 5, ("image", ""), "Confirmed", (34, 12), visible: true)
        ])
        let lines = StandardCompactAX.lines(source, id: "o1")
        XCTAssertTrue(lines.contains { $0.contains("[e4?] image \"Badge\" @0,34,100,12 clip=0,34,100,6") })
        XCTAssertFalse(lines.contains { $0.contains("Outside") || $0.contains("Unproven") })
        XCTAssertTrue(lines.contains { $0.contains("image \"Confirmed\" @") })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        _ = try cache.store(source)
        let detail = try cache.inspect(ObservationReference("o1:e7"), offset: 0)
        XCTAssertTrue((detail["text"] as? String)?.contains("Unproven") == true)
        let action = try DeviceAction(operation: "tap", request: ["reference": "o1:e4"])
        XCTAssertThrowsError(try cache.resolveTarget(for: action)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_action_unsupported")
        }

        // Historical snapshots can include unknown images in the initial presentation.
        var metadata = source.metadata
        metadata.removeValue(forKey: "axCollection")
        let legacy = CapturedObservation(nodes: source.nodes, metadata: metadata, screenshot: Data())
        XCTAssertTrue(PresentedAX.project(legacy).indices.contains(6))
        XCTAssertFalse(StandardCompactAX.lines(legacy, id: "o1").contains { $0.contains("Unproven") })
        metadata.removeValue(forKey: "screenFrame")
        let unlocated = CapturedObservation(nodes: source.nodes, metadata: metadata, screenshot: Data())
        XCTAssertFalse(StandardCompactAX.lines(unlocated, id: "o1").contains { $0.contains("Badge") })
    }
}
