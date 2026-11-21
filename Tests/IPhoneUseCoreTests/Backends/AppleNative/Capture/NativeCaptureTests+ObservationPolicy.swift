import XCTest
import IPhoneUseRunnerSupport
@testable import IPhoneUseCore

extension NativeCaptureTests {
    func testDefaultTapReturnsPendingPNGThenReadsAXOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try SessionPaths.secureDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = directory.appendingPathComponent("ax-calls")
        let reader = AXPReader(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [
            "-c", "import sys; open(sys.argv[1], 'a').write('read\\n'); print('{}')", calls.path
        ])
        let backend = AppleDeviceBackend(
            config: HostConfiguration(session: "s" + String(repeating: "b", count: 32), device: "fixture",
                xctestrun: "fixture", idleTimeoutSeconds: 180), paths: SessionPaths(directory: directory),
            axpReader: reader)
        let png = try screenPNG(width: 12, height: 18)
        let cli = AppleDeviceCLI(device: "fixture", cancellation: backend.cancellation)
        var samples = 0
        cli.nativeScreenshot = NativeScreenshotReader(device: "fixture", read: { _ in
            samples += 1
            Thread.sleep(forTimeInterval: 1.6)
            XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path))
            return ["png": png.base64EncodedString(), "displayBefore": self.display(), "display": self.display()]
        })
        backend.cli = cli
        let result = try backend.observeAfterAction(actionKind: "tap", textOptions: nil,
            ignoring: nil, sourceContext: nil)
        XCTAssertEqual(samples, 1)
        XCTAssertEqual(result.screenshot, png)
        XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8), "read\n")
        let stability = try XCTUnwrap(result.metadata["postActionStability"] as? [String: Any])
        XCTAssertEqual(stability["stable"] as? Bool, false)
        let acquisition = try XCTUnwrap(result.metadata["observationAcquisition"] as? [String: Any])
        XCTAssertEqual(acquisition["strategy"] as? String, "selected_frame_then_ax")
        XCTAssertEqual(acquisition["intervalsOverlap"] as? Bool, false)
    }

    func testNativeGeometryChangesAndMissingEvidenceStillRejectPixels() throws {
        let png = try screenPNG(width: 12, height: 18)
        let original = display()
        for (key, value) in [
            ("displayId", 2), ("uniqueId", "other"), ("pointScale", 2),
            ("bounds", [[0, 0], [18, 12]]), ("currentOrientation", "rot180"),
            ("nativeOrientation", "rot180")
        ] as [(String, Any)] {
            var changed = original
            var displays = try XCTUnwrap(changed["displays"] as? [[String: Any]])
            displays[0][key] = value; changed["displays"] = displays
            let current = changed
            let reader = NativeScreenshotReader(device: "test", read: { _ in
                ["png": png.base64EncodedString(), "displayBefore": original, "display": current]
            })
            XCTAssertThrowsError(try reader.capture(cancelled: { false }), key)
        }
        for before: Any? in [nil, [:], ["displays": []]] {
            let reader = NativeScreenshotReader(device: "test", read: { _ in
                var payload: [String: Any] = ["png": png.base64EncodedString(), "display": original]
                payload["displayBefore"] = before
                return payload
            })
            XCTAssertThrowsError(try reader.capture(cancelled: { false }))
        }
    }

    func testNativeInvalidPixelsAndServiceFailureCannotFallBackToAnotherCapture() throws {
        for png in [Data("broken".utf8), try screenPNG(width: 18, height: 12)] {
            let cli = AppleDeviceCLI(device: "test", cancellation: NativeCancellation(), reader: { _ in
                XCTFail("Invalid pixels cannot cause source switching"); return [:]
            })
            cli.nativeScreenshot = NativeScreenshotReader(device: "test", read: { _ in
                ["png": png.base64EncodedString(), "displayBefore": self.display(), "display": self.display()]
            })
            XCTAssertThrowsError(try cli.capture(generation: "test"))
        }
        let cli = AppleDeviceCLI(device: "test", cancellation: NativeCancellation(), reader: { _ in
            XCTFail("Service failure cannot cause source switching"); return [:]
        })
        cli.nativeScreenshot = NativeScreenshotReader(device: "test", read: { _ in
            throw IPhoneUseError("observation_connection_failed", "fixture")
        })
        XCTAssertThrowsError(try cli.capture(generation: "test")) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "observation_connection_failed")
        }
    }

    func testNativeInputRetainsPixelTargetGuardWhenScreenBecomesBlack() throws {
        let base = try screenPNG(width: 12, height: 18)
        let black = try screenPNG(width: 12, height: 18,
                                  patches: [(CGRect(x: 0, y: 0, width: 12, height: 18), [0, 0, 0])])
        let display = try NativeDisplay(display())
        let guardValue = try ScreenGuard(png: base, context: display.context, rects: [display.screen], policy: .init())
        let cli = AppleDeviceCLI(device: "test", cancellation: NativeCancellation(), reader: { _ in
            XCTFail("Input capture must not query lock state"); return [:]
        })
        cli.nativeScreenshot = NativeScreenshotReader(device: "test", read: { _ in
            ["png": black.base64EncodedString(), "displayBefore": self.display(),
             "display": self.display(backlight: "off")]
        })
        let budget = NativeCaptureBudget(requestDeadline: ProcessInfo.processInfo.systemUptime + 30)
        XCTAssertThrowsError(try NativeInputPreflight.check(
            guard: guardValue, displayID: display.id, displayRotation: display.rotation,
            captureSource: "instruments_screenshot", deadline: budget.requestDeadline,
            maximumCaptures: 1, budget: budget, capture: { try cli.capture(generation: "test", budget: budget) })) {
            let failure = $0 as? ActionFailure
            XCTAssertEqual(failure?.possiblyExecuted, false)
            XCTAssertEqual(failure?.rejectedCapture?.screenshot, black)
            XCTAssertEqual(failure?.result?["preInputCaptures"] as? Int, 1)
        }
    }

    func testNativeCaptureChecksCancellationAndDeadlineAroundPixelRequest() throws {
        let png = try screenPNG(width: 12, height: 18)
        for phase in ["before", "during", "expired"] {
            let cancellation = NativeCancellation()
            let cli = AppleDeviceCLI(device: "test", cancellation: cancellation)
            let budget = NativeCaptureBudget(requestDeadline: ProcessInfo.processInfo.systemUptime
                + (phase == "expired" ? -1 : 30))
            var requests = 0
            cli.nativeScreenshot = NativeScreenshotReader(device: "test", read: { _ in
                requests += 1
                if phase == "during" { cancellation.cancel() }
                return ["png": png.base64EncodedString(), "displayBefore": self.display(), "display": self.display()]
            })
            if phase == "before" { cancellation.cancel() }
            XCTAssertThrowsError(try cli.capture(generation: "test", budget: budget), phase)
            XCTAssertEqual(requests, phase == "during" ? 1 : 0)
        }
    }

    func testDisplaySelectedFallbackAcceptsBlackImageWithoutLockOrBacklightGate() throws {
        let png = try screenPNG(width: 18, height: 12,
                               patches: [(CGRect(x: 0, y: 0, width: 18, height: 12), [0, 0, 0])])
        let facts = display("rot90", backlight: "off")
        var queries: [[String]] = []
        let cli = AppleDeviceCLI(device: "test", cancellation: NativeCancellation(), reader: { args in
            queries.append(args)
            if args.last == "displays" { return facts }
            XCTAssertEqual(Array(args.prefix(3)), ["device", "capture", "screenshot"])
            try png.write(to: URL(fileURLWithPath: try XCTUnwrap(args.last)))
            return [:]
        })
        cli.nativeScreenshot = NativeScreenshotReader(device: "test", read: { _ in
            ["png": png.base64EncodedString(), "displayBefore": facts, "display": facts]
        })
        let image = try cli.capture(generation: "test")
        XCTAssertEqual(image.screenshot, png)
        XCTAssertEqual(image.metadata["captureSource"] as? String, "coredevice_screenshot")
        XCTAssertEqual(image.metadata["displayRotation"] as? String, "rot90")
        XCTAssertEqual(queries.count, 3, "Two geometry reads bracket the explicitly selected PNG")
        XCTAssertFalse(queries.contains { $0.last == "lockState" })
    }
}
