import XCTest
@testable import IPhoneUseRunnerSupport

final class RunnerAXAncestorTests: XCTestCase {
    private final class Node {
        let identity: String
        var children: [Node]
        var value = "same label"
        init(_ identity: String, _ children: [Node] = []) {
            self.identity = identity; self.children = children
        }
    }
    private struct Snapshot {
        let identity: String
        let children: [Snapshot]
        let value: String
        let node: Node
        init(_ node: Node) {
            identity = node.identity; children = node.children.map(Self.init)
            value = node.value; self.node = node
        }
    }
    private let path: [[String: Any]] = ["app", "window", "container", "field"].map {
        ["identityToken": $0, "childIndex": 0]
    }

    private func fixture() -> (Node, [Node]) {
        let field = Node("field")
        let container = Node("container", [field])
        let window = Node("window", [container])
        return (Node("app", [window]), [window, container, field])
    }

    private func resolve(_ root: Node, onBind: @escaping (Node) -> Node = { $0 }) throws -> (Node, Snapshot) {
        var reads = 0
        let result = try RunnerAXTree.resolve(
            root: root, path: path,
            access: .init(snapshot: { node in reads += 1; return Snapshot(node) }, children: { $0.children },
                          bind: { _, selected in onBind(selected.node) }),
            sameIdentity: { $0.identity == $1.identity },
            matches: { $0.identity == $1["identityToken"] as? String },
            identityMatches: { $0.identity == $1["identityToken"] as? String })
        XCTAssertEqual(reads, 3, "Initial root, bound element and fresh root must all be read")
        return result
    }

    func testSiblingChangesAtEveryLevelPreserveTheWholeIdentityChain() throws {
        let (root, nodes) = fixture()
        let window = nodes[0], container = nodes[1], field = nodes[2]
        root.children.insert(Node("other-window", [Node("lookalike")]), at: 0)
        window.children.insert(Node("other-container"), at: 0)
        container.children.insert(Node("other-field"), at: 0)
        let result = try resolve(root) { selected in
            // A second immutable tree must be collected after binding; every index changes again.
            root.children.reverse(); window.children.reverse(); container.children.reverse()
            container.value = "expanded parent"
            field.value = "latest value"
            return selected
        }
        XCTAssertTrue(result.0 === field)
        XCTAssertEqual(result.1.value, "latest value")
    }

    func testReplacedAncestorCannotBeBypassedEvenIfLeafIdentitySurvives() {
        for afterBinding in [false, true] {
            let (root, nodes) = fixture()
            let window = nodes[0], container = nodes[1], field = nodes[2]
            let replace = { window.children = [Node("replacement", [field])]; container.children = [] }
            if !afterBinding { replace() }
            XCTAssertThrowsError(try resolve(root) { selected in
                if afterBinding { replace() }
                return selected
            }) { XCTAssertEqual($0 as? RunnerAXTree.Failure, .targetChanged) }
        }
    }

    func testReparentedLeafCannotBeFoundThroughAnotherBranch() {
        let (root, nodes) = fixture()
        let window = nodes[0], container = nodes[1], field = nodes[2]
        XCTAssertThrowsError(try resolve(root) { selected in
            container.children = []
            window.children.append(Node("other-container", [field]))
            return selected
        }) { XCTAssertEqual($0 as? RunnerAXTree.Failure, .targetChanged) }
    }

    func testDuplicateAncestorIdentityRejectsBeforeAndAfterBinding() {
        for afterBinding in [false, true] {
            let (root, nodes) = fixture()
            let window = nodes[0], field = nodes[2]
            let duplicate = { window.children.append(Node("container", [field])) }
            if !afterBinding { duplicate() }
            XCTAssertThrowsError(try resolve(root) { selected in
                if afterBinding { duplicate() }
                return selected
            }) { XCTAssertEqual($0 as? RunnerAXTree.Failure, .ambiguousIdentity) }
        }
    }

    func testChangedRootIdentityRejectsEvenWithIdenticalDescendants() {
        let (_, nodes) = fixture()
        let window = nodes[0]
        XCTAssertThrowsError(try resolve(Node("another-app", [window]))) {
            XCTAssertEqual($0 as? RunnerAXTree.Failure, .targetChanged)
        }
    }
}
