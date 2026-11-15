import XCTest
@testable import IPhoneUseCore

final class PresentedChildControlsTests: XCTestCase {
    private func capture(_ name: String) throws -> CapturedObservation {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "native-\(name)", withExtension: "json"))
        let fixture = try jsonObject(Data(contentsOf: file))
        let records = try XCTUnwrap(fixture["nodes"] as? [[String: Any]])
        return CapturedObservation(nodes: try records.map { fields in
            AXNode(index: try XCTUnwrap(fields["index"] as? Int), parent: fields["parent"] as? Int,
                   role: try XCTUnwrap(fields["role"] as? String), attributes: fields)
        }, metadata: try XCTUnwrap(fixture["metadata"] as? [String: Any]), screenshot: try screenPNG())
    }

    func testSettingsHomeSnapshotRetainsContentWithoutExtraChildren() throws {
        let source = try capture("settings-home")
        let projection = PresentedAX.project(source)
        let lines = CompactAX.render(source.nodes, including: projection.indices)
        XCTAssertEqual(source.nodes.count, 144)
        XCTAssertEqual(projection.unqueriedChildControls, 0)
        XCTAssertEqual(lines.count, 13)
        for label in ["Settings", "Airplane Mode", "Bluetooth, On", "Cellular", "Search"] {
            XCTAssertTrue(lines.contains { $0.contains(label) }, label)
        }
    }

    func testWLANRestoreNineIndependentInfoControlsWithOriginalParentsAndUnknownVisibility() throws {
        let source = try capture("wlan")
        let projection = PresentedAX.project(source)
        let lines = CompactAX.render(source.nodes, including: projection.indices)
        let info = source.nodes.filter { $0.label == "More Info" }
        let added = info.filter { projection.indices.contains($0.index) }
        XCTAssertEqual(info.count, 11)
        XCTAssertEqual(added.count, 9)
        XCTAssertEqual(projection.unqueriedChildControls, 9)
        XCTAssertEqual(lines.count, 25)
        for node in added {
            let parent = try XCTUnwrap(node.parent)
            XCTAssertTrue(projection.indices.contains(parent))
            XCTAssertTrue(lines.contains { $0.hasPrefix("  [\(node.ref)]") && $0.contains("More Info") })
            XCTAssertNil(node.attributes["visible"])
            XCTAssertNil(node.attributes["nativeAttributes"].flatMap { ($0 as? [String: Any])?["2025"] })
            XCTAssertNil(node.enabled)
        }
        XCTAssertTrue(lines.contains { $0.contains("Connectivity Assist") && $0.contains("ax_value=\"0\"") })
        XCTAssertFalse(lines.contains { $0.contains("enabled=unknown") })
    }

    func testJoinNetworkSnapshotNeverBringsUnderlyingWLANRowsIntoModal() throws {
        let source = try capture("join-network")
        let projection = PresentedAX.project(source)
        let lines = CompactAX.render(source.nodes, including: projection.indices)
        XCTAssertTrue(source.nodes.contains { $0.label == "More Info" })
        XCTAssertEqual(projection.unqueriedChildControls, 0)
        XCTAssertEqual(lines.count, 17)
        XCTAssertFalse(lines.contains { $0.contains("More Info") || $0.contains("Other…") })
        for label in ["Cancel", "Done", "Name", "Password", "Security, WPA2/WPA3", "next"] {
            XCTAssertTrue(lines.contains { $0.contains(label) }, label)
        }
        XCTAssertEqual(projection.omittedKeyboardCharacters, 27)
    }

    func testChildHintsCannotPromoteHiddenUnknownForeignOrIncompleteNodes() throws {
        let original = try capture("wlan")
        let target = try XCTUnwrap(original.nodes.first { $0.label == "More Info" && $0.parent == 51 })
        for mutation in 0..<10 {
            var nodes = original.nodes
            var fields = target.attributes
            var parentFields = nodes[51].attributes
            mutate(mutation, fields: &fields, parent: &parentFields)
            nodes[target.index] = AXNode(index: target.index, parent: target.parent,
                                         role: target.role, attributes: fields)
            nodes[51] = AXNode(index: 51, parent: nodes[51].parent, role: nodes[51].role, attributes: parentFields)
            let changed = CapturedObservation(
                nodes: nodes, metadata: original.metadata, screenshot: original.screenshot)
            XCTAssertFalse(PresentedAX.project(changed).indices.contains(target.index), "mutation \(mutation)")
        }
    }

    private func mutate(_ mutation: Int, fields: inout [String: Any], parent: inout [String: Any]) {
        switch mutation {
        case 0: fields["visible"] = false
        case 1: parent.removeValue(forKey: "visible")
        case 2: parent["visible"] = false
        case 3: fields["nativeElement"] = parent["nativeElement"]
        case 4: fields["externalProcessReference"] = true
        case 5: fields["reportedChildCount"] = 1
        case 6: fields["frame"] = ["x": 330, "y": 800, "width": 25, "height": 25]
        case 7: fields["frame"] = NSNull()
        case 8: fields["nativeAttributes"] = ["2004": 0]
        default: fields["label"] = ""; fields["identifier"] = ""
        }
    }

    func testChildHintsLeaveCachedFactsAndStandardActionSemanticsUnchanged() throws {
        let source = try capture("wlan")
        let original = try jsonData(["nodes": source.nodes.map(\.attributes)])
        let directory = URL(fileURLWithPath: "/private/tmp/as-child-controls-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try SessionPaths.secureDirectory(directory)
        let cache = ObservationCache(directory: directory)
        let output = try cache.store(source)
        let text = try XCTUnwrap(output["text"] as? String)
        XCTAssertTrue(text.contains("independent_child_controls=9 with unknown visibility"))
        XCTAssertEqual(try jsonData(["nodes": cache.entries[0].capture.nodes.map(\.attributes)]), original)
        let reference = try ObservationReference("o1:e57")
        let detail = try cache.inspect(reference, offset: 0)
        XCTAssertTrue((detail["text"] as? String)?.contains("More Info") == true)
        XCTAssertNil(try cache.resolveCurrent(reference).attributes["visible"])
        let action = try DeviceAction(operation: "tap", request: ["reference": "o1:e57"])
        XCTAssertThrowsError(try cache.resolveTarget(for: action)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_action_unsupported")
        }
        cache.invalidate("superseded")
        XCTAssertEqual(try cache.inspect(reference, offset: 0)["refs"] as? String, "superseded")
        XCTAssertThrowsError(try cache.resolveCurrent(reference))
    }
}
