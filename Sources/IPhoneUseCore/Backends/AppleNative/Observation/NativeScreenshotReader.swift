import Foundation
import ImageIO

final class NativeScreenshotReader {
    struct Frame {
        let png: Data
        let display: NativeDisplay
        let lease: [String: Any]
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
    func capture(cancelled: () -> Bool) throws -> Frame {
        let payload = try read?(cancelled) ?? worker.read(cancelled: cancelled)
        guard let encoded = payload["png"] as? String, let png = Data(base64Encoded: encoded),
            !png.isEmpty, png.count <= 32 * 1024 * 1024,
            let facts = payload["display"] as? [String: Any],
            let displays = facts["displays"] as? [[String: Any]] else {
            throw IPhoneUseError("native_screenshot_invalid", "Native screenshot or display reply is invalid")
        }
        let display = try NativeDisplay(facts)
        guard displays.filter({ $0["primary"] as? Bool == true }).count == 1,
            (displays.first(where: { $0["primary"] as? Bool == true })?["displayId"] as? NSNumber)?
                .uint64Value == display.id,
            displays.filter({ ($0["type"] as? [String: Any])?["integrated"] != nil }).count <= 1,
            display.backlightOn else {
            throw IPhoneUseError(
                "native_screenshot_display_unsupported", "Native screenshot cannot select this active display")
        }
        // The verified Instruments path is upright. Other orientations keep devicectl's explicit contract.
        guard display.rotation == "rot0", display.nativeRotation == "rot0" else {
            throw IPhoneUseError(
                "native_screenshot_orientation_unsupported", "Use the display-selected screenshot for this orientation")
        }
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
            (properties[kCGImagePropertyOrientation as String] as? Int ?? 1) == 1 else {
            throw IPhoneUseError("native_screenshot_invalid", "Native image orientation is not upright")
        }
        guard let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
            let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
            (1...8192).contains(width), (1...8192).contains(height),
            Double(width) == display.pixelWidth, Double(height) == display.pixelHeight else {
            throw IPhoneUseError("native_screenshot_geometry_conflict", "PNG dimensions disagree with the display")
        }
        return Frame(png: png, display: display, lease: payload["connectionLease"] as? [String: Any] ?? [:])
    }
}
