import XCTest
@testable import IPhoneUseCore

extension RunnerRecordingTests {
    func testDirectionChangeDuringReadOnlyProbeKeepsHealthyMediaUntilNextPoll() throws {
        let connection = RunnerRecordingConnectionStub()
        var probes = 0
        let owner = RunnerNativeRecording(
            root: try root(), cancellation: NativeCancellation(),
            previewGeometry: { _ in
                probes += 1
                if probes == 1 {
                    throw IPhoneUseError("preview_geometry_conflict", "Changed between two display reads")
                }
                return RunnerPreviewGeometry(width: 32, height: 48, orientation: 1)
            }, connect: { connection })
        defer { _ = owner.close() }
        let before = try owner.startPreview(options: .init(port: 0))
        XCTAssertFalse(owner.previewTick())
        XCTAssertFalse(owner.previewTick())
        XCTAssertEqual(probes, 2)
        XCTAssertEqual(connection.closed, 0)
        XCTAssertEqual(connection.previewRefreshes, 0)
        XCTAssertEqual(owner.previewStatus["url"] as? String, before["url"] as? String)
        XCTAssertNotEqual(owner.previewStatus["state"] as? String, "failed")
    }

    func testPostBindDirectionReadPrecedesIndependentGeometryValidation() throws {
        let connection = RunnerRecordingConnectionStub()
        connection.rotation = "rot90"
        connection.onValidation = { connection.rotation = "rot180" }
        var verified = false
        let owner = RunnerNativeRecording(
            root: try root(), cancellation: NativeCancellation(),
            previewGeometry: { display in
                XCTAssertEqual(display.rotation, "rot180")
                verified = true
                return RunnerPreviewGeometry(width: 32, height: 48, orientation: 3)
            }, connect: { connection })
        defer { _ = owner.close() }
        _ = try owner.startPreview(options: .init(port: 0))
        connection.changed = true
        XCTAssertTrue(owner.previewTick())
        XCTAssertTrue(verified)
        XCTAssertEqual(connection.previewRefreshes, 1)
        XCTAssertEqual(connection.closed, 0)
        XCTAssertNotEqual(owner.previewStatus["state"] as? String, "transitioning")
    }

    func testSuccessfulRebindWaitsForGeometryWithoutReplacingMediaAgain() throws {
        let connection = RunnerRecordingConnectionStub()
        var probes = 0
        let owner = RunnerNativeRecording(
            root: try root(), cancellation: NativeCancellation(),
            previewGeometry: { display in
                XCTAssertEqual(display.rotation, "rot90")
                probes += 1
                return RunnerPreviewGeometry(width: 32, height: 48, orientation: probes == 1 ? 1 : 6)
            }, connect: { connection })
        defer { _ = owner.close() }
        let initial = try owner.startPreview(options: .init(port: 0))
        connection.changed = true; connection.refreshedRotation = "rot90"
        XCTAssertTrue(owner.previewTick())
        XCTAssertEqual(owner.previewStatus["state"] as? String, "transitioning")
        XCTAssertEqual(owner.previewStatus["url"] as? String, initial["url"] as? String)
        XCTAssertEqual(connection.closed, 0)
        XCTAssertThrowsError(try owner.start(duration: 30)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "preview_validation_pending")
        }
        XCTAssertTrue(owner.previewTick())
        XCTAssertEqual(probes, 2)
        XCTAssertEqual(connection.previewRefreshes, 1)
        XCTAssertEqual(connection.closed, 0)
        XCTAssertNotEqual(owner.previewStatus["state"] as? String, "transitioning")
    }

    func testPostRebindReadTimeoutCanSettleButInvalidRepliesRemainTerminal() throws {
        for code in ["coredevice_timeout", "display_unavailable", "preview_geometry_invalid", "device_locked"] {
            let connection = RunnerRecordingConnectionStub()
            var probes = 0
            let owner = RunnerNativeRecording(
                root: try root(), cancellation: NativeCancellation(),
                previewGeometry: { _ in
                    probes += 1
                    if probes == 1 { throw IPhoneUseError(code, "Fixture probe failed") }
                    return RunnerPreviewGeometry(width: 32, height: 48, orientation: 1)
                }, connect: { connection })
            defer { _ = owner.close() }
            _ = try owner.startPreview(options: .init(port: 0))
            connection.changed = true
            XCTAssertTrue(owner.previewTick())
            let transient = ["coredevice_timeout", "display_unavailable"].contains(code)
            XCTAssertEqual(connection.closed, transient ? 0 : 1)
            XCTAssertEqual(owner.previewTick(), transient)
            XCTAssertEqual(probes, transient ? 2 : 1)
            XCTAssertEqual(connection.previewRefreshes, 1)
        }
    }

    func testPendingValidationBoundsAttemptsAndStopsOnCancellationOrMediaLoss() throws {
        for ending in ["attempts", "cancel", "media"] {
            let connection = RunnerRecordingConnectionStub(), cancellation = NativeCancellation()
            var probes = 0
            let owner = RunnerNativeRecording(
                root: try root(), cancellation: cancellation,
                previewGeometry: { _ in
                    probes += 1
                    throw IPhoneUseError("preview_geometry_conflict", "Not settled")
                }, now: { 0 }, connect: { connection })
            defer { _ = owner.close() }
            _ = try owner.startPreview(options: .init(port: 0))
            connection.changed = true
            XCTAssertTrue(owner.previewTick())
            if ending == "cancel" {
                cancellation.cancel()
                XCTAssertFalse(owner.previewTick())
                _ = owner.close()
            } else {
                if ending == "media" { connection.receiver.healthy = false }
                _ = owner.previewTick(); _ = owner.previewTick()
            }
            XCTAssertEqual(probes, ending == "attempts" ? 3 : 1)
            XCTAssertEqual(connection.previewRefreshes, 1)
            XCTAssertEqual(connection.closed, 1)
        }
    }

    func testPreviewProbePreservesDisplayFailuresAndChecksBoundIdentity() throws {
        XCTAssertThrowsError(try XCTestBackend.decodePreviewGeometry([
            "ok": false, "error": ["code": "display_unavailable"]
        ])) { XCTAssertEqual(($0 as? IPhoneUseError)?.code, "display_unavailable") }
        let connection = RunnerRecordingConnectionStub()
        let before = try XCTUnwrap(connection.previewDisplay)
        try XCTestBackend.validatePreviewDisplay(before, expected: before)
        connection.rotation = "rot90"
        XCTAssertThrowsError(try XCTestBackend.validatePreviewDisplay(
            XCTUnwrap(connection.previewDisplay), expected: before)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "preview_geometry_conflict")
        }
    }

    func testOnlyIdentifiedReadOnlyTransportTimeoutMayWait() {
        let pending = RunnerPreviewValidation(reason: "display_changed", deadline: 6, attempts: 1)
        XCTAssertTrue(pending.canWait(
            TransportError(description: "Timeout", possiblySent: true, code: "runner_socket_timeout"),
            healthy: true, now: 1))
        for code: String? in [nil, "mismatched_response", "runner_session_changed"] {
            XCTAssertFalse(pending.canWait(
                TransportError(description: "Failure", possiblySent: true, code: code), healthy: true, now: 1))
        }
    }
}
