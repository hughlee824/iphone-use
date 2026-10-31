import Foundation

// The capture process owns media independently of any control session. This
// client holds no device transport and never starts Runner or prepares HID.
final class PreviewCaptureClient {
    let device: String
    let directory: URL
    private let recordingOwner: String
    private var recordingRequested = false
    private let events = DispatchQueue(label: "iphone-use.preview.decorations")

    init(device: String, recordingOwner: String = UUID().uuidString) throws {
        guard device.range(of: "^[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil else {
            throw IPhoneUseError("invalid_device_id", "Use the exact hardware UDID")
        }
        self.device = device; self.recordingOwner = recordingOwner
        directory = SessionPaths.defaultRoot.appendingPathComponent("preview-\(device)")
        try SessionPaths.secureDirectory(directory)
        guard directory.appendingPathComponent("ipc.sock").path.utf8.count < 104 else {
            throw IPhoneUseError("state_path_too_long", "Preview capture socket path is too long")
        }
    }

    private func ensureRunning() throws {
        if (try? call("ping")) != nil { return }
        let startup = try PreviewServiceClient.startupLock(directory: directory)
        defer { withExtendedLifetime(startup) {} }
        if (try? call("ping")) != nil { return }
        // A missing socket is not proof that an old capture has released media.
        do {
            let ownership = try DeviceLock(root: directory, device: "capture")
            withExtendedLifetime(ownership) {}
        }
        try launch()
    }

    private func launch() throws {
        let logURL = directory.appendingPathComponent("capture.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["_preview-capture", "--device", device]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = log; process.standardError = log
        try process.run()
        guard try PreviewServiceProcess.waitForStartup(process, ready: { (try? self.call("ping")) != nil }) else {
            throw IPhoneUseError("preview_capture_unavailable", "Cannot start independent capture; see \(logURL.path)")
        }
    }

    func call(_ operation: String, fields: [String: Any] = [:], timeout: Double = 3) throws -> [String: Any] {
        var request = fields
        request["id"] = UUID().uuidString; request["version"] = 1
        request["op"] = operation; request["owner"] = recordingOwner
        let response = try JSONTransport.exchange(
            endpoint: .unix(path: directory.appendingPathComponent("ipc.sock").path),
            request: request, timeout: timeout)
        guard response["ok"] as? Bool == true else {
            let error = response["error"] as? [String: Any] ?? [:]
            if let possible = response["possiblyExecuted"] as? Bool {
                throw ActionFailure(code: error["code"] as? String ?? "preview_capture_failed",
                                    description: error["message"] as? String ?? "Capture failed",
                                    possiblyExecuted: possible, requiresObservation: true,
                                    result: response["result"] as? [String: Any])
            }
            throw IPhoneUseError(error["code"] as? String ?? "preview_capture_failed",
                                 error["message"] as? String ?? "Capture rejected request")
        }
        return response["result"] as? [String: Any] ?? [:]
    }

    func startPreview(options: NativePreviewOptions) throws -> [String: Any] {
        try ensureRunning()
        return try call("preview-start", fields: ["port": Int(options.port), "portExplicit": options.explicitPort],
                        timeout: 60)
    }
    func stopPreview() throws -> [String: Any] { try call("preview-stop", timeout: 60) }
    func showPreviewGesture(_ gesture: NativePreviewGesture) {
        // Optional visual receipt. A viewer failure can never delay/fail input.
        events.async { _ = try? self.call("gesture", fields: gesture.facts, timeout: 0.5) }
    }
    var previewStatus: [String: Any] {
        (try? call("status"))?["preview"] as? [String: Any] ?? ["state": "unavailable"]
    }
    func status() -> [String: Any] {
        (try? call("status"))?["recording"] as? [String: Any] ?? ["state": "idle"]
    }
    func start(duration: Double) throws -> [String: Any] {
        try ensureRunning()
        recordingRequested = true
        return try call("record-start", fields: ["duration": duration], timeout: 60)
    }
    func stop(id: String) throws -> [String: Any] {
        try call("record-stop", fields: ["recordingID": id], timeout: 60)
    }
    // Disconnecting control releases only its recording. Preview has its own
    // explicit stop and remains available across control failures/idle expiry.
    func close() -> [String: Any] {
        guard recordingRequested else { return ["recordingCleanupAcknowledged": true] }
        do { return try call("release-recording", timeout: 60) } catch {
            return ["recordingCleanupAcknowledged": false, "error": String(describing: error)]
        }
    }
}

public func independentPreview(device: String, stop: Bool, port: Int?) throws -> [String: Any] {
    let client = try PreviewCaptureClient(device: device)
    let options = try NativePreviewOptions(request: PreviewConfiguration().startFields(port: port))
    return ["ok": true, "result": try stop ? client.stopPreview() : client.startPreview(options: options)]
}
