import XCTest
@testable import IPhoneUseCore

final class PreviewCaptureHostTests: XCTestCase {
    func testLockedPreviewReadsOnlyTopologyWhileAutomationStillRequiresUnlock() throws {
        let display: [String: Any] = ["backlightState": "activeOn", "displays": [
            ["primary": true, "displayId": 1, "bounds": [[0, 0], [32, 48]], "pointScale": 1,
             "currentOrientation": "rot0", "nativeOrientation": "rot0"]]]
        var requests: [[String]] = []
        let facts = try NativePreviewDisplay.read {
            requests.append($0)
            return $0.last == "lockState" ? ["passcodeRequired": true] : display
        }
        XCTAssertEqual(facts.pixelWidth, 32)
        XCTAssertEqual(requests, [["device", "info", "displays"]])
        XCTAssertThrowsError(try NativeCaptureChecks.read {
            $0.last == "lockState" ? ["passcodeRequired": true] : display
        }) { XCTAssertEqual(($0 as? IPhoneUseError)?.code, "device_locked") }
    }
    private func fixture() throws -> (PreviewCaptureHost, RunnerRecordingConnectionStub) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try SessionPaths.secureDirectory(directory)
        let connection = RunnerRecordingConnectionStub()
        let media = RunnerNativeRecording(root: directory, cancellation: NativeCancellation()) { connection }
        addTeardownBlock { _ = media.close(); try? FileManager.default.removeItem(at: directory) }
        return (PreviewCaptureHost(media: media), connection)
    }

    func testPreviewWithoutControlSurvivesControlOwnerRelease() throws {
        let (host, connection) = try fixture()
        let preview = try host.media.startPreview(options: .init(port: 0))
        let owner = UUID().uuidString
        _ = try host.result(["version": 1, "op": "release-recording", "owner": owner])
        XCTAssertEqual(connection.closed, 0)
        XCTAssertEqual(host.media.previewStatus["url"] as? String, preview["url"] as? String)
        XCTAssertTrue(host.media.previewStatus["connection"] is NSNull)
        _ = try host.result(["version": 1, "op": "preview-stop"])
        XCTAssertEqual(connection.closed, 1)
    }

    func testReleasingOneControlOwnerCannotStopAnotherRecordingOrPreview() throws {
        let (host, connection) = try fixture()
        _ = try host.media.startPreview(options: .init(port: 0))
        let owner = UUID().uuidString, other = UUID().uuidString
        let record = try host.result(["version": 1, "op": "record-start", "owner": owner, "duration": 30])
        let identifier = try XCTUnwrap(record["recordingID"] as? String)
        _ = try host.result(["version": 1, "op": "release-recording", "owner": other])
        XCTAssertEqual(host.media.status()["state"] as? String, "waiting_for_frame")
        XCTAssertThrowsError(try host.result([
            "version": 1, "op": "record-stop", "owner": other, "recordingID": identifier]))
        _ = try host.result(["version": 1, "op": "release-recording", "owner": owner])
        XCTAssertNotEqual(host.media.status()["state"] as? String, "waiting_for_frame")
        XCTAssertEqual(connection.closed, 0)
        XCTAssertNotNil(host.media.previewStatus["url"])
    }

    func testStoppingPreviewKeepsIndependentRecording() throws {
        let (host, connection) = try fixture()
        _ = try host.media.startPreview(options: .init(port: 0))
        let owner = UUID().uuidString
        _ = try host.result(["version": 1, "op": "record-start", "owner": owner, "duration": 30])
        let result = try host.result(["version": 1, "op": "preview-stop"])
        XCTAssertEqual(result["mediaRetainedForRecording"] as? Bool, true)
        XCTAssertEqual(connection.closed, 0)
        XCTAssertEqual(host.media.status()["state"] as? String, "waiting_for_frame")
        _ = try host.result(["version": 1, "op": "release-recording", "owner": owner])
        XCTAssertEqual(connection.closed, 1)
    }

    func testGestureDecorationRejectsMalformedValuesAndDoesNotStartMedia() throws {
        let (host, connection) = try fixture()
        XCTAssertThrowsError(try host.result(["version": 1, "op": "gesture", "kind": "tap"]))
        XCTAssertThrowsError(try host.result(["version": 2, "op": "preview-stop"]))
        XCTAssertEqual(connection.closed, 0)
        XCTAssertEqual(host.media.previewStatus["state"] as? String, "stopped")
    }
}
