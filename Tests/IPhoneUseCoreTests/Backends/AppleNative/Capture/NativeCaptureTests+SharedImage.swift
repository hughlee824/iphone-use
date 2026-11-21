import XCTest
import IPhoneUseRunnerSupport
@testable import IPhoneUseCore

extension NativeCaptureTests {
    func testSharedPixelsAcceptBlackAndPreserveOriginalPNGAndFrameHash() throws {
        for level: UInt8 in [0, 8, 9, 255] {
            let png = try screenPNG(
                width: 12, height: 18,
                patches: [(CGRect(x: 0, y: 0, width: 12, height: 18), [level, level, level])])
            let cli = AppleDeviceCLI(
                device: "fixture", cancellation: NativeCancellation(), reader: { _ in
                    XCTFail("Pixel validation must not query the device"); return [:]
                })
            let attempt = AppleCaptureAttempt(cli: cli, generation: "fixture", budget: nil)
            let display = try NativeDisplay(display())
            let fingerprint = try attempt.validate(png, display: display)
            let capture = try attempt.captured(png: png, fingerprint: fingerprint, display: display, geometry: [:])
            XCTAssertEqual(capture.screenshot, png)
            XCTAssertEqual(fingerprint.hash, try FrameFingerprint(png: png).hash)
        }
    }
}
