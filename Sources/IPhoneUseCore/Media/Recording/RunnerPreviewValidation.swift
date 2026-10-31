import Foundation

// Only the read-only validation AFTER a confirmed successful rebind may wait.
// Never replay a media start/stop or use this policy for input or recording.
struct RunnerPreviewValidation {
    let reason: String
    let deadline: Double
    var attempts = 0

    func canWait(_ error: Error, healthy: Bool, now: Double) -> Bool {
        guard healthy, attempts < 3, now < deadline else { return false }
        if let transport = error as? TransportError { return transport.code == "runner_socket_timeout" }
        guard let error = error as? IPhoneUseError else { return false }
        return [
            "coredevice_timeout", "coredevice_initialization_timeout", "native_display_unavailable",
            "preview_geometry_conflict", "display_unavailable", "preview_geometry_unavailable"
        ].contains(error.code)
    }
}
