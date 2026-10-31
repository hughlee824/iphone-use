import Foundation

// Only media recovery uses this policy. Never retry an input, an uncertain
// stream start, or a replacement whose owned resources were not released.
struct RunnerPreviewRecovery {
    private(set) var nextAttempt: Double?
    private var delay = 2.0

    static func permits(_ error: Error) -> Bool {
        let code: String
        if let failure = error as? ActionFailure {
            guard !failure.possiblyExecuted,
                let cleanup = failure.result?["recordingCleanup"] as? [String: Any],
                released(cleanup) else { return false }
            code = failure.code
        } else if let failure = error as? IPhoneUseError {
            code = failure.code
        } else { return false }
        return [
            "coredevice_timeout", "coredevice_initialization_timeout", "native_display_unavailable",
            "display_unavailable", "display_changed", "capture_unavailable", "preview_geometry_conflict",
            "preview_geometry_unavailable", "preview_validation_timeout", "native_media_unhealthy",
            "native_recording_format_unavailable"
        ].contains(code)
    }

    static func released(_ facts: [String: Any]) -> Bool {
        facts["mediaStopAcknowledged"] as? Bool == true
            && facts["tunnelReleaseAcknowledged"] as? Bool == true
    }

    mutating func schedule(now: Double) {
        nextAttempt = now + delay
        delay = min(30, delay * 2)
    }

    mutating func takeAttempt(now: Double) -> Bool {
        guard let nextAttempt, now >= nextAttempt else { return false }
        self.nextAttempt = nil
        return true
    }
}
