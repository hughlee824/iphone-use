import XCTest
@testable import IPhoneUseCore

extension PreviewCaptureHostTests {
    private func recordingHost(
        connect: @escaping () throws -> RunnerRecordingConnection
    ) throws -> PreviewCaptureHost {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try SessionPaths.secureDirectory(directory)
        let media = RunnerNativeRecording(root: directory, cancellation: NativeCancellation(), connect: connect)
        addTeardownBlock { _ = media.close(); try? FileManager.default.removeItem(at: directory) }
        return PreviewCaptureHost(media: media)
    }

    private func request(_ operation: String, owner: String) -> [String: Any] {
        ["version": 1, "op": operation, "owner": owner, "duration": 30]
    }

    func testReleasedPreparationFailureAllowsNewControlOwnerToRecord() throws {
        for code in ["device_locked", "display_changed", "coredevice_timeout"] {
            let old = RunnerRecordingConnectionStub(), fresh = RunnerRecordingConnectionStub()
            old.displayError = IPhoneUseError(code, "Preparation rejected")
            var starts = 0
            let host = try recordingHost { starts += 1; return starts == 1 ? old : fresh }
            let owner = UUID().uuidString, reconnected = UUID().uuidString
            XCTAssertThrowsError(try host.result(request("record-start", owner: owner))) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, code)
            }
            XCTAssertEqual(old.closed, 1)
            XCTAssertFalse(old.receiver.attached)
            XCTAssertFalse(host.media.recording.isActive)
            _ = try host.result(request("release-recording", owner: owner))
            _ = try host.result(request("status", owner: reconnected))
            host.media.checkDisplay()
            XCTAssertEqual(starts, 1, "Cleanup and polling must not replay recording startup")
            let result = try host.result(request("record-start", owner: reconnected))
            XCTAssertNotNil(result["recordingID"])
            XCTAssertTrue(fresh.receiver.attached)
            XCTAssertEqual(starts, 2)
            XCTAssertNil(host.media.preview)
            _ = try host.result(request("release-recording", owner: reconnected))
            XCTAssertEqual(fresh.closed, 1)
        }
    }

    func testConfirmedConnectionRejectionAllowsOnlyNextExplicitStart() throws {
        let fresh = RunnerRecordingConnectionStub()
        var starts = 0
        let host = try recordingHost {
            starts += 1
            if starts == 1 {
                throw ActionFailure(code: "device_locked", description: "Locked before writer startup",
                    possiblyExecuted: false, requiresObservation: true,
                    result: ["recordingCleanup": ["mediaStopAcknowledged": true,
                                                  "tunnelReleaseAcknowledged": true]])
            }
            return fresh
        }
        let owner = UUID().uuidString
        XCTAssertThrowsError(try host.result(request("record-start", owner: owner))) {
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false)
        }
        XCTAssertEqual(starts, 1)
        let result = try host.result(request("record-start", owner: owner))
        XCTAssertNotNil(result["recordingID"])
        XCTAssertEqual(starts, 2)
    }

    func testUnconfirmedPreparationCleanupBlocksRecordingAcrossOwnerRelease() throws {
        for unconfirmedMedia in [true, false] {
            let connection = RunnerRecordingConnectionStub()
            // Even affirmative error details cannot override a failed close of
            // the actual connection held by this request.
            connection.displayError = ActionFailure(code: "device_locked", description: "Locked",
                possiblyExecuted: false, requiresObservation: true,
                result: ["recordingCleanup": ["mediaStopAcknowledged": true, "tunnelReleaseAcknowledged": true]])
            connection.acknowledged = !unconfirmedMedia
            connection.tunnelAcknowledged = unconfirmedMedia
            var starts = 0
            let host = try recordingHost { starts += 1; return connection }
            let owner = UUID().uuidString
            XCTAssertThrowsError(try host.result(request("record-start", owner: owner)))
            _ = try host.result(request("release-recording", owner: owner))
            XCTAssertThrowsError(try host.result(request("record-start", owner: UUID().uuidString))) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, "recording_reconnect_required")
            }
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(connection.closed, 1)
            XCTAssertFalse(connection.receiver.attached)
        }
    }

    func testUncertainOrUnverifiedConnectionFailureIsNotResetByOldCleanupFacts() throws {
        let released = ["mediaStopAcknowledged": true, "tunnelReleaseAcknowledged": true]
        let failures: [Error] = [
            ActionFailure(code: "device_locked", description: "Unknown start", possiblyExecuted: true,
                requiresObservation: true, result: ["recordingCleanup": released]),
            ActionFailure(code: "device_locked", description: "Missing cleanup", possiblyExecuted: false,
                requiresObservation: true),
            ActionFailure(code: "display_changed", description: "Unreleased tunnel", possiblyExecuted: false,
                requiresObservation: true,
                result: ["recordingCleanup": ["mediaStopAcknowledged": true, "tunnelReleaseAcknowledged": false]]),
            ActionFailure(code: "native_device_mismatch", description: "Wrong identity", possiblyExecuted: false,
                requiresObservation: true, result: ["recordingCleanup": released]),
            IPhoneUseError("device_locked", "No current connection cleanup facts"),
            TransportError(description: "Lost start reply", possiblySent: true)
        ]
        for failure in failures {
            var starts = 0
            let host = try recordingHost { starts += 1; throw failure }
            host.media.cleanup = released // A previous connection's success proves nothing about this attempt.
            let owner = UUID().uuidString
            XCTAssertThrowsError(try host.result(request("record-start", owner: owner)))
            _ = try host.result(request("release-recording", owner: owner))
            XCTAssertThrowsError(try host.result(request("record-start", owner: UUID().uuidString))) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, "recording_reconnect_required")
            }
            XCTAssertEqual(starts, 1)
        }
    }

    func testRecordingRejectionLeavesExistingPreviewAndOtherRecordingUntouched() throws {
        let connection = RunnerRecordingConnectionStub()
        var starts = 0
        let host = try recordingHost { starts += 1; return connection }
        let preview = try host.media.startPreview(options: .init(port: 0))
        let owner = UUID().uuidString, other = UUID().uuidString
        connection.displayError = IPhoneUseError("device_locked", "Lock screen preview is allowed")
        XCTAssertThrowsError(try host.result(request("record-start", owner: owner)))
        _ = try host.result(request("release-recording", owner: owner))
        XCTAssertEqual(host.media.previewStatus["url"] as? String, preview["url"] as? String)
        XCTAssertEqual(connection.closed, 0)
        connection.displayError = nil
        let recording = try host.result(request("record-start", owner: owner))
        XCTAssertThrowsError(try host.result(request("record-start", owner: other))) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "recording_busy")
        }
        _ = try host.result(request("release-recording", owner: other))
        XCTAssertTrue(host.media.recording.isActive)
        XCTAssertEqual(host.media.status()["recordingID"] as? String, recording["recordingID"] as? String)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(connection.closed, 0)
        XCTAssertEqual(host.media.previewStatus["url"] as? String, preview["url"] as? String)
    }

    func testPreWriterClockRejectionAllowsExplicitRetryWithFreshMedia() throws {
        let connection = RunnerRecordingConnectionStub(), fresh = RunnerRecordingConnectionStub()
        connection.receiver.clockConfirmed = false
        var starts = 0
        let host = try recordingHost { starts += 1; return starts == 1 ? connection : fresh }
        let owner = UUID().uuidString
        XCTAssertThrowsError(try host.result(request("record-start", owner: owner))) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_recording_format_unavailable")
        }
        XCTAssertEqual(connection.closed, 1)
        XCTAssertFalse(connection.receiver.attached)
        XCTAssertEqual(starts, 1)
        _ = try host.result(request("release-recording", owner: owner))
        XCTAssertNotNil(try host.result(request("record-start", owner: UUID().uuidString))["recordingID"])
        XCTAssertEqual(starts, 2)
        XCTAssertTrue(fresh.receiver.attached)
    }
}
