import Foundation
import AppleNativeBridge

// Calls are serialized on SessionHost's work queue. The shared recording sink
// owns its timer/packet queue; signal cancellation only flips a thread-safe flag.
final class RunnerNativeRecording {
    private let recording: NativeStreamRecording
    private let cancellation: NativeCancellation
    private let connect: () throws -> RunnerRecordingConnection
    private let previewGeometry: ((NativeDisplay) throws -> RunnerPreviewGeometry)?
    private let previewDevice: NativePreviewDevice
    private var connection: RunnerRecordingConnection?
    private var failure: String?
    private var validation: RunnerPreviewValidation?
    private var unlockCheck: (() throws -> Bool)?
    private let now: () -> Double
    private var cleanup: [String: Any] = [:]
    private var cleanupByRecordingID: [String: [String: Any]] = [:]
    private var currentRecordingID: String?
    private var closed = false
    var hasConsumers: Bool { preview != nil || recording.isActive }
    private var preview: NativePreview?
    var previewOwner: PreviewOwner?
    var connectionStatus: () -> [String: Any]? = { nil }
    private var independentOrientationConflicts = 0
    private let previewContinuity = NativePreviewContinuity()
    private let previewEventsURL: URL
    var previewStatus: [String: Any] {
        var result =
            preview?.status() ?? [
                "state": failure == nil ? "stopped" : "failed", "error": failure as Any? ?? NSNull()
            ]
        result["independentOrientationConflicts"] = independentOrientationConflicts
        return result
    }

    init(
        root: URL, cancellation: NativeCancellation,
        previewDevice: NativePreviewDevice = .unknown,
        previewGeometry: ((NativeDisplay) throws -> RunnerPreviewGeometry)? = nil,
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        connect: @escaping () throws -> RunnerRecordingConnection
    ) {
        previewEventsURL = root.deletingLastPathComponent().appendingPathComponent("preview-events.jsonl")
        recording = NativeStreamRecording(root: root); self.cancellation = cancellation
        self.connect = connect; self.now = now
        self.previewGeometry = previewGeometry
        self.previewDevice = previewDevice
    }
    convenience init(
        device: String, root: URL, cancellation: NativeCancellation,
        previewDevice: NativePreviewDevice,
        previewGeometry: @escaping (NativeDisplay) throws -> RunnerPreviewGeometry
    ) {
        self.init(
            root: root, cancellation: cancellation, previewDevice: previewDevice,
            previewGeometry: previewGeometry,
            connect: { try RunnerMediaConnection.open(device: device, cancellation: cancellation) })
    }

    func start(duration: Double) throws -> [String: Any] {
        _ = try NativeRecordingOptions.duration(["duration": duration])
        try requireReadyToRecord()
        // Recording readiness must not tear down an independently running
        // preview (in particular when the screen is locked).
        if preview != nil { try connection?.verifyDisplay() }
        if preview == nil { releaseMedia() }
        guard failure == nil else { throw IPhoneUseError("recording_reconnect_required", failure!) }
        currentRecordingID = nil
        do {
            let media = try connection ?? connect(); connection = media
            if try media.synchronizeRecordingOrientation() {
                // An explicit recording needs a verified fixed transform even
                // when the read-only viewer can follow stale-metadata rotations.
                try validateRefreshedPreview(media)
                if preview != nil { try attachPreview() }
            }
            try media.verifyDisplay()
            try cancellation.check()
            let result = try recording.start(
                duration: duration, receiver: media.source, mediaID: media.sessionID,
                rotation: media.rotation,
                snapshots: preview == nil ? nil : media.previewReceiver?.snapshots)
            currentRecordingID = result["recordingID"] as? String
            return result
        } catch {
            // A rebound preview can decode before RTCP has confirmed the
            // recording clock. This pre-writer rejection must not tear down a
            // healthy shared preview or poison its next explicit recording.
            if (error as? IPhoneUseError)?.code == "native_recording_format_unavailable",
                preview != nil, !recording.isActive,
                connection?.source.health()["healthy"] as? Bool == true {
                throw error
            }
            failure = String(describing: error)
            preview?.suspend(failure!); preview?.close(); preview = nil
            releaseMedia()
            if let facts = (error as? ActionFailure)?.result?["recordingCleanup"] as? [String: Any] {
                cleanup = facts
            }
            throw error
        }
    }

    private func requireReadyToRecord() throws {
        try cancellation.check()
        guard !closed, failure == nil else {
            throw IPhoneUseError("recording_reconnect_required", failure ?? "Recorder closed")
        }
        guard unlockCheck == nil else {
            throw IPhoneUseError("device_locked", "Wait for preview to resume after unlocking before recording")
        }
        guard validation == nil else {
            throw IPhoneUseError("preview_validation_pending", "Wait for the display transition before recording")
        }
        guard !recording.isActive else {
            throw IPhoneUseError("recording_busy", "A recording is already active")
        }
    }

    func stop(id: String) throws -> [String: Any] {
        var result = try recording.stop(id: id)
        // An old ID is idempotent and must not close a newer active stream.
        if !recording.isActive, preview == nil { releaseMedia() }
        let ownedCleanup = cleanupByRecordingID[id] ?? [:]
        result["mediaCleanup"] = ownedCleanup
        result["mediaRetainedForPreview"] = preview != nil && connection != nil
        if !ownedCleanup.isEmpty,
            ownedCleanup["mediaStopAcknowledged"] as? Bool != true
                || ownedCleanup["tunnelReleaseAcknowledged"] as? Bool != true {
            throw ActionFailure(
                code: "recording_cleanup_unconfirmed",
                description: "File stopped, but owned media cleanup was not confirmed",
                possiblyExecuted: true, requiresObservation: true, result: result)
        }
        return result
    }

    func checkDisplay() {
        if recording.isActive, let connection {
            do { try connection.verifyDisplay() } catch {
                let reason = (error as? IPhoneUseError)?.code ?? "display_unavailable"
                recording.endSegment(reason: reason)
            }
        }
        if preview != nil { _ = previewTick(); return }
        if !recording.isActive, preview == nil { releaseMedia() }
    }

    func status() -> [String: Any] {
        checkDisplay()
        var result = recording.status()
        result["mediaConnectionOpen"] = connection != nil
        result["mediaCleanup"] = cleanup
        if let failure { result["connectionError"] = failure; result["reconnectRequired"] = true }
        return result
    }

    private func releaseMedia() {
        guard let connection else { return }
        cleanup = connection.close(); self.connection = nil
        if let currentRecordingID { cleanupByRecordingID[currentRecordingID] = cleanup }
        if cleanup["mediaStopAcknowledged"] as? Bool != true
            || cleanup["tunnelReleaseAcknowledged"] as? Bool != true {
            failure = "Owned recording media cleanup was not confirmed; reconnect explicitly"
        }
    }

    func showPreviewGesture(_ gesture: NativePreviewGesture) { preview?.showGesture(gesture) }
    var previewGestureRotation: String? { preview?.gestureRotation }
    func reservePreview(options: NativePreviewOptions) throws -> [String: Any] {
        if let preview { return try preview.status(for: options) }
        let preview = try NativePreview(
            port: options.port, device: connection?.previewDevice ?? previewDevice,
            connectionStatus: connectionStatus, owner: previewOwner)
        self.preview = preview
        return preview.status()
    }
    func startPreview(options: NativePreviewOptions = NativePreviewOptions(), duringStartup: Bool = false)
        throws
        -> [String: Any] {
        try cancellation.check()
        guard !closed, failure == nil else {
            throw IPhoneUseError("preview_unavailable", failure ?? "Connection closed")
        }
        if let preview, connection != nil || unlockCheck != nil { return try preview.status(for: options) }
        // Reserve the HTTP port before touching media. A collision must not
        // poison this owner or interrupt an existing recording.
        _ = try reservePreview(options: options)
        do {
            if connection == nil { connection = try connect() }
            try attachPreview()
            return preview!.status()
        } catch {
            // Video readiness and Runner authorization are independent. Keep
            // the startup page and its diagnostics when media is unavailable.
            if duringStartup {
                self.preview?.suspend(String(describing: error))
            } else {
                self.preview?.close(); self.preview = nil
            }
            if !recording.isActive { releaseMedia() }
            if let facts = (error as? ActionFailure)?.result?["recordingCleanup"] as? [String: Any] {
                cleanup = facts
            }
            failure = String(describing: error)
            if duringStartup {
                try cancellation.check()
                return preview!.status()
            }
            throw error
        }
    }
    private func attachPreview() throws {
        guard let receiver = connection?.previewReceiver, let display = connection?.previewDisplay else {
            throw IPhoneUseError("preview_unavailable", "No decoded media source")
        }
        preview?.attach(receiver, display: display, device: connection?.previewDevice)
    }
    func stopPreview() throws -> [String: Any] {
        validation = nil; unlockCheck = nil
        preview?.close(); preview = nil
        if !recording.isActive { releaseMedia() }
        if cleanup.isEmpty || (cleanup["mediaStopAcknowledged"] as? Bool == true
            && cleanup["tunnelReleaseAcknowledged"] as? Bool == true) { failure = nil }
        guard failure == nil else { throw IPhoneUseError("preview_cleanup_failed", failure!) }
        return ["state": "stopped", "mediaRetainedForRecording": recording.isActive]
    }

    func close() -> [String: Any] {
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
}

extension RunnerNativeRecording {
    func previewTick() -> Bool {
        guard let preview, !closed, !cancellation.isCancelled else { return false }
        if unlockCheck != nil { return resumeAfterUnlock(preview) }
        guard let connection else { return false }
        return tickPreview(preview, connection: connection)
    }
    private func tickPreview(_ preview: NativePreview, connection: RunnerRecordingConnection) -> Bool {
        var checkingDisplay = true
        do {
            if validation != nil { return try finishPreviewRefresh(connection) }
            let recovery = previewContinuity.needsRecovery(
                connection.previewReceiver?.snapshots?.status() ?? [:])
            var changed = recovery
            var reason = recovery ? "decoder_continuity_lost" : "none"
            if !changed {
                changed = try connection.previewNeedsRefresh()
                if changed { reason = connection.previewRefreshReason }
            }
            if !changed, let previewGeometry, let display = connection.previewDisplay,
                NativePreviewGeometry.continuousDisplay(
                    frame: connection.previewReceiver?.snapshots?.previewFrame(includeReducedResolution: true),
                    bound: display, current: display) == nil {
                // XCTest and video can sample opposite sides of a rotation.
                // Keep the independent fallback for frames without verified tags.
                changed = try previewGeometry(display).conflicts(with: display)
                if changed { independentOrientationConflicts += 1; reason = "xctest_geometry_conflict" }
            }
            checkingDisplay = false
            if changed {
                previewEvent("refresh_started", reason: reason, connection: connection)
                preview.suspend(recovery ? "Recovering video continuity" : "Synchronizing display", transitioning: true)
                recording.endSegment(reason: recovery ? "media_discontinuity" : "display_changed")
                try connection.refreshPreview()
                validation = RunnerPreviewValidation(reason: reason, deadline: now() + 6)
                return try finishPreviewRefresh(connection)
            }
            try attachPreview()
            return preview.takeRotationChange() || changed
        } catch {
            if pauseForUnlock(error, connection: connection, preview: preview) { return true }
            if !cancellation.isCancelled, let validation,
                validation.canWait(error, healthy: connection.source.health()["healthy"] as? Bool == true, now: now()) {
                previewEvent("validation_deferred", reason: String(describing: error), connection: connection)
                return true
            }
            if checkingDisplay, validation == nil, !cancellation.isCancelled,
                NativePreviewPoll.canDefer(error, health: connection.source.health()) {
                previewEvent("poll_deferred", reason: String(describing: error), connection: connection)
                return false // A status timeout is not evidence that the independent video stopped.
            }
            validation = nil
            failure = failure ?? String(describing: error)
            // A failed rebind may already have cleared its media session ID.
            // Retain the error without reading identities that require a live stream.
            NativePreviewEvents.append(
                to: previewEventsURL, event: "preview_failed", reason: failure!, source: connection.source.health())
            preview.suspend(failure!); preview.close(); self.preview = nil
            recording.endSegment(reason: "preview_display_unavailable")
            releaseMedia()
            return true
        }
    }
    private func pauseForUnlock(
        _ error: Error, connection: RunnerRecordingConnection, preview: NativePreview
    ) -> Bool {
        guard !cancellation.isCancelled, (error as? IPhoneUseError)?.code == "device_locked" else { return false }
        validation = nil
        preview.suspend("Unlock the iPhone to resume preview")
        recording.endSegment(reason: "device_locked")
        releaseMedia()
        guard failure == nil else { return false }
        unlockCheck = { try connection.previewCanResumeAfterUnlock() }
        NativePreviewEvents.append(to: previewEventsURL, event: "waiting_for_unlock",
                                   reason: "device_locked", source: cleanup)
        return true
    }
    private func resumeAfterUnlock(_ preview: NativePreview) -> Bool {
        do {
            guard try unlockCheck?() == true else { return false }
            try cancellation.check()
            // Consume readiness before starting media: a lost start reply is
            // terminal, never retried by subsequent preview ticks.
            unlockCheck = nil
            connection = try connect()
            validation = RunnerPreviewValidation(reason: "device_unlocked", deadline: now() + 6)
            preview.suspend("Synchronizing unlocked display", transitioning: true)
            return true
        } catch {
            unlockCheck = nil; validation = nil
            failure = String(describing: error)
            NativePreviewEvents.append(to: previewEventsURL, event: "unlock_resume_failed",
                                       reason: failure!, source: [:])
            preview.suspend(failure!); preview.close(); self.preview = nil
            releaseMedia()
            if let facts = (error as? ActionFailure)?.result?["recordingCleanup"] as? [String: Any] {
                cleanup = facts
            }
            return true
        }
    }
    private func finishPreviewRefresh(_ connection: RunnerRecordingConnection) throws -> Bool {
        try cancellation.check()
        guard let pending = validation, now() < pending.deadline else {
            throw IPhoneUseError("preview_validation_timeout", "Display did not settle after media rebind")
        }
        guard connection.source.health()["healthy"] as? Bool == true else {
            throw IPhoneUseError("native_media_unhealthy", "Replacement preview media connection lost")
        }
        validation?.attempts += 1
        try connection.preparePreviewValidation()
        try validateRefreshedPreview(connection)
        try cancellation.check()
        try attachPreview()
        validation = nil
        previewEvent("refresh_completed", reason: pending.reason, connection: connection)
        return true
    }
    private func validateRefreshedPreview(_ connection: RunnerRecordingConnection) throws {
        if let previewGeometry, let display = connection.previewDisplay {
            let geometry = try previewGeometry(display)
            guard !geometry.conflicts(with: display) else {
                throw IPhoneUseError(
                    "preview_geometry_conflict",
                    """
                    Display still conflicts with XCTest after owned-media resynchronization \
                    (XCTest \(geometry.width)x\(geometry.height), EXIF \(geometry.orientation); \
                    display \(display.pixelWidth)x\(display.pixelHeight), \(display.rotation))
                    """)
            }
        }
    }

    private func previewEvent(_ event: String, reason: String, connection: RunnerRecordingConnection) {
        var facts = connection.source.health()
        facts["mediaSessionID"] = connection.sessionID; facts["displayRotation"] = connection.rotation
        NativePreviewEvents.append(to: previewEventsURL, event: event, reason: reason, source: facts)
    }
}
