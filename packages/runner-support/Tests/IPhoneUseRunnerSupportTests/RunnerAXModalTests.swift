import XCTest
@testable import IPhoneUseRunnerSupport

// Model the hierarchy returned by the system, not Apple's filtering algorithm.
// Exercise the same flatten/reference/resolve primitives used by the Runner.
final class RunnerAXModalTests: XCTestCase {
    private final class Element {
        let identity = NSUUID()
        let role: String
        let label: String
        var children: [Element] = []
        var value = ""
        var focused: Bool?
        let frame = CGRect(x: 10, y: 20, width: 100, height: 40)

        init(_ role: String, _ label: String) { self.role = role; self.label = label }
    }

    private struct Snapshot {
        let element: Element
        let children: [Snapshot]
        let label: String
        let value: String
        let focused: Bool?
        let frame: CGRect

        init(_ element: Element) {
            self.element = element
            children = element.children.map(Self.init)
            label = element.label; value = element.value
            focused = element.focused; frame = element.frame
        }
    }

    private struct Capture {
        let entries: [(node: Snapshot, parent: Int?)]
        let tokens: [String]
        let references: RunnerAXReferences<NSObject>

        init(_ root: Element) {
            entries = RunnerAXTree.flatten(Snapshot(root), children: { $0.children })
            var references = RunnerAXReferences<NSObject>()
            tokens = entries.map { references.register($0.node.element.identity) }
            self.references = references
        }

        func path(to element: Element) throws -> [[String: Any]] {
            var index: Int? = try XCTUnwrap(entries.firstIndex { $0.node.element === element })
            var path: [[String: Any]] = []
            while let current = index {
                let entry = entries[current]
                let childIndex = entry.parent.flatMap { parent in
                    entries[parent].node.children.firstIndex { $0.element === entry.node.element }
                } ?? 0
                path.append(["identityToken": tokens[current], "childIndex": childIndex,
                             "type": entry.node.element.role])
                index = entry.parent
            }
            return path.reversed()
        }
    }

    private final class Page {
        let root = Element("application", "Fixture")
        let background = Element("group", "Background")
        let modal = Element("group", "Dialog")
        let backgroundButton = Element("button", "Continue")
        let modalButton = Element("button", "Continue")
        let backgroundField = Element("text_field", "Name")
        let modalField = Element("text_field", "Name")
        let secondModalField = Element("text_field", "Name")
        var bindingOverride: Element?
        var afterBind: () -> Void = {}
        var bound: [Element] = []

        init() {
            background.children = [backgroundButton, backgroundField]
            modal.children = [modalButton, modalField, secondModalField]
            backgroundField.value = "background"; backgroundField.focused = true
            modalField.value = "dialog"; modalField.focused = true
            secondModalField.value = "neighbor"; secondModalField.focused = false
            present(false)
        }

        func present(_ modalVisible: Bool) { root.children = modalVisible ? [modal] : [background] }

        func resolve(_ capture: Capture, _ target: Element) throws -> Element {
            func identityMatches(_ snapshot: Snapshot, _ step: [String: Any]) throws -> Bool {
                try capture.references.identity(for: step["identityToken"] as? String)
                    .isEqual(snapshot.element.identity)
            }
            // Deliberately retain background and reverse same-name modal query candidates.
            let candidates = [backgroundField, backgroundButton, secondModalField, modalField, modalButton]
            return try RunnerAXTree.resolve(
                root: root, path: capture.path(to: target),
                access: .init(snapshot: Snapshot.init, children: { $0.children }, bind: { _, selected in
                    let result = try XCTUnwrap(self.bindingOverride ?? candidates.first {
                        $0.identity.isEqual(selected.element.identity)
                    })
                    self.bound.append(result)
                    self.afterBind()
                    return result
                }), sameIdentity: { $0.element.identity.isEqual($1.element.identity) },
                matches: { snapshot, step in
                    try identityMatches(snapshot, step) && snapshot.element.role == step["type"] as? String
                }, identityMatches: identityMatches).0
        }
    }

    func testModalCaptureKeepsHierarchyDuplicateControlsAndInputContent() throws {
        let page = Page()
        page.present(true)
        let capture = Capture(page.root)
        XCTAssertEqual(capture.entries.map { $0.node.label }, ["Fixture", "Dialog", "Continue", "Name", "Name"])
        XCTAssertEqual(capture.entries.map(\.parent), [nil, 0, 1, 1, 1])
        XCTAssertEqual(Set(capture.tokens).count, 5)
        XCTAssertEqual(capture.entries[3].node.value, "dialog")
        XCTAssertEqual(capture.entries[3].node.focused, true)
        XCTAssertEqual(capture.entries[4].node.value, "neighbor")
        XCTAssertEqual(capture.entries[4].node.focused, false)
        XCTAssertEqual(capture.entries[3].node.frame, page.modalField.frame)
        for target in [page.modalButton, page.modalField, page.secondModalField] {
            XCTAssertTrue(try page.resolve(capture, target) === target)
        }
        XCTAssertFalse(page.bound.contains { $0 === page.backgroundField || $0 === page.backgroundButton })
        page.modalField.focused = nil
        XCTAssertNil(Capture(page.root).entries[3].node.focused)
    }

    func testOpeningAndClosingModalRejectOldReferencesBeforeBinding() throws {
        for opening in [true, false] {
            let page = Page()
            page.present(!opening)
            let capture = Capture(page.root)
            let oldTargets = opening ? [page.backgroundButton, page.backgroundField] :
                [page.modalButton, page.modalField]
            page.present(opening)
            for target in oldTargets {
                XCTAssertThrowsError(try page.resolve(capture, target)) {
                    XCTAssertEqual($0 as? RunnerAXTree.Failure, .targetChanged)
                }
            }
            XCTAssertTrue(page.bound.isEmpty)
            let fresh = Capture(page.root)
            let current = opening ? page.modalField : page.backgroundField
            XCTAssertTrue(try page.resolve(fresh, current) === current)
        }
    }

    func testModalTransitionDuringBindingRejectsStillReadableOldLeaf() throws {
        for opening in [true, false] {
            let page = Page()
            page.present(!opening)
            let capture = Capture(page.root)
            let target = opening ? page.backgroundField : page.modalField
            page.afterBind = { page.present(opening) }
            defer { page.afterBind = {} }
            XCTAssertThrowsError(try page.resolve(capture, target)) {
                XCTAssertEqual($0 as? RunnerAXTree.Failure, .targetChanged)
            }
            XCTAssertEqual(page.bound.count, 1)
            XCTAssertTrue(page.bound.first === target)
        }
    }

    func testWrongSameNameBindingCannotSelectBackgroundOrNeighbor() {
        let page = Page()
        page.present(true)
        let capture = Capture(page.root)
        for wrong in [page.backgroundField, page.secondModalField] {
            page.bindingOverride = wrong
            XCTAssertEqual(wrong.label, page.modalField.label)
            XCTAssertThrowsError(try page.resolve(capture, page.modalField)) {
                XCTAssertEqual($0 as? RunnerAXTree.Failure, .targetChanged)
            }
        }
    }

    func testReorderedModalControlsKeepIdentityButReplacedSameNameFieldRejects() throws {
        let page = Page()
        page.present(true)
        let capture = Capture(page.root)
        page.modal.children.swapAt(0, 1)
        XCTAssertTrue(try page.resolve(capture, page.modalField) === page.modalField)
        let replacement = Element("text_field", "Name")
        page.modal.children = [replacement, page.modalButton]
        let bindings = page.bound.count
        XCTAssertThrowsError(try page.resolve(capture, page.modalField)) {
            XCTAssertEqual($0 as? RunnerAXTree.Failure, .targetChanged)
        }
        XCTAssertEqual(page.bound.count, bindings)
    }
}
