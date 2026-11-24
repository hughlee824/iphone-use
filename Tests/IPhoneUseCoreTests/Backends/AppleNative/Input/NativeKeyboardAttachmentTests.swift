import XCTest
import IPhoneUseRunnerSupport
@testable import IPhoneUseCore

final class NativeKeyboardAttachmentTests: XCTestCase {
    private let context = screenTestContext()
    private let lease = UUID().uuidString
    private let field = ScreenRect(CGRect(x: 20, y: 100, width: 350, height: 44))
    private let dock = CGRect(x: 0, y: 544, width: 390, height: 300)

    private func editor(id: String = "17", top: Double = 100) -> AXNode {
        AXNode(index: 0, parent: nil, role: "text_field", attributes: [
            "frame": ["x": 20, "y": top, "width": 350, "height": 44], "keyboardFocus": true,
            "nativeElement": ["pid": 4, "objectID": id]
        ])
    }

    private func frame(_ png: Data, _ nodes: [AXNode], generation: String? = nil) throws -> CapturedObservation {
        CapturedObservation(nodes: nodes, metadata: [
            "axStatus": "available", "axApplicationBundleId": "test.app",
            "screenContext": try jsonObject(JSONEncoder().encode(context)),
            "axCleanup": ["connectionLease": ["generation": generation ?? lease]]
        ], screenshot: png)
    }

    private struct Fixture {
        let binding: NativeKeyboardAttachment
        let baseline: ScreenGuard
        let source: CapturedObservation
    }

    private func original() throws -> Fixture {
        let bounds = ["x": 0, "y": 544, "width": 390, "height": 300]
        let host = AXNode(index: 1, parent: nil, role: "unknown", attributes: [
            "nativeAttributes": ["5003": "UIInputSetHostView"], "frame": bounds
        ])
        let keys = AXNode(index: 2, parent: 1, role: "keyboard", attributes: ["frame": bounds])
        let source = try frame(screenPNG(patches: [(dock, [0, 0, 0])]), [editor(), host, keys])
        let baseline = try ScreenGuard(png: source.screenshot, context: context, rects: [field], policy: .init())
        let binding = try XCTUnwrap(NativeKeyboardAttachment(source: source, field: field,
                                                             guard: baseline, fieldGuard: nil))
        return Fixture(binding: binding, baseline: baseline, source: source)
    }

    func testOnlySameUniqueResponderInSameLeaseAndFieldCanContinue() throws {
        let fixture = try original()
        let binding = fixture.binding, baseline = fixture.baseline, source = fixture.source
        XCTAssertNoThrow(try binding.confirm(source))
        for nodes in [[], [editor(id: "18")], [editor(top: 101)], [editor(), editor()], [editor(id: "0")]] {
            let changed = try frame(source.screenshot, nodes)
            XCTAssertThrowsError(try binding.confirm(changed)) { error in
                XCTAssertEqual((error as? ActionFailure)?.code, "native_keyboard_focus_unverified")
                XCTAssertEqual((error as? ActionFailure)?.possiblyExecuted, false)
            }
        }
        try XCTAssertThrowsError(binding.confirm(frame(source.screenshot, [editor()], generation: UUID().uuidString)))
        let wrongField = ScreenRect(CGRect(x: 20, y: 105, width: 350, height: 44))
        XCTAssertNil(try NativeKeyboardAttachment(source: source, field: wrongField, guard: baseline, fieldGuard: nil))
    }

    func testSemanticFocusSurvivesLayoutChangeAndRequiresOriginalEditorAndLease() throws {
        let png = try screenPNG()
        let source = try frame(png, [editor()])
        let original = try XCTUnwrap(NativeTextResponder(source))
        XCTAssertTrue(try original.sameEditor(as: NativeTextResponder(frame(png, [editor(top: 250)]))))
        XCTAssertFalse(try original.sameEditor(as: NativeTextResponder(frame(png, [editor(id: "18")]))))
        XCTAssertFalse(try original.sameEditor(as: NativeTextResponder(frame(png, [editor()], generation: "retired"))))
        XCTAssertFalse(try original.sameEditor(as: NativeTextResponder(frame(png, [editor(), editor()]))))
        XCTAssertFalse(try original.sameEditor(as: NativeTextResponder(frame(png, []))))
    }

    func testTargetedTypeResolvesOnlyUniqueStructuralEditors() throws {
        let png = try screenPNG()
        var attrs = editor().attributes
        attrs["attributeSource"] = "axp-native-snapshot"
        attrs["keyboardFocus"] = NSNull()
        let selected = AXNode(index: 0, parent: nil, role: "text_field", attributes: attrs)
        let capture = try frame(png, [selected])
        XCTAssertNil(NativeTextResponder(capture))
        XCTAssertNotNil(NativeTextResponder(capture, selecting: selected))
        XCTAssertNil(try NativeTextResponder(frame(png, [selected, selected]), selecting: selected))
        XCTAssertNil(NativeTextResponder(capture, selecting: editor()))
    }

    func testOnlyAlreadyFocusedSemanticTargetsCanSkipThePixelBaseline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        func node(_ index: Int, focused: Bool) -> AXNode {
            var attrs = editor(id: String(index + 1), top: Double(100 + 60 * index)).attributes
            attrs["attributeSource"] = "axp-native-snapshot"
            attrs["keyboardFocus"] = focused
            return AXNode(index: index, parent: nil, role: "text_field", attributes: attrs)
        }
        let source = try frame(screenPNG(), [node(0, focused: true), node(1, focused: false)])
        var metadata = source.metadata
        metadata["backend"] = "apple-native"; metadata["screenshotWidth"] = 390; metadata["screenshotHeight"] = 844
        func store() throws {
            let capture = CapturedObservation(nodes: source.nodes, metadata: metadata, screenshot: source.screenshot)
            _ = try cache.store(capture)
        }
        func resolve(_ ref: String, field: String? = nil) throws -> ObservedTarget {
            var fields: [String: Any] = ["reference": ref, "text": "abc", "mode": "insert"]
            fields["fieldRect"] = field
            return try cache.resolveTarget(for: DeviceAction(operation: "type", request: fields, allowScreenText: true))
        }
        try store()
        for ref in ["o1", "o1:e1"] {
            let target = try resolve(ref)
            XCTAssertNotNil(target.focusedTextContext)
            XCTAssertNil(target.textGuard)
        }
        XCTAssertNotNil(try resolve("o1:e2").textGuard)
        XCTAssertNotNil(try resolve("o1", field: "20,100,350,44").textFieldGuard)
        metadata["screenshotHeight"] = 500
        try store()
        XCTAssertThrowsError(try resolve("o2"))
        XCTAssertThrowsError(try resolve("o1:e1"))
    }

    func testBackspaceUsesOnlyTheOriginalFocusedEditorOrTheRequestedVisualGuard() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        let source = try frame(screenPNG(), [editor()])
        var metadata = source.metadata
        metadata["backend"] = "apple-native"; metadata["screenshotWidth"] = 390; metadata["screenshotHeight"] = 844
        func store(_ nodes: [AXNode]) throws {
            let capture = CapturedObservation(nodes: nodes, metadata: metadata, screenshot: source.screenshot)
            _ = try cache.store(capture)
        }
        func press(_ ref: String, _ key: String, field: String? = nil) throws -> ObservedTarget {
            var request: [String: Any] = ["reference": ref, "key": key]
            request["fieldRect"] = field
            let action = try DeviceAction(operation: "press", request: request, allowScreenText: true)
            return try cache.resolveTarget(for: action)
        }
        try store([editor()])
        let backspace = try press("o1", "backspace")
        XCTAssertEqual(backspace.textEditor, NativeTextResponder(source))
        XCTAssertNotNil(backspace.focusedTextContext)
        XCTAssertNil(backspace.textGuard)
        for target in [try press("o1", "return"), try press("o1", "backspace", field: "20,100,350,44")] {
            XCTAssertNil(target.textEditor)
            XCTAssertNotNil(target.textFieldGuard)
        }
        try store([editor(), editor(id: "18")])
        let ambiguous = try press("o2", "backspace")
        XCTAssertNil(ambiguous.textEditor)
        XCTAssertNotNil(ambiguous.textFieldGuard)
        XCTAssertThrowsError(try press("o1", "backspace"))
    }

    func testDefaultBackspaceAcceptsOnlyEditorsWithVisibleAreaOnScreen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        let png = try screenPNG()
        for hasDimensions in [true, false] {
            for top in [-10.0, 832, -44, -60, 844] {
                let source = try frame(png, [editor(top: top)])
                var metadata = source.metadata
                metadata["backend"] = "apple-native"
                if hasDimensions {
                    metadata["screenshotWidth"] = 390; metadata["screenshotHeight"] = 844
                }
                let capture = CapturedObservation(nodes: source.nodes, metadata: metadata, screenshot: png)
                let stored = try cache.store(capture)
                let ref = try XCTUnwrap(stored["observation"] as? String)
                let action = try DeviceAction(operation: "press",
                    request: ["reference": ref, "key": "backspace"], allowScreenText: true)
                if top == -10 || top == 832 {
                    let target = try cache.resolveTarget(for: action)
                    XCTAssertEqual(target.textEditor, try XCTUnwrap(NativeTextResponder(source)))
                } else {
                    XCTAssertThrowsError(try cache.resolveTarget(for: action)) {
                        XCTAssertEqual($0 as? ScreenGuard.Failure, .invalidGuard)
                    }
                }
            }
        }
    }

    func testDismissalMustSettleBeforeStagingAndOtherScreenChangesRemainGuarded() throws {
        let fixture = try original()
        let binding = fixture.binding, baseline = fixture.baseline, source = fixture.source
        let hidden = try frame(screenPNG(), [editor()])
        var samples = [source, hidden, hidden].makeIterator()
        let settled = try binding.settledFrame(original: baseline) { try XCTUnwrap(samples.next()) }
        XCTAssertNil(samples.next())
        XCTAssertFalse(try baseline.check(png: settled.screenshot, context: context).accepted)
        let updated = try binding.afterRegistration(settled, original: baseline)
        XCTAssertTrue(try updated.check(png: settled.screenshot, context: context).accepted)
        XCTAssertFalse(try updated.check(png: source.screenshot, context: context).accepted)
        let modal = try frame(screenPNG(patches: [(CGRect(x: 30, y: 220, width: 320, height: 150), [0, 0, 0])]),
                              [editor()])
        let guarded = try binding.afterRegistration(modal, original: baseline)
        XCTAssertFalse(try guarded.check(png: modal.screenshot, context: context).accepted)
        var moving = [source, hidden, source, hidden].makeIterator()
        XCTAssertThrowsError(try binding.settledFrame(original: baseline) { try XCTUnwrap(moving.next()) })
    }
}
