import XCTest
@testable import IPhoneUseCore

extension RunnerRecordingTests {
    func testLockClearsPreviewButKeepsURLAndResumesOnceAfterVerifiedUnlock() throws {
        let old = RunnerRecordingConnectionStub(), fresh = RunnerRecordingConnectionStub()
        var starts = 0
        let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation()) {
            starts += 1; return starts == 1 ? old : fresh
        }
        defer { _ = owner.close() }
        let before = try owner.startPreview(options: .init(port: 0))
        _ = try owner.start(duration: 30)
        old.pollError = IPhoneUseError("device_locked", "Locked")
        XCTAssertTrue(owner.previewTick())
        XCTAssertEqual(old.closed, 1)
        XCTAssertFalse(old.receiver.attached)
        XCTAssertEqual(owner.previewStatus["state"] as? String, "unavailable")
        XCTAssertEqual(owner.previewStatus["url"] as? String, before["url"] as? String)
        XCTAssertTrue(owner.previewStatus["frameAgeSeconds"] is NSNull)
        for _ in 0..<4 { XCTAssertFalse(owner.previewTick()) }
        XCTAssertEqual(starts, 1, "Only read readiness while locked, never start media")
        XCTAssertEqual(try owner.startPreview()["url"] as? String, before["url"] as? String)
        XCTAssertThrowsError(try owner.start(duration: 30)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "device_locked")
        }
        old.canResume = true
        XCTAssertTrue(owner.previewTick())
        XCTAssertEqual(starts, 2)
        XCTAssertTrue(owner.previewTick(), "Validate the fresh source before attaching it")
        XCTAssertEqual(fresh.previewRefreshes, 0)
        XCTAssertEqual(fresh.closed, 0)
        XCTAssertEqual(owner.previewStatus["url"] as? String, before["url"] as? String)
        XCTAssertNotEqual(owner.previewStatus["state"] as? String, "unavailable")
        XCTAssertNil(owner.status()["reconnectRequired"])
        XCTAssertEqual(owner.status()["stopReason"] as? String, "device_locked")
        XCTAssertEqual(starts, 2, "Finished recordings must not restart on unlock")
    }

    func testUnlockCannotResumeAfterUnconfirmedCleanupOrUncertainStart() throws {
        for cleanupConfirmed in [true, false] {
            let old = RunnerRecordingConnectionStub()
            old.acknowledged = cleanupConfirmed
            var starts = 0
            let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation()) {
                starts += 1
                if starts > 1 { throw TransportError(description: "Lost media start", possiblySent: true) }
                return old
            }
            defer { _ = owner.close() }
            _ = try owner.startPreview(options: .init(port: 0))
            old.pollError = IPhoneUseError("device_locked", "Locked")
            XCTAssertTrue(owner.previewTick())
            old.canResume = true
            XCTAssertEqual(owner.previewTick(), cleanupConfirmed)
            for _ in 0..<3 { XCTAssertFalse(owner.previewTick()) }
            XCTAssertEqual(starts, cleanupConfirmed ? 2 : 1)
            XCTAssertEqual(old.closed, 1)
            XCTAssertNil(owner.previewStatus["url"])
            XCTAssertEqual(owner.status()["reconnectRequired"] as? Bool, true)
        }
    }

    func testStoppedOrCancelledPreviewCannotResumeOnUnlock() throws {
        for cancel in [true, false] {
            let old = RunnerRecordingConnectionStub(), cancellation = NativeCancellation()
            var starts = 0
            let owner = RunnerNativeRecording(root: try root(), cancellation: cancellation) {
                starts += 1; return old
            }
            defer { _ = owner.close() }
            _ = try owner.startPreview(options: .init(port: 0))
            old.pollError = IPhoneUseError("device_locked", "Locked")
            XCTAssertTrue(owner.previewTick())
            if cancel { cancellation.cancel() } else { _ = try owner.stopPreview() }
            old.canResume = true
            XCTAssertFalse(owner.previewTick())
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(old.closed, 1)
        }
    }
}
