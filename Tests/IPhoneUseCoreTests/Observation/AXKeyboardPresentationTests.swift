import XCTest
@testable import IPhoneUseCore

final class AXKeyboardPresentationTests: XCTestCase {
    private func node(_ index: Int, parent: Int?, type: String, label: String, identifier: String = "") -> AXNode {
        AXNode(index: index, parent: parent, role: "key", attributes: [
            "label": label, "identifier": identifier, "nativeAttributes": ["5003": type], "visible": true
        ])
    }

    func testOnlyKnownLeafCharactersInsideKeyboardAreFiltered() {
        let nodes = [
            node(0, parent: nil, type: "UIApplication", label: ""),
            node(1, parent: 0, type: "UIKeyboardLayoutStar", label: "Keyboard"),
            node(2, parent: 1, type: "UIAccessibilityElementKBKey", label: "q"),
            node(3, parent: 1, type: "UIAccessibilityElementKBKey", label: "space", identifier: "space"),
            node(4, parent: 1, type: "UIAccessibilityElementKBKey", label: "next"),
            node(5, parent: 1, type: "UIAccessibilityElementKBKey", label: "中"),
            node(6, parent: 0, type: "UIAccessibilityElementKBKey", label: "q"),
            node(7, parent: 1, type: "UIButton", label: "q"),
            node(8, parent: 1, type: "UIAccessibilityElementKBKey", label: "a"),
            node(9, parent: 8, type: "UIView", label: "child"),
            node(10, parent: 1, type: "UIAccessibilityElementKBKey", label: "delete"),
            node(11, parent: 1, type: "UIAccessibilityElementKBKey", label: "space"),
            node(12, parent: 1, type: "UIAccessibilityElementKBKey", label: "7"),
            node(13, parent: 1, type: "UIAccessibilityElementKBKey", label: "!")
        ]
        XCTAssertEqual(AXKeyboardPresentation.ordinaryCharacterIndices(nodes), [2, 3, 12, 13])
        let capture = CapturedObservation(nodes: nodes, metadata: [:], screenshot: Data())
        let shown = PresentedAX.project(capture)
        XCTAssertEqual(shown.indices, Set(nodes.indices).subtracting([2, 3, 12, 13]))
        XCTAssertEqual(nodes[2].attributes["visible"] as? Bool, true)
    }

    func testRunnerKeysWithoutNativeKeyboardEvidenceRemainUnchanged() {
        let nodes = [AXNode(index: 0, parent: nil, role: "keyboard", attributes: [:]),
                     AXNode(index: 1, parent: 0, role: "key", attributes: ["label": "q"])]
        XCTAssertTrue(AXKeyboardPresentation.ordinaryCharacterIndices(nodes).isEmpty)
        let capture = CapturedObservation(nodes: nodes, metadata: [:], screenshot: Data())
        XCTAssertEqual(PresentedAX.project(capture).indices, [0, 1])
    }

    func testCandidateProjectionKeepsUnknownKeyboardContextWithoutCallingOtherStructureHidden() {
        let nodes = [
            AXNode(index: 0, parent: nil, role: "application", attributes: [:]),
            AXNode(index: 1, parent: 0, role: "group", attributes: ["label": "Unqueried background"]),
            AXNode(index: 2, parent: 0, role: "keyboard",
                   attributes: ["nativeAttributes": ["5003": "UIKeyboardLayoutStar"]]),
            node(3, parent: 2, type: "UIAccessibilityElementKBKey", label: "next")
        ]
        let capture = CapturedObservation(nodes: nodes, metadata: ["axCollection": [
            "strategy": "full_tree_candidate_visibility_keyboard_batch_v1"
        ]], screenshot: Data())
        let projection = PresentedAX.project(capture)
        XCTAssertEqual(projection.indices, [2, 3])
        XCTAssertTrue(projection.semanticCandidatesOnly)
        XCTAssertNil(capture.nodes[1].attributes["visible"])
        XCTAssertEqual(capture.nodes.count, 4)
    }

}
