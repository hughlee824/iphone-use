import XCTest
import IPhoneUseRunnerSupport
@testable import IPhoneUseCore

extension NativeCaptureTests {
    func testInputRejectsChangedDisplayUUIDEvenWhenPixelsAndNumericIDMatch() throws {
        let png = try screenPNG(width: 12, height: 18)
        let display = try NativeDisplay(display())
        let guardValue = try ScreenGuard(
            png: png, context: display.context, rects: [display.screen], policy: .init())
        let context = try jsonObject(JSONEncoder().encode(display.context))
        func check(_ uniqueID: String) throws {
            _ = try NativeInputPreflight.check(
                guard: guardValue, displayID: display.id, displayUniqueID: "outer",
                deadline: 8, maximumCaptures: 1, now: { 0 }, capture: {
                    CapturedObservation(nodes: [], metadata: ["displayID": display.id,
                        "displayUniqueID": uniqueID, "screenContext": context], screenshot: png)
                })
        }
        XCTAssertNoThrow(try check("outer"))
        XCTAssertThrowsError(try check("inner")) {
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false)
            XCTAssertEqual(($0 as? ActionFailure)?.result?["screenContextChanged"] as? Bool, true)
        }
    }

    func testControlUsesOwnScreenshotsWithoutMediaAndStillRejectsLockAndWrongGeometry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try SessionPaths.secureDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = AppleDeviceBackend(
            config: HostConfiguration(session: "s" + String(repeating: "b", count: 32),
                                      device: "fixture", xctestrun: "fixture", idleTimeoutSeconds: 180),
            paths: SessionPaths(directory: directory))
        let transport = ScriptedTransport()
        let hid = NativeHIDAdapter(transport: transport, cancellation: backend.cancellation)
        try hid.prepare(); backend.hid = hid
        var locked = false, screenshots = 0
        var png = try screenPNG(width: 12, height: 18)
        backend.cli = AppleDeviceCLI(device: "fixture", cancellation: backend.cancellation, reader: {
            if $0.last == "lockState" { return ["passcodeRequired": locked] }
            if $0.last == "displays" { return self.display() }
            screenshots += 1
            try png.write(to: URL(fileURLWithPath: try XCTUnwrap($0.last)))
            return [:]
        })
        XCTAssertTrue(backend.controlStatus().available)
        XCTAssertNoThrow(try backend.checkInputAvailability())
        let observation = try backend.observe()
        XCTAssertEqual(observation.screenshot, png)
        XCTAssertEqual(observation.metadata["captureSource"] as? String, "coredevice_screenshot")
        XCTAssertEqual(transport.requests.count, 1, "Only HID preparation; no media inventory or preview request")
        XCTAssertTrue(transport.sends.isEmpty)
        locked = true
        XCTAssertThrowsError(try backend.observe()) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "device_locked")
        }
        XCTAssertEqual(screenshots, 1)
        locked = false; png = try screenPNG(width: 18, height: 12)
        XCTAssertThrowsError(try backend.observe()) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_screenshot_geometry_conflict")
        }
        backend.cancelCurrent()
        XCTAssertThrowsError(try backend.checkInputAvailability())
        XCTAssertFalse(backend.controlStatus().available)
    }
}
