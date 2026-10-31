import Foundation
import CoreGraphics
import ImageIO
import AppleNativeBridge

extension AppleDeviceBackend {
    func startRecording(duration: Double) throws -> [String: Any] {
        guard let independentMedia else {
            throw IPhoneUseError("backend_unavailable", "Device identity is unavailable")
        }
        return try independentMedia.start(duration: duration)
    }
    func stopRecording(id: String) throws -> [String: Any] {
        guard let independentMedia else {
            throw IPhoneUseError("backend_unavailable", "Device identity is unavailable")
        }
        return try independentMedia.stop(id: id)
    }
}
