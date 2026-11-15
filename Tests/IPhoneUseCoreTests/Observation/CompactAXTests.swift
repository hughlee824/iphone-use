import XCTest
@testable import IPhoneUseCore

final class CompactAXTests: XCTestCase {
    private let frame: [String: Any] = ["x": 0, "y": 0, "width": 100, "height": 40]

    private func wrapper(_ index: Int = 1, parent: Int? = 0, extra: [String: Any] = [:]) -> AXNode {
        var attributes: [String: Any] = [
            "frame": frame, "nativeAttributes": ["5003": "UITransitionView", "2004": 0],
            "enabled": NSNull(), "keyboardFocus": NSNull(), "reportedChildCount": 1
        ]
        attributes.merge(extra) { _, new in new }
        return AXNode(index: index, parent: parent, role: "unknown", attributes: attributes)
    }

    private func child(_ index: Int = 2, parent: Int? = 1) -> AXNode {
        AXNode(index: index, parent: parent, role: "button", attributes: ["label": "Continue", "frame": frame])
    }

    func testUnknownStatesAreOmittedAndKnownTrueFalseStatesRemainDistinct() {
        for state: Any in [NSNull(), true, false] {
            let node = AXNode(index: 0, parent: nil, role: "text_field", attributes: [
                "label": "Name", "value": "", "enabled": state, "keyboardFocus": state
            ])
            let text = CompactAX.render([node])[0]
            XCTAssertTrue(text.contains("ax_value=\"\""))
            if let known = state as? Bool {
                XCTAssertTrue(text.contains(known ? "enabled=true" : "disabled"))
                XCTAssertTrue(text.contains("keyboard_focus=\(known)"))
            } else {
                XCTAssertFalse(text.contains("enabled="))
                XCTAssertFalse(text.contains("disabled"))
                XCTAssertFalse(text.contains("keyboard_focus="))
            }
        }
        let missing = AXNode(index: 0, parent: nil, role: "text_field", attributes: ["label": "Name"])
        XCTAssertEqual(CompactAX.render([missing]), ["[e1] text_field \"Name\""])
    }

    func testWrapperFoldsWithoutRenumberingOrLosingNamedGroup() {
        let group = AXNode(index: 0, parent: nil, role: "group", attributes: ["label": "Account"])
        let nodes = [group, wrapper(), child()]
        XCTAssertEqual(CompactAX.render(nodes), ["[e1] group \"Account\"", "  [e3] button \"Continue\""])
        XCTAssertEqual(nodes[2].parent, 1)
        XCTAssertEqual(nodes[1].attributes["reportedChildCount"] as? Int, 1)
    }

    func testUnknownLeafCustomControlAndBranchingWrappersRemain() {
        XCTAssertEqual(CompactAX.render([wrapper(0, parent: nil)]).count, 1)
        let custom = wrapper(0, parent: nil, extra: ["nativeAttributes": ["5003": "CustomControl", "2004": 0]])
        XCTAssertEqual(CompactAX.render([custom, child(1, parent: 0)]).count, 2)
        let branch = [wrapper(0, parent: nil), child(1, parent: 0), child(2, parent: 0)]
        XCTAssertEqual(CompactAX.render(branch).count, 3)
        XCTAssertTrue(CompactAX.render(branch)[2].hasPrefix("  [e3]"))
    }

    func testSemanticEvidenceAndIncompleteGeometryPreventFolding() {
        let variants: [[String: Any]] = [
            ["label": "Section"], ["identifier": "section"], ["value": "0"], ["hint": "Double tap"],
            ["enabled": false], ["enabled": true], ["keyboardFocus": true], ["keyboardFocus": false],
            ["selected": true], ["externalProcessReference": true], ["reportedChildCount": 2],
            ["frame": NSNull()], ["frame": ["x": 0, "y": 0, "width": 99, "height": 40]],
            ["nativeAttributes": ["5003": "UITransitionView", "2004": 1]],
            ["nativeAttributes": ["5003": "UITransitionView", "2004": 0, "newProperty": true]]
        ]
        for extra in variants {
            let nodes = [wrapper(0, parent: nil, extra: extra), child(1, parent: 0)]
            XCTAssertEqual(CompactAX.render(nodes).count, 2, String(describing: extra))
        }
    }

    func testSameNamedControlsAndStateBearingTextAreNotMerged() {
        let nodes = [
            AXNode(index: 0, parent: nil, role: "button", attributes: ["label": "Continue", "identifier": "one"]),
            AXNode(index: 1, parent: 0, role: "text", attributes: ["label": "Continue", "keyboardFocus": true]),
            AXNode(index: 2, parent: nil, role: "button", attributes: ["label": "Continue", "identifier": "two"])
        ]
        let lines = CompactAX.render(nodes)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("id=\"one\""))
        XCTAssertTrue(lines[1].contains("keyboard_focus=true"))
        XCTAssertTrue(lines[2].contains("id=\"two\""))
    }
}

extension ObservationTests {
    func testFoldedWrapperRemainsInspectableWithOriginalHierarchyAndStates() throws {
        let frame = ["x": 0, "y": 0, "width": 100, "height": 40]
        let nodes = [
            AXNode(index: 0, parent: nil, role: "unknown", attributes: [
                "index": 0, "parent": NSNull(), "frame": frame, "enabled": NSNull(),
                "nativeAttributes": ["5003": "UITransitionView", "2004": 0]
            ]),
            AXNode(index: 1, parent: 0, role: "button", attributes: [
                "index": 1, "parent": 0, "frame": frame, "label": "Continue", "enabled": false
            ])
        ]
        let (cache, _) = try cache()
        let stored = try cache.store(CapturedObservation(nodes: nodes, metadata: [:], screenshot: try screenPNG()))
        let text = try XCTUnwrap(stored["text"] as? String)
        XCTAssertFalse(text.contains("[e1]"))
        XCTAssertTrue(text.contains("[e2] button \"Continue\" disabled"))
        let inspected = try queryNodes(cache.inspect(ObservationReference("o1:e1"), offset: 0))
        XCTAssertEqual(inspected.count, 2)
        XCTAssertTrue(inspected[0]["enabled"] is NSNull)
        XCTAssertEqual(inspected[1]["parent"] as? Int, 0)
        XCTAssertEqual(inspected[1]["enabled"] as? Bool, false)
        let saved = try jsonObject(Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(stored["snapshot"] as? String))))
        XCTAssertEqual((saved["nodes"] as? [[String: Any]])?.count, 2)
    }
}
