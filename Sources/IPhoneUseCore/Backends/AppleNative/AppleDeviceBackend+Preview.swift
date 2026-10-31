import Foundation
import CoreGraphics
import ImageIO
import AppleNativeBridge

extension AppleDeviceBackend {
    func showPreviewGesture(_ gesture: NativePreviewGesture) { independentMedia?.showPreviewGesture(gesture) }
    var previewGestureRotation: String? { nil }
    func startPreview(options: NativePreviewOptions = NativePreviewOptions()) throws -> [String: Any] {
        guard let independentMedia else {
            throw IPhoneUseError("backend_unavailable", "Device identity is unavailable")
        }
        return try independentMedia.startPreview(options: options)
    }
    func stopPreview() throws -> [String: Any] {
        try independentMedia?.stopPreview() ?? ["state": "stopped"]
    }
    func previewTick() -> Bool { false }
}
