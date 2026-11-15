import XCTest
@testable import IPhoneUseCore

final class ObservationAcquisitionTests: XCTestCase {
    func testRunnerUsesCommonNonAtomicDescriptionWithoutInventingScreenshotStart() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "app.json", withExtension: nil))
        var source = try jsonObject(Data(contentsOf: fixture))
        source["screenshotBase64"] = try screenPNG().base64EncodedString()
        source["snapshotStartedAt"] = 100.0
        source["snapshotFinishedAt"] = 100.3
        source["screenshotCapturedAt"] = 100.8
        let capture = try XCTestCapture.decode(source)
        let timing = try XCTUnwrap(capture.metadata["observationAcquisition"] as? [String: Any])
        XCTAssertEqual(timing["strategy"] as? String, "runner_serial")
        XCTAssertEqual(timing["clock"] as? String, "device_unix_seconds")
        XCTAssertEqual(timing["atomic"] as? Bool, false)
        let image = try XCTUnwrap(timing["screenshot"] as? [String: Any])
        XCTAssertTrue(image["startedAt"] is NSNull)
        XCTAssertEqual(image["finishedAt"] as? Double, 100.8)
        let lines = ObservationAcquisition.lines(capture.metadata).joined(separator: "\n")
        XCTAssertTrue(lines.contains("observation_atomic=false acquisition=runner_serial"))
        XCTAssertTrue(lines.contains("screenshot_request_started=null"))
    }
}
