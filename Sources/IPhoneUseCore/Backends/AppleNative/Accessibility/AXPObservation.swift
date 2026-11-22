import Foundation
import IPhoneUseRunnerSupport

// Read-only AX augments screenshots, including responder checks across keyboard attachment.
enum AXPObservation {
    static func capture(
        device: String, generation: String, previous: CapturedObservation? = nil,
        read: @escaping (() -> Bool) throws -> [String: Any], screenshot: () throws -> CapturedObservation,
        checkCancellation: () throws -> Void
    ) throws -> CapturedObservation {
        try checkCancellation()
        let task = AXPParallelRead(read: read)
        defer { task.cancel(); _ = task.join() }
        let imageStarted = Date().timeIntervalSince1970
        let image = try screenshot()
        let imageFinished = Date().timeIntervalSince1970
        try checkCancellation()
        let reply = task.join()
        try checkCancellation()
        return try finish(image, reply: reply, identity: (device, generation),
            acquisition: ObservationAcquisition.parallel(
                screenshot: (imageStarted, imageFinished), accessibility: (reply.startedAt, reply.finishedAt)),
            previous: previous, checkCancellation: checkCancellation)
    }

    static func captureSelected(
        _ image: CapturedObservation, device: String, generation: String,
        read: () throws -> [String: Any], checkCancellation: () throws -> Void
    ) throws -> CapturedObservation {
        try checkCancellation()
        guard let start = image.metadata["captureStartedAt"] as? Double,
            let end = image.metadata["captureCompletedAt"] as? Double else {
            throw IPhoneUseError("invalid_action_frame", "Missing selected screenshot acquisition interval")
        }
        let started = Date().timeIntervalSince1970
        let payload = Result { try read() }
        let reply = AXPParallelRead.Reply(
            startedAt: started, finishedAt: Date().timeIntervalSince1970, payload: payload)
        try checkCancellation()
        let acquisition = ObservationAcquisition.host(strategy: "selected_frame_then_ax",
            screenshot: (start, end), accessibility: (reply.startedAt, reply.finishedAt))
        return try finish(image, reply: reply, identity: (device, generation),
            acquisition: acquisition, checkCancellation: checkCancellation)
    }

    private static func finish(
        _ image: CapturedObservation, reply: AXPParallelRead.Reply, identity: (device: String, generation: String),
        acquisition: [String: Any], previous: CapturedObservation? = nil, checkCancellation: () throws -> Void
    ) throws -> CapturedObservation {
        guard image.metadata["deviceID"] as? String == identity.device,
              image.metadata["sessionGeneration"] as? String == identity.generation else {
            throw IPhoneUseError("capture_context_changed", "Observation device or session changed during acquisition")
        }
        var metadata = image.metadata
        metadata.merge([
            "snapshotSource": "axp_native_snapshot_v1", "axScope": "application", "axAtomic": false,
            "axElementActions": false, "axCoverage": "unknown", "sourceTruncated": false,
            "observationAcquisition": acquisition
        ]) { _, new in new }
        let nodes = associate(reply, image: image, device: identity.device, metadata: &metadata)
        try updateReadiness(previous, image: image, metadata: &metadata)
        try checkCancellation()
        return CapturedObservation(nodes: nodes, metadata: metadata, screenshot: image.screenshot,
            validatedPixels: image.validatedPixels)
    }

    private static func associate(
        _ reply: AXPParallelRead.Reply, image: CapturedObservation, device: String,
        metadata: inout [String: Any]
    ) -> [AXNode] {
        do {
            let snapshot = try AXPSnapshot.decode(reply.payload.get(), device: device)
            guard matches(snapshot, image, interval: reply) else {
                throw IPhoneUseError(
                    "axp_context_changed", "AX display or acquisition time conflicts with this screenshot")
            }
            metadata["axStatus"] = "available"
            metadata["sourceBundleId"] = snapshot.bundle
            metadata["snapshotStartedAt"] = snapshot.started
            metadata["snapshotFinishedAt"] = snapshot.finished
            metadata["axCleanup"] = snapshot.cleanup
            metadata["axCollection"] = snapshot.collection
            if (snapshot.collection["omittedSupplementalCandidateCount"] as? Int ?? 0) > 0 {
                metadata["sourceTruncated"] = true
            }
            metadata["axApplicationBundleId"] = snapshot.bundle // Not verified foreground identity.
            metadata.removeValue(forKey: "axError")
            metadata.removeValue(forKey: "axErrorCode")
            return snapshot.nodes
        } catch {
            metadata["axStatus"] = "unavailable"
            metadata["axError"] = (error as? IPhoneUseError)?.description ?? "AXP read failed; use the screenshot"
            metadata["axErrorCode"] = (error as? IPhoneUseError)?.code ?? "axp_unavailable"
            return []
        }
    }

    private static func updateReadiness(
        _ previous: CapturedObservation?, image: CapturedObservation, metadata: inout [String: Any]
    ) throws {
        guard let previous, let stability = previous.metadata["postActionStability"] as? [String: Any] else { return }
        // Post-action sampling is separate from ordinary observe. Its earlier frame
        // must still match the single new image before carrying readiness forward.
        let comparison = try AXPScreenComparison(previous, image)
        var confirmed = stability
        confirmed["frameHash"] = image.metadata["frameHash"]
        confirmed["axScreenRevalidated"] = true
        metadata["postActionStability"] = comparison.equivalent ? confirmed : [
            "stable": false, "reason": "changed_during_ax_capture", "automaticReplayAllowed": false
        ]
    }

    private static func matches(
        _ snapshot: AXPSnapshot, _ capture: CapturedObservation, interval: AXPParallelRead.Reply
    ) -> Bool {
        guard let frame = capture.metadata["screenFrame"] as? [String: Any],
            AXPSnapshot.rect(frame) == snapshot.screen,
            capture.metadata["displayRotation"] as? String == "rot0",
            (capture.metadata["displayID"] as? NSNumber)?.uint64Value == snapshot.displayID,
            snapshot.displayUniqueID == nil
                || capture.metadata["displayUniqueID"] as? String == snapshot.displayUniqueID,
            snapshot.started >= interval.startedAt - 1, snapshot.finished <= interval.finishedAt + 1
        else { return false }
        return true
    }
}
