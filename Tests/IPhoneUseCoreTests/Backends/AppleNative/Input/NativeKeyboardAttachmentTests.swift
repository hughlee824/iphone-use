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
