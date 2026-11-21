import Foundation
import ImageIO

final class NativeScreenshotReader {
    struct Frame {
        let png: Data
        let display: NativeDisplay
        let lease: [String: Any]
        let diagnostics: [String: Any]
    }
    let worker: NativeObservationWorker
    private let read: ((() -> Bool) throws -> [String: Any])?
    init(device: String, read: ((() -> Bool) throws -> [String: Any])? = nil) {
        worker = NativeObservationWorker(device: device, kind: "screenshot"); self.read = read
    }
    static func supports(_ hardware: [String: Any]) -> Bool {
        guard let product = hardware["productType"] as? String, product.hasPrefix("iPhone") else { return false }
        return product != "iPhone19,4" // Duo requires explicit active-display selection via devicectl.
    }
    func capture(startBefore: TimeInterval? = nil, noteDisplay: ((NativeDisplay) -> Void)? = nil,
                 cancelled: () -> Bool) throws -> Frame {
        let started = ProcessInfo.processInfo.systemUptime
        let payload = try read?(cancelled) ?? worker.read(startBefore: startBefore, cancelled: cancelled)
        let received = ProcessInfo.processInfo.systemUptime
        guard let beforeFacts = payload["displayBefore"] as? [String: Any] else {
            throw IPhoneUseError("native_display_unavailable", "Missing display before screenshot")
        }
        let before = try NativeDisplay(beforeFacts)
        noteDisplay?(before)
        if startBefore != nil, payload["samplingEnded"] as? Bool == true {
            throw IPhoneUseError("capture_timeout", "Tap sampling ended before the screenshot request")
        }
        guard let facts = payload["display"] as? [String: Any] else {
            throw IPhoneUseError("native_display_unavailable", "Missing display after screenshot")
        }
        let display = try NativeDisplay(facts)
        noteDisplay?(display)
        try validateSelection(before, facts: beforeFacts)
        try validateSelection(display, facts: facts)
        guard before.geometry == display.geometry else {
            throw IPhoneUseError("capture_context_changed", "Display geometry changed during screenshot acquisition")
        }
        let decodeStarted = ProcessInfo.processInfo.systemUptime
        guard let encoded = payload["png"] as? String, let png = Data(base64Encoded: encoded),
            !png.isEmpty, png.count <= 32 * 1024 * 1024 else {
            throw IPhoneUseError("native_screenshot_invalid", "Native screenshot reply is invalid")
        }
        let decoded = ProcessInfo.processInfo.systemUptime
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw IPhoneUseError("native_screenshot_invalid", "Native image properties are unavailable")
        }
        guard (properties[kCGImagePropertyOrientation as String] as? Int ?? 1) == 1 else {
            throw IPhoneUseError("native_screenshot_geometry_conflict", "Native image orientation is not upright")
        }
        guard let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
            let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
            (1...8192).contains(width), (1...8192).contains(height),
            Double(width) == display.pixelWidth, Double(height) == display.pixelHeight else {
            throw IPhoneUseError("native_screenshot_geometry_conflict", "PNG dimensions disagree with the display")
        }
        var diagnostics = payload["screenshotTimings"] as? [String: Any] ?? [:]
        diagnostics["workerRoundTripMs"] = (received - started) * 1000
        diagnostics["base64DecodeMs"] = (decoded - decodeStarted) * 1000
        let validationTime = (decodeStarted - received) + (ProcessInfo.processInfo.systemUptime - decoded)
        diagnostics["hostMetadataValidationMs"] = validationTime * 1000
        return Frame(png: png, display: display,
            lease: payload["connectionLease"] as? [String: Any] ?? [:], diagnostics: diagnostics)
    }
    private func validateSelection(_ display: NativeDisplay, facts: [String: Any]) throws {
        let displays = facts["displays"] as? [[String: Any]] ?? []
        guard displays.filter({ $0["primary"] as? Bool == true }).count == 1,
            (displays.first(where: { $0["primary"] as? Bool == true })?["displayId"] as? NSNumber)?
                .uint64Value == display.id,
            displays.filter({ ($0["type"] as? [String: Any])?["integrated"] != nil }).count <= 1 else {
            throw IPhoneUseError(
                "native_screenshot_display_unsupported", "Native screenshot cannot select this active display")
        }
        // The verified Instruments path is upright. Other orientations keep devicectl's explicit contract.
        guard display.rotation == "rot0", display.nativeRotation == "rot0" else {
            throw IPhoneUseError(
                "native_screenshot_orientation_unsupported", "Use the display-selected screenshot for this orientation")
        }
    }
}
