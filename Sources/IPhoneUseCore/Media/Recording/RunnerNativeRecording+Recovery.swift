import Foundation

extension RunnerNativeRecording {
    func close() -> [String: Any] {
        recovery = RunnerPreviewRecovery()
        closed = true; unlockCheck = nil
        preview?.close(); preview = nil
        var result = recording.close()
        releaseMedia()
        result["mediaCleanup"] = cleanup
        result["recordingCleanupAcknowledged"] =
            cleanup.isEmpty
            || (cleanup["mediaStopAcknowledged"] as? Bool == true
                && cleanup["tunnelReleaseAcknowledged"] as? Bool == true)
        return result
    }

    func canDeferPoll(_ error: Error, connection: RunnerRecordingConnection) -> Bool {
        validation == nil && !cancellation.isCancelled
            && NativePreviewPoll.canDefer(error, health: connection.source.health())
    }

    func canWaitForValidation(_ error: Error) -> Bool {
        !cancellation.isCancelled && validation?.canWait(
            error, healthy: connection?.source.health()["healthy"] as? Bool == true, now: now()) == true
    }

    func recoverPreview(_ error: Error) -> Bool {
        guard let preview, !closed, !cancellation.isCancelled, RunnerPreviewRecovery.permits(error) else {
            return false
        }
        validation = nil; unlockCheck = nil
        preview.suspend("Recovering preview: \(error)", transitioning: true)
        recording.endSegment(reason: "preview_media_recovery")
        releaseMedia()
        if let facts = (error as? ActionFailure)?.result?["recordingCleanup"] as? [String: Any] {
            cleanup = facts
        }
        guard failure == nil, RunnerPreviewRecovery.released(cleanup) else { return false }
        recovery.schedule(now: now())
        NativePreviewEvents.append(to: previewEventsURL, event: "recovery_scheduled",
            reason: String(describing: error), source: cleanup)
        return true
    }

    func resumePreview() -> Bool {
        guard recovery.takeAttempt(now: now()) else { return false }
        do {
            try cancellation.check()
            connection = try connect()
            validation = RunnerPreviewValidation(reason: "media_recovery", deadline: now() + 6)
            return try finishPreviewRefresh(connection!)
        } catch {
            if canWaitForValidation(error) { return true }
            if recoverPreview(error) { return true }
            failure = String(describing: error)
            if let facts = (error as? ActionFailure)?.result?["recordingCleanup"] as? [String: Any] {
                cleanup = facts
            }
            NativePreviewEvents.append(to: previewEventsURL, event: "recovery_failed",
                reason: failure!, source: cleanup)
            preview?.suspend(failure!); preview?.close(); preview = nil
            validation = nil
            releaseMedia()
            return true
        }
    }
}
