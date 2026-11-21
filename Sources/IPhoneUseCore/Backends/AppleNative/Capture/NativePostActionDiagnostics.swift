import Foundation

// Opt-in private evidence. Buffer existing captures only; never capture, wait, retry,
// or write files between samples. Export failures cannot change execution facts.
final class NativePostActionDiagnostics {
    static let environmentKey = "IPHONE_USE_POST_ACTION_DIAGNOSTICS_DIR"
    let directory: URL
    let started = ProcessInfo.processInfo.systemUptime
    var stability: Any?
    private let maximumBytes: Int
    private let maximumFrames: Int
    private var frames: [(String, Data)] = []
    private var samples: [[String: Any]] = []
    private var bytes = 0
    private var dropped = 0

    init(root: URL, maximumBytes: Int = 64 * 1024 * 1024, maximumFrames: Int = 32) {
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.maximumBytes = maximumBytes
        self.maximumFrames = maximumFrames
    }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NativePostActionDiagnostics? {
        guard let path = environment[environmentKey], path.hasPrefix("/") else { return nil }
        return NativePostActionDiagnostics(root: URL(fileURLWithPath: path, isDirectory: true))
    }

    func record(_ frame: CapturedObservation, phase: String, started: TimeInterval) {
        let finished = ProcessInfo.processInfo.systemUptime
        let name = String(format: "%03d-%@.png", samples.count + 1, phase)
        let retained = frames.count < maximumFrames && frame.screenshot.count <= maximumBytes - bytes
        if retained {
            frames.append((name, frame.screenshot))
            bytes += frame.screenshot.count
        } else { dropped += 1 }
        // Keep diagnostics bounded even if a caller produces more samples than expected.
        guard samples.count < 128 else { return }
        samples.append([
            "phase": phase, "startedUptime": started, "finishedUptime": finished,
            "elapsedMs": (finished - started) * 1000,
            "screenshot": retained ? name : NSNull(), "metadata": frame.metadata
        ])
    }

    func record(_ error: Error, started: TimeInterval, phase: String = "stability") {
        guard samples.count < 128 else { return }
        samples.append([
            "phase": phase, "startedUptime": started,
            "finishedUptime": ProcessInfo.processInfo.systemUptime,
            "errorCode": (error as? IPhoneUseError)?.code ?? "capture_failed",
            "diagnostics": (error as? IPhoneUseError)?.diagnostics ?? [:]
        ])
    }

    func complete(_ frame: CapturedObservation) -> CapturedObservation {
        var metadata = frame.metadata
        metadata["postActionDiagnostics"] = flush(outcome: "captured", acquisition: metadata["observationAcquisition"])
        return CapturedObservation(nodes: frame.nodes, metadata: metadata, screenshot: frame.screenshot,
            validatedPixels: frame.validatedPixels)
    }

    func fail(_ error: Error) {
        _ = flush(outcome: "failed", error: (error as? IPhoneUseError)?.code ?? "capture_failed")
    }

    private func flush(outcome: String, error: String? = nil, acquisition: Any? = nil) -> [String: Any] {
        let captureFinished = ProcessInfo.processInfo.systemUptime
        var result: [String: Any] = [
            "directory": directory.path, "retainedFrames": frames.count, "droppedFrames": dropped,
            "captureFinishedUptime": captureFinished, "automaticReplayAllowed": false
        ]
        do {
            try SessionPaths.secureDirectory(directory)
            for (name, data) in frames { try data.write(to: directory.appendingPathComponent(name), options: .atomic) }
            let manifest: [String: Any] = [
                "version": 1, "startedUptime": started, "captureFinishedUptime": captureFinished,
                "outcome": outcome, "errorCode": error as Any? ?? NSNull(),
                "finalAcquisition": acquisition ?? NSNull(), "stabilityBeforeAX": stability ?? NSNull(),
                "samples": samples,
                "retainedFrames": frames.count, "droppedFrames": dropped,
                "timingMeaning": "Host acquisition intervals, not device exposure or input acknowledgement",
                "exportStartedUptime": captureFinished
            ]
            try jsonData(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
            result["exported"] = true
        } catch {
            result["exported"] = false
            result["error"] = String(describing: error)
        }
        result["exportElapsedMs"] = (ProcessInfo.processInfo.systemUptime - captureFinished) * 1000
        return result
    }
}
