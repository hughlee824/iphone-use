import XCTest
@testable import IPhoneUseCore

extension NativePostActionStabilityTests {
    private func sourceFrame(_ source: String) throws -> CapturedObservation {
        let original = try frame()
        var metadata = original.metadata
        metadata["captureSource"] = source
        return CapturedObservation(nodes: original.nodes, metadata: metadata, screenshot: original.screenshot)
    }

    func testNativeInstrumentsPNGSupportsUnchangedPostActionReadiness() throws {
        let native = try sourceFrame("instruments_screenshot")
        let result = try alternate(native, native)
        XCTAssertEqual(facts(result)["stable"] as? Bool, true)
        XCTAssertEqual(facts(result)["automaticReplayAllowed"] as? Bool, false)
        XCTAssertEqual(result.metadata["captureSource"] as? String, "instruments_screenshot")
    }

    func testPreviewAndUnknownSourcesRemainIneligibleEvenWithValidPixels() throws {
        for source in ["native_media", "preview", "unknown"] {
            let unsupported = try sourceFrame(source)
            XCTAssertThrowsError(try alternate(unsupported, unsupported)) { error in
                XCTAssertEqual((error as? IPhoneUseError)?.code, "invalid_action_frame")
            }
        }
    }

    func testSwitchingAppleProvidersCannotAccumulateStableSamples() throws {
        let result = try alternate(frame(), sourceFrame("instruments_screenshot"))
        XCTAssertEqual(facts(result)["stable"] as? Bool, false)
        XCTAssertEqual(facts(result)["consecutiveFrames"] as? Int, 1)
    }
}
