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
            return ["png": png.base64EncodedString(), "displayBefore": facts, "display": facts]
        })
        let image = try AppleCaptureAttempt(cli: cli, generation: "test", budget: nil).nativeObservation()
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(image.metadata["captureSource"] as? String, "instruments_screenshot")
        XCTAssertEqual(image.metadata["displayID"] as? UInt64, 1)
        XCTAssertEqual(image.screenshot, png)
    }
    func testInputCaptureUsesNativeGeometryWithoutExternalStateQueries() throws {
        let png = try nativePNG(), facts = display(backlight: "off")
        let budget = NativeCaptureBudget(requestDeadline: ProcessInfo.processInfo.systemUptime + 30)
        let cli = AppleDeviceCLI(device: "test", cancellation: NativeCancellation(), reader: { _ in
            XCTFail("Native capture must not spawn lock or display queries"); return [:]
        })
        var captures = 0
        cli.nativeScreenshot = NativeScreenshotReader(device: "test", read: { _ in
            XCTAssertNotNil(budget.validationStartedAt)
            captures += 1
            return ["png": png.base64EncodedString(), "displayBefore": facts, "display": facts]
        })
        let image = try cli.capture(generation: "test", budget: budget)
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(image.metadata["captureSource"] as? String, "instruments_screenshot")
        XCTAssertEqual((image.metadata["captureCommands"] as? [Any])?.count, 0)
    }
    func testNativeCaptureAcceptsBlackPixelsAndBacklightTransitions() throws {
        let png = try screenPNG(width: 12, height: 18,
                                patches: [(CGRect(x: 0, y: 0, width: 12, height: 18), [0, 0, 0])])
        for state in ["activeOn", "activeDimmed", "off", "inactive", "unknown"] {
            let cli = AppleDeviceCLI(device: "test", cancellation: NativeCancellation(), reader: { _ in
                XCTFail("A black/locked screen does not require a lock query"); return [:]
            })
            cli.nativeScreenshot = NativeScreenshotReader(device: "test", read: { _ in
                ["png": png.base64EncodedString(), "displayBefore": self.display(),
                 "display": self.display(backlight: state)]
            })
            XCTAssertEqual(try cli.capture(generation: "test").screenshot, png)
        }
    }
    func testUnverifiedNativeRotationRequiresDisplaySelectedScreenshot() throws {
        let png = try nativePNG(), facts = display("rot180")
        let reader = NativeScreenshotReader(device: "test", read: { _ in
            ["png": png.base64EncodedString(), "displayBefore": facts, "display": facts]
        })
        XCTAssertThrowsError(try reader.capture(cancelled: { false })) { error in
            XCTAssertEqual((error as? IPhoneUseError)?.code, "native_screenshot_orientation_unsupported")
        }
    }
    func testCaptureKeepsNativeTimingWithoutExternalQueries() throws {
        let png = try nativePNG(), facts = display()
        let cli = AppleDeviceCLI(device: "test", cancellation: NativeCancellation(), reader: { _ in
            XCTFail("Native sampling must not spawn external state queries"); return [:]
        })
        cli.nativeScreenshot = NativeScreenshotReader(device: "test", read: { _ in
            return ["png": png.base64EncodedString(), "displayBefore": facts, "display": facts,
                    "screenshotTimings": ["takeScreenshotMs": 120, "displayQueryMs": 8]]
        })
        let image = try cli.capture(generation: "test")
        let details = try XCTUnwrap(image.metadata["nativeScreenshotDiagnostics"] as? [String: Any])
        XCTAssertEqual(details["takeScreenshotMs"] as? Int, 120)
        XCTAssertNotNil(details["workerRoundTripMs"])
    }

    func testCutoffAfterDisplayReadFallsBackOnlyWithMatchingGeometry() throws {
        let old = try nativePNG(), portrait = display()
        for rotated in [false, true] {
            let next = rotated ? display("rot180") : portrait
            var time = 0.0
            let reader = NativeScreenshotReader(device: "test", read: { _ in
                if time == 0 {
                    time = 1
                    return ["png": old.base64EncodedString(), "displayBefore": portrait, "display": portrait]
                }
                time = 1.6
                return ["samplingEnded": true, "displayBefore": next]
            })
            let cli = AppleDeviceCLI(device: "test", cancellation: NativeCancellation())
            cli.nativeScreenshot = reader
            let history = NativeTapFrameWorker.DisplayHistory()
            let acquire = {
                try NativePostActionStability.capture(policy: .adjacentTap, now: { time }, pause: { _ in },
                    checkCancellation: {}, sample: { _ in
                        try history.sample { note in
                            try cli.capture(generation: "test", budget: NativeCaptureBudget(
                                requestDeadline: ProcessInfo.processInfo.systemUptime + 30, purpose: .observation,
                                screenshotStartDeadline: ProcessInfo.processInfo.systemUptime + 1, noteDisplay: note))
                        }
                    })
            }
            if rotated {
                XCTAssertThrowsError(try acquire()) {
                    XCTAssertEqual(($0 as? IPhoneUseError)?.code, "post_action_capture_timeout")
                }
            } else {
                let frame = try acquire()
                XCTAssertEqual(frame.screenshot, old)
                XCTAssertEqual((frame.metadata["postActionStability"] as? [String: Any])?["stable"] as? Bool, false)
            }
        }
    }
}
