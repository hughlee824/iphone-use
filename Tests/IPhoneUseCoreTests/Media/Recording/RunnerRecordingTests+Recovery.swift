import XCTest
@testable import IPhoneUseCore

extension RunnerRecordingTests {
    func testMediaLossPreservesPreviewAndRecoversWithoutRestartingRecording() throws {
        let old = RunnerRecordingConnectionStub(), fresh = RunnerRecordingConnectionStub()
        var clock = 0.0, starts = 0
        let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation(),
            now: { clock }, connect: {
            starts += 1; return starts == 1 ? old : fresh
        })
        defer { _ = owner.close() }
        let before = try owner.startPreview(options: .init(port: 0))
        let url = try XCTUnwrap(URL(string: XCTUnwrap(before["url"] as? String)))
        let recording = try owner.start(duration: 30)
        old.pollError = IPhoneUseError("native_media_unhealthy", "Stream lost")
        old.receiver.healthy = false
        XCTAssertTrue(owner.previewTick())
        XCTAssertEqual(try recoveryHTTPStatus(url), 200)
        XCTAssertEqual(old.closed, 1)
        XCTAssertTrue(owner.hasConsumers, "The capture process must not idle-exit during recovery")
        XCTAssertEqual(owner.previewStatus["state"] as? String, "transitioning")
        XCTAssertEqual(owner.previewStatus["url"] as? String, before["url"] as? String)
        XCTAssertEqual(try owner.startPreview()["url"] as? String, before["url"] as? String)
        XCTAssertThrowsError(try owner.start(duration: 30))
        for _ in 0..<4 { XCTAssertFalse(owner.previewTick()) }
        XCTAssertEqual(starts, 1)
        clock = 2
        XCTAssertTrue(owner.previewTick())
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(try recoveryHTTPStatus(url), 200)
        XCTAssertEqual(fresh.closed, 0)
        XCTAssertEqual(owner.previewStatus["url"] as? String, before["url"] as? String)
        XCTAssertNotEqual(owner.previewStatus["state"] as? String, "transitioning")
        XCTAssertNil(owner.status()["reconnectRequired"])
        let result = try owner.stop(id: XCTUnwrap(recording["recordingID"] as? String))
        XCTAssertEqual(result["stopReason"] as? String, "preview_media_recovery")
        XCTAssertEqual(starts, 2, "Recovery does not replay record-start")
    }

    func testRepeatedSafeStartFailuresBackOffAndKeepTheSameURL() throws {
        let old = RunnerRecordingConnectionStub(), fresh = RunnerRecordingConnectionStub()
        var clock = 0.0, starts = 0
        let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation(),
            now: { clock }, connect: {
            starts += 1
            if starts > 1 && starts < 4 {
                throw ActionFailure(code: "display_changed", description: "Still folding", possiblyExecuted: false,
                    requiresObservation: true,
                    result: ["recordingCleanup": ["mediaStopAcknowledged": true, "tunnelReleaseAcknowledged": true]])
            }
            return starts == 1 ? old : fresh
        })
        defer { _ = owner.close() }
        let before = try owner.startPreview(options: .init(port: 0))
        old.pollError = IPhoneUseError("native_media_unhealthy", "Lost")
        XCTAssertTrue(owner.previewTick())
        for (time, expected) in [(1.0, 1), (2, 2), (5, 2), (6, 3), (13, 3), (14, 4)] {
            clock = time; _ = owner.previewTick()
            XCTAssertEqual(starts, expected)
            XCTAssertEqual(owner.previewStatus["url"] as? String, before["url"] as? String)
        }
        XCTAssertEqual(fresh.closed, 0)
        XCTAssertNil(owner.status()["reconnectRequired"])
    }

    func testRecoveryValidatesFreshMediaWithoutDiscardingItOnOneReadTimeout() throws {
        let old = RunnerRecordingConnectionStub(), fresh = RunnerRecordingConnectionStub()
        var clock = 0.0, starts = 0, probes = 0
        fresh.onValidation = {
            probes += 1
            if probes == 1 { throw IPhoneUseError("coredevice_timeout", "Transient read") }
        }
        let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation(),
            now: { clock }, connect: {
            starts += 1; return starts == 1 ? old : fresh
        })
        defer { _ = owner.close() }
        _ = try owner.startPreview(options: .init(port: 0))
        old.pollError = IPhoneUseError("native_media_unhealthy", "Lost")
        _ = owner.previewTick(); clock = 2
        XCTAssertTrue(owner.previewTick())
        XCTAssertEqual(owner.previewStatus["state"] as? String, "transitioning")
        XCTAssertTrue(owner.previewTick())
        XCTAssertEqual(probes, 2)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(fresh.closed, 0)
    }

    func testRecoveryNeverRetriesUncertainStartsOrUnconfirmedCleanup() throws {
        for problem in ["old_cleanup", "start_unknown", "start_cleanup", "invalid_reply"] {
            let old = RunnerRecordingConnectionStub()
            old.acknowledged = problem != "old_cleanup"
            var clock = 0.0, starts = 0
            let owner = RunnerNativeRecording(root: try root(), cancellation: NativeCancellation(),
            now: { clock }, connect: {
                starts += 1
                if starts > 1 {
                    throw ActionFailure(code: problem == "invalid_reply" ? "native_device_mismatch" : "display_changed",
                        description: problem, possiblyExecuted: problem == "start_unknown", requiresObservation: true,
                        result: ["recordingCleanup": ["mediaStopAcknowledged": problem != "start_cleanup",
                                                      "tunnelReleaseAcknowledged": true]])
                }
                return old
            })
            defer { _ = owner.close() }
            _ = try owner.startPreview(options: .init(port: 0))
            old.pollError = IPhoneUseError("native_media_unhealthy", "Lost")
            _ = owner.previewTick(); clock = 2; _ = owner.previewTick()
            clock = 100
            for _ in 0..<3 { XCTAssertFalse(owner.previewTick()) }
            XCTAssertEqual(starts, problem == "old_cleanup" ? 1 : 2)
            XCTAssertEqual(old.closed, 1)
            XCTAssertEqual(owner.status()["reconnectRequired"] as? Bool, true)
        }
    }

    func testStopAndCancellationPreventPendingRecovery() throws {
        for stop in [true, false] {
            let old = RunnerRecordingConnectionStub(), cancellation = NativeCancellation()
            var clock = 0.0, starts = 0
            let owner = RunnerNativeRecording(root: try root(), cancellation: cancellation, now: { clock }, connect: {
                starts += 1; return old
            })
            defer { _ = owner.close() }
            _ = try owner.startPreview(options: .init(port: 0))
            old.pollError = IPhoneUseError("native_media_unhealthy", "Lost")
            _ = owner.previewTick()
            if stop { _ = try owner.stopPreview() } else { cancellation.cancel() }
            clock = 100
            XCTAssertFalse(owner.previewTick())
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(old.closed, 1)
        }
    }

    private func recoveryHTTPStatus(_ url: URL) throws -> Int {
        let done = expectation(description: "Original preview remains reachable")
        var status: Int?, failure: Error?
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { _, response, error in
            status = (response as? HTTPURLResponse)?.statusCode
            failure = error; done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        if let failure { throw failure }
        return try XCTUnwrap(status)
    }

    func testRecoveryDelayIsCappedWithoutAnAttemptLimit() {
        var policy = RunnerPreviewRecovery(), clock = 0.0
        for expected in [2.0, 4, 8, 16, 30, 30, 30] {
            policy.schedule(now: clock)
            XCTAssertEqual(policy.nextAttempt, clock + expected)
            XCTAssertFalse(policy.takeAttempt(now: clock + expected - 0.01))
            clock += expected
            XCTAssertTrue(policy.takeAttempt(now: clock))
            XCTAssertFalse(policy.takeAttempt(now: clock))
        }
    }
}
