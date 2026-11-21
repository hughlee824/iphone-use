import XCTest
@testable import IPhoneUseCore

extension AXPObservationTests {
    func testSelectedScreenshotKeepsPixelsReadinessAndActualTimesEvenIfAXFails() throws {
        let image = try screenshot()
        var metadata = image.metadata
        metadata["captureStartedAt"] = 1.0
        metadata["captureCompletedAt"] = 2.0
        metadata["postActionStability"] = ["stable": true]
        let selected = CapturedObservation(nodes: [], metadata: metadata, screenshot: image.screenshot)
        for unavailable in [false, true] {
            var calls = 0
            let observation = try AXPObservation.captureSelected(selected, device: "device", generation: "generation",
                read: {
                    calls += 1
                    if unavailable { throw IPhoneUseError("ax_unavailable", "test") }
                    return self.payload()
                }, checkCancellation: {})
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(observation.screenshot, image.screenshot)
            XCTAssertEqual(observation.nodes.isEmpty, unavailable)
            XCTAssertEqual((observation.metadata["postActionStability"] as? [String: Bool])?["stable"], true)
            let intervals = try XCTUnwrap(observation.metadata["observationAcquisition"] as? [String: Any])
            XCTAssertEqual(intervals["strategy"] as? String, "selected_frame_then_ax")
            XCTAssertEqual(intervals["screenshot"] as? [String: Double], ["startedAt": 1, "finishedAt": 2])
            XCTAssertEqual(intervals["intervalsOverlap"] as? Bool, false)
        }
    }
}
