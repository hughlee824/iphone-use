import XCTest
@testable import IPhoneUseRunnerSupport

final class RunnerInputActionTests: XCTestCase {
    private enum Fault: Error { case transport, snapshot }

    func testUnfocusedTypeNeverTapsOrSends() {
        let action = RunnerInputAction()
        var sends = 0
        XCTAssertThrowsError(try action.send(focused: false) { sends += 1 })
        XCTAssertEqual(sends, 0)
        XCTAssertFalse(action.attempted)
    }

    func testTypeAcknowledgesOnceWithoutPostInputLayoutValidation() throws {
        let action = RunnerInputAction()
        var text = ""
        try action.send(focused: true) { text += "ASCII-BEGIN|abcdefghijklmnopqrstuvwxyz|ASCII-END" }
        XCTAssertEqual(text, "ASCII-BEGIN|abcdefghijklmnopqrstuvwxyz|ASCII-END")
        XCTAssertTrue(action.acknowledged)
        XCTAssertEqual(action.verification, "not_requested")
    }

    func testUncertainSendIsNeverReplayed() {
        let action = RunnerInputAction()
        var sends = 0
        XCTAssertThrowsError(try action.send(focused: true) { sends += 1; throw Fault.transport })
        XCTAssertThrowsError(try action.send(focused: true) { sends += 1 })
        XCTAssertEqual(sends, 1)
        XCTAssertTrue(action.attempted)
        XCTAssertFalse(action.acknowledged)
    }

    func testFocusNoOpAndChangedPageAfterTap() throws {
        var taps = 0
        let noOp = RunnerInputAction()
        try noOp.focus(isFocused: true, event: { taps += 1 }, verify: { XCTFail("Unexpected callback"); return false })
        XCTAssertEqual(noOp.verification, "confirmed")
        XCTAssertEqual(taps, 0)
        let navigated = RunnerInputAction()
        try navigated.focus(isFocused: false, event: { taps += 1 }, verify: { throw Fault.snapshot })
        XCTAssertEqual(taps, 1)
        XCTAssertTrue(navigated.acknowledged)
        XCTAssertEqual(navigated.verification, "unavailable")
    }

    func testFocusFalseVerificationNeverRetaps() throws {
        let action = RunnerInputAction()
        var taps = 0
        try action.focus(isFocused: false, event: { taps += 1 }, verify: { false })
        XCTAssertEqual(taps, 1)
        XCTAssertEqual(action.verification, "unconfirmed")
    }

    func testClearSelectionDeletesOnceAndDoesNotRepairIncompleteSelection() throws {
        let action = RunnerInputAction()
        var deletes = 0
        try action.clear(state: .init(value: "头🙂尾", secure: false, focused: true), expected: "头🙂尾",
                         event: { deletes += 1 }, verify: { false })
        XCTAssertEqual(deletes, 1)
        XCTAssertTrue(action.acknowledged)
        XCTAssertEqual(action.verification, "unconfirmed")
    }

    func testClearRejectsChangedValueSecureAndLostFocusBeforeDeleting() {
        for (value, secure, focused) in [("changed", false, true), ("old", true, true), ("old", false, false)] {
            let action = RunnerInputAction()
            XCTAssertThrowsError(try action.clear(state: .init(value: value, secure: secure, focused: focused),
                                                 expected: "old",
                                                 event: { XCTFail("Unexpected callback") },
                                                 verify: { XCTFail("Unexpected callback"); return true }))
            XCTAssertFalse(action.attempted)
        }
    }

    func testEmptyClearIsVerifiedNoOpAndPostDeleteReadFailureKeepsAcknowledgement() throws {
        let empty = RunnerInputAction()
        try empty.clear(state: .init(value: nil, secure: false, focused: true), expected: nil,
                        event: { XCTFail("Unexpected callback") },
                                                 verify: { XCTFail("Unexpected callback"); return false })
        XCTAssertEqual(empty.verification, "confirmed")
        XCTAssertFalse(empty.attempted)
        let changed = RunnerInputAction()
        var deletes = 0
        try changed.clear(state: .init(value: "old", secure: false, focused: true), expected: "old",
                          event: { deletes += 1 }, verify: { throw Fault.snapshot })
        XCTAssertEqual(deletes, 1)
        XCTAssertTrue(changed.acknowledged)
        XCTAssertEqual(changed.verification, "unavailable")
    }
}
