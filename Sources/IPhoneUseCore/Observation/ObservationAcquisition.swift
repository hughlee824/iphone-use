import Foundation

// Common observation envelope; a shared ID is not a shared device sampling instant.
enum ObservationAcquisition {
    static func parallel(screenshot: (Double, Double), accessibility: (Double, Double)) -> [String: Any] {
        ["strategy": "parallel_ax_screenshot", "atomic": false, "clock": "host_unix_seconds",
         "timeMeaning": "request_intervals_not_device_sample_instants",
         "screenshot": ["startedAt": screenshot.0, "finishedAt": screenshot.1],
         "ax": ["startedAt": accessibility.0, "finishedAt": accessibility.1],
         "intervalsOverlap": max(screenshot.0, accessibility.0) <= min(screenshot.1, accessibility.1)]
    }

    static func attachRunner(to metadata: inout [String: Any], source: [String: Any]) {
        for key in ["snapshotStartedAt", "snapshotFinishedAt", "screenshotCapturedAt"] {
            metadata[key] = source[key] as? Double ?? NSNull()
        }
        metadata["observationAcquisition"] = runner(metadata)
    }

    static func runner(_ metadata: [String: Any]) -> [String: Any] {
        ["strategy": "runner_serial", "atomic": false, "clock": "device_unix_seconds",
         "timeMeaning": "request_intervals_not_device_sample_instants",
         "screenshot": ["startedAt": NSNull(), "finishedAt": metadata["screenshotCapturedAt"] ?? NSNull()],
         "ax": ["startedAt": metadata["snapshotStartedAt"] ?? NSNull(),
                "finishedAt": metadata["snapshotFinishedAt"] ?? NSNull()]]
    }

    static func lines(_ metadata: [String: Any]) -> [String] {
        guard let acquisition = metadata["observationAcquisition"] as? [String: Any] else { return [] }
        let accessibility = acquisition["ax"] as? [String: Any] ?? [:]
        let image = acquisition["screenshot"] as? [String: Any] ?? [:]
        return [
            "observation_atomic=false acquisition=\(acquisition["strategy"] ?? "unknown") "
                + "timing_clock=\(acquisition["clock"] ?? "unknown"); "
                + "times are request bounds, not device sample instants",
            "ax_request_started=\(quoted(accessibility["startedAt"] ?? NSNull())) "
                + "ax_request_finished=\(quoted(accessibility["finishedAt"] ?? NSNull())) "
                + "screenshot_request_started=\(quoted(image["startedAt"] ?? NSNull())) "
                + "screenshot_request_finished=\(quoted(image["finishedAt"] ?? NSNull()))"
        ]
    }
}
