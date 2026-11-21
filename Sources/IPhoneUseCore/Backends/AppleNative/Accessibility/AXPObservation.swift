import Foundation
import IPhoneUseRunnerSupport

// AXP augments observations only; input preflight remains screenshot-only.
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
        guard image.metadata["deviceID"] as? String == device,
              image.metadata["sessionGeneration"] as? String == generation else {
            throw IPhoneUseError("capture_context_changed", "Observation device or session changed during acquisition")
        }
        var metadata = image.metadata
        metadata.merge([
            "snapshotSource": "axp_native_snapshot_v1", "axScope": "application", "axAtomic": false,
            "axElementActions": false, "axCoverage": "unknown", "sourceTruncated": false,
            "observationAcquisition": ObservationAcquisition.parallel(
                screenshot: (imageStarted, imageFinished), accessibility: (reply.startedAt, reply.finishedAt))
        ]) { _, new in new }
        let nodes = associate(reply, image: image, device: device, metadata: &metadata)
        try updateReadiness(previous, image: image, metadata: &metadata)
        try checkCancellation()
        return CapturedObservation(nodes: nodes, metadata: metadata, screenshot: image.screenshot)
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
