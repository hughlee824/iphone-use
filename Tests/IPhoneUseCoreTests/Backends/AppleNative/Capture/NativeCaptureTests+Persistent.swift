import XCTest
import CoreGraphics
import ImageIO
@testable import IPhoneUseCore

extension NativeCaptureTests {
    private func nativePNG() throws -> Data {
        let color = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 18, bitsPerComponent: 8,
                                            bytesPerRow: 48, space: color,
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 12, height: 18))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    func testOrdinaryNativeObservationUsesOneScreenshotDisplayReplyAndNoLockQuery() throws {
        let png = try nativePNG(), facts = display()
        let cli = AppleDeviceCLI(device: "test", cancellation: NativeCancellation(), reader: { _ in
            XCTFail("Ordinary native observation must not spawn devicectl queries")
            return [:]
        })
        var captures = 0
        cli.nativeScreenshot = NativeScreenshotReader(device: "test", read: { _ in
            captures += 1
            return ["png": png.base64EncodedString(), "display": facts]
        })
        let image = try AppleCaptureAttempt(cli: cli, generation: "test", budget: nil).nativeObservation()
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(image.metadata["captureSource"] as? String, "instruments_screenshot")
        XCTAssertEqual(image.metadata["displayID"] as? UInt64, 1)
        XCTAssertEqual(image.screenshot, png)
    }
    func testStrictCapturePreservesLockAndDisplayChecksAroundNativePixels() throws {
        let png = try nativePNG(), facts = display()
        let counts = State()
        let cli = AppleDeviceCLI(device: "test", cancellation: NativeCancellation(), reader: { arguments in
            counts.lock.lock(); defer { counts.lock.unlock() }
            if arguments == ["device", "info", "lockState"] {
                counts.screenshots += 1; return ["passcodeRequired": false]
            }
            XCTAssertEqual(arguments, ["device", "info", "displays"])
            return facts
        })
        cli.nativeScreenshot = NativeScreenshotReader(device: "test", read: { _ in
            ["png": png.base64EncodedString(), "display": facts]
        })
        let image = try cli.capture(generation: "test")
        XCTAssertEqual(counts.screenshots, 2)
        XCTAssertEqual(image.metadata["captureSource"] as? String, "instruments_screenshot")
    }
    func testLockedInputCaptureNeverRequestsNativePixels() throws {
        let cli = AppleDeviceCLI(device: "test", cancellation: NativeCancellation(), reader: { arguments in
            arguments.last == "lockState" ? ["passcodeRequired": true] : self.display()
        })
        cli.nativeScreenshot = NativeScreenshotReader(device: "test", read: { _ in
            XCTFail("Locked input preflight must fail before screenshot"); return [:]
        })
        XCTAssertThrowsError(try cli.capture(generation: "test"))
    }
    func testUnverifiedNativeRotationRequiresDisplaySelectedScreenshot() throws {
        let png = try nativePNG(), facts = display("rot180")
        let reader = NativeScreenshotReader(device: "test", read: { _ in
            ["png": png.base64EncodedString(), "display": facts]
        })
        XCTAssertThrowsError(try reader.capture(cancelled: { false })) { error in
            XCTAssertEqual((error as? IPhoneUseError)?.code, "native_screenshot_orientation_unsupported")
        }
    }
}
