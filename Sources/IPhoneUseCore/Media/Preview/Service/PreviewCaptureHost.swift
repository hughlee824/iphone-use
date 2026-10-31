import Foundation
import Darwin

// Serialized media lifecycle, outside SessionHost and its cancellation/idle
// deadlines. Only this process can acquire the per-device capture lock.
final class PreviewCaptureHost {
    let media: RunnerNativeRecording
    private var recordingOwners: [String: String] = [:]
    private var activeRecording: String?

    init(media: RunnerNativeRecording) { self.media = media }

    func result(_ request: [String: Any]) throws -> [String: Any] {
        guard request["version"] as? Int == 1 else {
            throw IPhoneUseError("invalid_request", "Unsupported capture protocol")
        }
        switch request["op"] as? String {
        case "ping": return ["independentPreview": true, "pid": Int(getpid())]
        case "status": return status(owner: request["owner"] as? String)
        case "preview-start": return try media.startPreview(options: NativePreviewOptions(request: request))
        case "preview-stop": return try media.stopPreview()
        case "gesture": return try decorate(request)
        case "record-start": return try startRecording(request)
        case "record-stop": return try stopRecording(request)
        case "release-recording": return try releaseRecording(owner: request["owner"] as? String)
        default: throw IPhoneUseError("invalid_request", "Unknown capture operation")
        }
    }

    private func status(owner: String?) -> [String: Any] {
        let recording = media.status()
        let visible = activeRecording.map { recordingOwners[$0] == owner } ?? false
        let selected: [String: Any] = visible ? recording : ["state": "idle"]
        return ["preview": media.previewStatus, "recording": selected]
    }
    private func decorate(_ request: [String: Any]) throws -> [String: Any] {
        guard let gesture = NativePreviewGesture(facts: request) else {
            throw IPhoneUseError("invalid_request", "Invalid visual receipt")
        }
        media.showPreviewGesture(gesture)
        return [:]
    }
    private func stopRecording(_ request: [String: Any]) throws -> [String: Any] {
        guard let identifier = request["recordingID"] as? String,
            let owner = request["owner"] as? String, recordingOwners[identifier] == owner else {
            throw IPhoneUseError("recording_not_owned", "This client does not own the recording")
        }
        return try media.stop(id: identifier)
    }
    private func releaseRecording(owner: String?) throws -> [String: Any] {
        if let identifier = activeRecording, recordingOwners[identifier] == owner {
            _ = try media.stop(id: identifier)
        }
        return ["recordingCleanupAcknowledged": true, "previewRetained": true]
    }

    private func startRecording(_ request: [String: Any]) throws -> [String: Any] {
        guard let owner = request["owner"] as? String, UUID(uuidString: owner) != nil else {
            throw IPhoneUseError("invalid_request", "Expected recording owner")
        }
        let result = try media.start(duration: NativeRecordingOptions.duration(request))
        if let identifier = result["recordingID"] as? String {
            activeRecording = identifier; recordingOwners[identifier] = owner
        }
        return result
    }

    func reply(_ request: [String: Any]) -> [String: Any] {
        do { return ["id": request["id"] ?? NSNull(), "ok": true, "result": try result(request)] } catch {
            if let failure = error as? ActionFailure {
                return ["id": request["id"] ?? NSNull(), "ok": false,
                        "error": ["code": failure.code, "message": failure.description],
                        "possiblyExecuted": failure.possiblyExecuted,
                        "result": failure.result ?? [:]]
            }
            return ["id": request["id"] ?? NSNull(), "ok": false,
                    "error": ["code": (error as? IPhoneUseError)?.code ?? "preview_capture_failed",
                              "message": String(describing: error)]]
        }
    }
}

public func runPreviewCapture(device: String) throws {
    umask(0o077)
    let directory = try PreviewCaptureClient(device: device).directory
    let ownership = try DeviceLock(root: directory, device: "capture")
    let cancellation = NativeCancellation()
    let media = RunnerNativeRecording(root: directory.appendingPathComponent("recordings"),
                                     cancellation: cancellation, connect: {
        try RunnerMediaConnection.open(device: device, cancellation: cancellation, previewOnly: true)
    })
    media.previewOwner = PreviewOwner(device: device)
    let host = PreviewCaptureHost(media: media)
    let queue = DispatchQueue(label: "iphone-use.preview.capture")
    let socket = directory.appendingPathComponent("ipc.sock").path
    try? FileManager.default.removeItem(atPath: socket)
    let server = try JSONServer(path: socket)
    let ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    var lastRequest = ProcessInfo.processInfo.systemUptime
    server.onFailure = { _ in ready.signal(); done.signal() }
    server.onRequest = { request, reply in queue.async {
        lastRequest = ProcessInfo.processInfo.systemUptime
        reply(host.reply(request)) {}
    } }
    server.start { ready.signal() }
    guard ready.wait(timeout: .now() + 4) == .success else {
        throw IPhoneUseError("preview_capture_unavailable", "Capture IPC did not start")
    }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 2, repeating: 2)
    timer.setEventHandler {
        media.checkDisplay()
        if !media.hasConsumers, ProcessInfo.processInfo.systemUptime - lastRequest > 600 { done.signal() }
    }
    timer.resume()
    let signalQueue = DispatchQueue(label: "iphone-use.preview.capture.signals")
    let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
        source.setEventHandler { cancellation.cancel(); done.signal() }
        source.resume(); return source
    }
    done.wait()
    timer.cancel(); signals.forEach { $0.cancel() }; server.stopAccepting()
    queue.sync { _ = media.close() }
    try? FileManager.default.removeItem(atPath: socket)
    withExtendedLifetime(ownership) {}
}
