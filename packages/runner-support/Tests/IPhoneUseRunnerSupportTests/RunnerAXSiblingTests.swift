import XCTest
@testable import IPhoneUseRunnerSupport

final class RunnerAXSiblingTests: XCTestCase {
    private final class Node {
        var children: [Node] = []
        var height = 160
        var value = ""
    }

    func testSiblingInsertionRemovalAndReorderingKeepExactIdentity() throws {
        let root = Node(), field = Node(), other = Node(), decoration = Node()
        let path: [[String: Any]] = [["childIndex": 0], ["childIndex": 1]]
        for siblings in [[other, field], [decoration, other, field], [field], [field, other]] {
            root.children = siblings
            root.height += 50 // Probe's received-text label expands its parent.
            field.value += "a"
            let result = try resolve(root, field: field, path: path)
            XCTAssertTrue(result === field)
        }
    }

    func testReplacementReparentingAndDuplicateIdentityFailClosed() {
        let root = Node(), field = Node(), replacement = Node(), otherParent = Node()
        let path: [[String: Any]] = [["childIndex": 0], ["childIndex": 0]]
        otherParent.children = [field]
        for siblings in [[replacement], [otherParent], [], [field, field]] {
            root.children = siblings
            XCTAssertThrowsError(try resolve(root, field: field, path: path))
        }
    }

    func testBindingAndSecondFreshTreeCannotSubstituteTarget() {
        let root = Node(), field = Node(), other = Node()
        let path: [[String: Any]] = [["childIndex": 0], ["childIndex": 0]]
        for wrongBinding in [true, false] {
            root.children = [field]
            XCTAssertThrowsError(try resolve(root, field: field, path: path, bind: { selected in
                if wrongBinding { return other }
                root.children = [other]
                return selected
            }))
        }
    }

    private func resolve(
        _ root: Node, field: Node, path: [[String: Any]], bind: ((Node) -> Node)? = nil
    ) throws -> Node {
        try RunnerAXTree.resolve(
            root: root, path: path,
            access: .init(snapshot: { $0 }, children: { $0.children }, bind: { _, selected in
                bind?(selected) ?? selected
            }), sameIdentity: { $0 === $1 },
            matches: { node, _ in node === root || node === field },
            identityMatches: { node, _ in node === field }).0
    }
}
