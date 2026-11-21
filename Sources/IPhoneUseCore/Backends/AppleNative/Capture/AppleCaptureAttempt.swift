import IPhoneUseRunnerSupport
import Foundation

// Confined to one capture operation. Native PNGs carry bracketing geometry;
// the display-selected fallback obtains its geometry through CoreDevice.
final class AppleCaptureAttempt {
    let cli: AppleDeviceCLI
    let generation: String
    let budget: NativeCaptureBudget?
    let started = Date().timeIntervalSince1970
    let monotonic = ProcessInfo.processInfo.systemUptime
    var timings: [String: Double] = [:]
    var intervals: [String: [String: Double]] = [:]
    let diagnostics = NativeCaptureDiagnostics()
    var phase = "checksBefore"
    var captureSource = "coredevice_screenshot"
    var screenshotLease: [String: Any] = [:]
    var screenshotDetails: [String: Any] = [:]

    init(cli: AppleDeviceCLI, generation: String, budget: NativeCaptureBudget?) {
        self.cli = cli
        self.generation = generation
        self.budget = budget
    }
    func timed<T>(_ name: String, _ operation: () throws -> T) rethrows -> T {
        phase = name
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            let finished = ProcessInfo.processInfo.systemUptime
            timings[name, default: 0] += (finished - start) * 1000
            intervals[name] = ["started": start, "finished": finished]
        }
        return try operation()
    }
    func read(_ arguments: [String], phase: String) throws -> [String: Any] {
        try diagnostics.read(arguments, phase: phase) { try self.cli.read(arguments, budget: budget) }
    }

    func run(
        prepareDisplay: (NativeDisplay) throws -> Void, validateDisplay: (NativeDisplay, Double) throws -> [String: Any]
    ) throws -> CapturedObservation {
        do {
            if cli.nativeScreenshot != nil {
                do {
                    return try nativeObservation(prepareDisplay: prepareDisplay, validateDisplay: validateDisplay)
                } catch let error as IPhoneUseError where Self.needsDisplaySelection(error) {
                    // Unsupported display selection retains CoreDevice's explicit PNG contract.
                }
            }
            let before = try timed("displayBefore") {
                try NativeDisplay(read(["device", "info", "displays"], phase: "displayBefore"))
            }
            budget?.noteDisplay?(before)
            try timed("prepareDisplay") { try prepareDisplay(before) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "iphone-use-screen-\(UUID().uuidString)")
            try SessionPaths.secureDirectory(directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appendingPathComponent("screen.png")
            let requestedAt = ProcessInfo.processInfo.systemUptime
            // Geometry evidence never supplies observation pixels. Apple PNG is
            // the only source, including after media recovery or screenshot failure.
            let geometry = try timed("displayGeometry") { try validateDisplay(before, requestedAt) }
            try budget?.beginValidation()
            try checkScreenshotStart()
            let png = try coreDevicePNG(before, destination: destination)
            let fingerprint = try timed("appleImageValidation") { try validate(png, display: before) }
            let after = try timed("displayAfter") {
                try NativeDisplay(read(["device", "info", "displays"], phase: "displayAfter"))
            }
            try cli.cancellation.check()
            budget?.noteDisplay?(after)
            phase = "displayConsistency"
            guard before.geometry == after.geometry else {
                throw IPhoneUseError("capture_context_changed", "Display changed during screenshot acquisition")
            }
            try budget?.check()
            timings["total"] = (ProcessInfo.processInfo.systemUptime - monotonic) * 1000
            return try captured(png: png, fingerprint: fingerprint, display: after, geometry: geometry)

        } catch {
            timings["total"] = (ProcessInfo.processInfo.systemUptime - monotonic) * 1000
            var facts: [String: Any] = ["failedStage": phase, "timingsMs": timings, "commands": diagnostics.commands]
            if let budget {
                facts["budgetPurpose"] = budget.purpose == .input ? "input" : "observation"
                facts["deadlineUptime"] = budget.deadline
                facts["requestDeadlineUptime"] = budget.requestDeadline
                facts["validationStartedUptime"] = budget.validationStartedAt
            }
            throw IPhoneUseError(
                (error as? IPhoneUseError)?.code ?? "capture_failed", String(describing: error),
                diagnostics: ["capture": facts])
        }
    }
    static func needsDisplaySelection(_ error: IPhoneUseError) -> Bool {
        ["native_screenshot_display_unsupported", "native_screenshot_orientation_unsupported"].contains(error.code)
    }
    private func coreDevicePNG(_ display: NativeDisplay, destination: URL) throws -> Data {
        _ = try timed("screenshot") {
            try read(display.screenshotArguments(destination: destination), phase: "screenshot")
        }
        return try timed("readPNG") { try Data(contentsOf: destination) }
    }
    func nativeObservation(
        prepareDisplay: (NativeDisplay) throws -> Void = { _ in },
        validateDisplay: (NativeDisplay, Double) throws -> [String: Any] = { _, _ in
            ["verification": "native_png_and_stable_display_metadata"]
        }
    ) throws -> CapturedObservation {
        guard let native = cli.nativeScreenshot else {
            throw IPhoneUseError("capture_unavailable", "Native screenshot unavailable")
        }
        try cli.cancellation.check(); try budget?.check()
        try budget?.beginValidation()
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let frame = try timed("screenshotAndDisplay") {
            try native.capture(startBefore: budget?.screenshotStartDeadline, noteDisplay: budget?.noteDisplay) {
                self.cli.cancellation.isCancelled
                    || self.budget.map { ProcessInfo.processInfo.systemUptime >= $0.deadline } == true
            }
        }
        try timed("prepareDisplay") { try prepareDisplay(frame.display) }
        let geometry = try timed("displayGeometry") { try validateDisplay(frame.display, requestedAt) }
        screenshotDetails = frame.diagnostics
        let fingerprint = try timed("appleImageValidation") { try validate(frame.png, display: frame.display) }
        try cli.cancellation.check(); try budget?.check()
        captureSource = "instruments_screenshot"; screenshotLease = frame.lease
        timings["total"] = (ProcessInfo.processInfo.systemUptime - monotonic) * 1000
        return try captured(png: frame.png, fingerprint: fingerprint, display: frame.display, geometry: geometry)
    }

    private func checkScreenshotStart() throws {
        if let cutoff = budget?.screenshotStartDeadline, ProcessInfo.processInfo.systemUptime >= cutoff {
            throw IPhoneUseError("capture_timeout", "Tap screenshot sampling has ended")
        }
    }

    func validate(_ png: Data, display before: NativeDisplay) throws -> FrameFingerprint {
        let fingerprint = try FrameFingerprint(png: png)
        guard fingerprint.width == Int(before.pixelWidth), fingerprint.height == Int(before.pixelHeight) else {
            throw IPhoneUseError(
                "native_screenshot_geometry_conflict", "Screenshot dimensions disagree with the current display")
        }
        return fingerprint
    }

    func captured(
        png: Data, fingerprint: FrameFingerprint, display after: NativeDisplay, geometry: [String: Any]
    ) throws -> CapturedObservation {
        return CapturedObservation(
            nodes: [],
            metadata: [
                "captureSource": captureSource, "screenshotConnectionLease": screenshotLease,
                "nativeScreenshotDiagnostics": screenshotDetails,
                "captureSourcePolicy": cli.captureSourcePolicy,
                "captureTimingsMs": timings, "captureIntervalsUptime": intervals,
                "captureCommands": diagnostics.commands, "displayGeometry": geometry,
                "backend": "apple-native", "deviceID": cli.device, "sessionGeneration": generation,
                "captureID": UUID().uuidString, "captureStartedAt": started,
                "captureCompletedAt": Date().timeIntervalSince1970, "captureStartedUptime": monotonic,
                "screenshotCapturedAt": Date().timeIntervalSince1970, "screenshotWidth": fingerprint.width,
                "screenshotHeight": fingerprint.height, "frameHash": fingerprint.hash, "displayID": after.id,
                "displayUniqueID": after.uniqueID as Any? ?? NSNull(),
                "displayRotation": after.rotation, "nativeRotation": after.nativeRotation,
                "coordinateSpace": "screen_points", "pointScale": after.scale,
                "imageTransform": ["cropOriginPixels": [0, 0], "resizeScale": 1, "pixelsPerPoint": after.scale],
                "screenFrame": try jsonObject(JSONEncoder().encode(after.screen)),
                "screenContext": try jsonObject(JSONEncoder().encode(after.context)), "scope": "screen",
                "foregroundBundleId": NSNull(), "keyboardState": "unknown", "axStatus": "unavailable",
                "axError": "Native backend uses screenshots; AX is not collected", "sourceTruncated": false,
                "validity": "valid"
            ], screenshot: png, validatedPixels: fingerprint)
    }
}
