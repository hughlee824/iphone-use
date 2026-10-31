import Foundation
import Network
import Darwin

final class XCTestBackend: SessionBackend {
    private let config: HostConfiguration
    let paths: SessionPaths
    var runner: StandaloneRunner?
    private var transport: RunnerUSBTransport?
    private var deviceLock: SessionDeviceLock?
    private let token = UUID().uuidString + UUID().uuidString
    var identity: String?
    private var runnerPID: Int?
    var deviceUDID: String?
    private let recordingCancellation = NativeCancellation()
    var recording: PreviewCaptureClient?
    private var recordingPlatformSupported = false
    private let authorization: RunnerAuthorization

    init(config: HostConfiguration, paths: SessionPaths) {
        self.config = config
        self.paths = paths
        authorization = RunnerAuthorization(directory: paths.directory)
    }

    func start() throws -> [String: Any] {
        do { return try startRunner() } catch { authorization.failed(String(describing: error)); throw error }
    }

    private func startRunner() throws -> [String: Any] {
        let details = try deviceInfo("details")
        guard let hardware = details["hardwareProperties"] as? [String: Any],
            let udid = hardware["udid"] as? String
        else {
            throw IPhoneUseError("coredevice_unavailable", "CoreDevice did not identify the selected iPhone")
        }
        deviceLock = try SessionDeviceLock(root: paths.directory.deletingLastPathComponent(), device: udid)
        deviceUDID = udid
        let lockState = try deviceInfo("lockState")
        if lockState["passcodeRequired"] as? Bool == true {
            throw IPhoneUseError("device_locked", "Unlock the iPhone and connect again")
        }
        recordingPlatformSupported =
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27
            && ((details["deviceProperties"] as? [String: Any])?["osVersionNumber"] as? String)?.hasPrefix(
                "27.")
                == true
        recording = try PreviewCaptureClient(device: udid)
        let transport = RunnerUSBTransport(device: udid)
        _ = try transport.requireUSB(deadline: ProcessInfo.processInfo.systemUptime + 5)
        self.transport = transport
        let bundle = try StandaloneRunner.bundleID(manifest: URL(fileURLWithPath: config.xctestrun))
        let runner = StandaloneRunner { arguments, tail, environment in
            try CoreDevice.read(
                arguments + ["--device", udid], trailingArguments: tail, timeout: 10,
                launchEnvironment: environment)
        }
        self.runner = runner
        try startConfiguredPreview()
        authorization.start(device: udid)
        try recordingCancellation.check()
        let launched = try runner.start(bundle: bundle, token: token)
        authorization.bind(runnerPID: launched.pid)
        try saveJSON(
            [
                "device": udid, "bundleId": bundle, "runnerPid": launched.pid,
                "executable": launched.executable.absoluteString, "transport": "usb-loopback",
                "launch": "standalone-background", "installationPerformed": false
            ],
            to: paths.directory.appendingPathComponent("backend.json"))
        return try awaitRunner(runner, launched: launched)
    }

    func startConfiguredPreview(start: ((NativePreviewOptions) throws -> [String: Any])? = nil) throws {
        do {
            guard let port = config.startupPreviewPort else { return }
            let options = NativePreviewOptions(
                port: try PreviewConfiguration.validate(port: port), explicitPort: true)
            let preview = try start?(options) ?? recording?.startPreview(options: options)
            if let url = preview?["url"] as? String { authorization.setPreviewURL(url) }
        } catch {
            // Optional viewer failure never prevents control startup. Do not
            // replay media startup or hide control cancellation.
            try recordingCancellation.check()
            authorization.setPreviewError(String(describing: error))
        }
    }

    private func awaitRunner(_ runner: StandaloneRunner, launched: NativeAppProcess) throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        var nextProcessCheck = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime < deadline {
            try recordingCancellation.check()
            // Only startup health checks retry; launching and UI input never do.
            if let response = try? request("ping", timeout: 1), response["ok"] as? Bool == true,
                let result = response["result"] as? [String: Any] {
                guard let sessionID = response["sessionId"] as? String, UUID(uuidString: sessionID) != nil,
                    response["runnerPid"] as? Int == launched.pid
                else {
                    throw IPhoneUseError(
                        "invalid_runner_identity", "USB peer did not match the launched Runner")
                }
                identity = sessionID
                runnerPID = launched.pid
                try Self.validateCapabilities(result)
                guard result["applicationStateTimeoutSupported"] as? Bool == true else {
                    throw IPhoneUseError(
                        "unsupported_xctest_runtime",
                        "This XCTest runtime cannot bound application-state waits")
                }
                authorization.ready()
                return metadata()
            }
            if ProcessInfo.processInfo.systemUptime >= nextProcessCheck {
                guard try runner.isRunning() else {
                    throw RunnerStartupDiagnostics.failure(
                        processExited: true, authorization: authorization.snapshot())
                }
                nextProcessCheck = ProcessInfo.processInfo.systemUptime + 3
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw RunnerStartupDiagnostics.failure(processExited: false, authorization: authorization.snapshot())
    }

    private func deviceInfo(_ kind: String, timeout: Int = 20) throws -> [String: Any] {
        try CoreDevice.read(
            ["device", "info", kind, "--device", config.device],
            savingTo: paths.directory.appendingPathComponent("device-\(kind).json"), timeout: timeout)
    }

    private func metadata() -> [String: Any] {
        [
            "runnerSession": identity ?? "", "runnerPid": runnerPID ?? 0,
            "launch": "standalone-background", "transport": "usb-loopback", "installationPerformed": false
        ]
    }

    func request(
        _ operation: String, fields: [String: Any] = [:], timeout: TimeInterval = 45,
        expectedDisplay: NativeDisplay? = nil,
        onInputStarted: (() -> Void)? = nil
    ) throws -> [String: Any] {
        guard let transport else { throw IPhoneUseError("backend_unavailable", "Runner is not connected") }
        var request = fields
        if !["ping", "shutdown"].contains(operation) {
            let display = try NativeDisplay(deviceInfo("displays", timeout: expectedDisplay == nil ? 20 : 3))
            try Self.validatePreviewDisplay(display, expected: expectedDisplay)
            request["displayID"] = display.id
            request["displayContext"] = try jsonObject(JSONEncoder().encode(display.context))
            if operation == "act",
                (fields["target"] as? [String: Any])?["displayID"] as? UInt64 != display.id {
                throw IPhoneUseError("screen_context_changed", "Active display changed; observe before choosing input")
            }
        }
        request["id"] = UUID().uuidString
        request["token"] = token
        request["op"] = operation
        if onInputStarted != nil { request["inputProgress"] = true }
        let response = try transport.exchange(
            request, timeout: timeout,
            onProgress: onInputStarted.map { callback in
                { [identity] progress in
                    guard progress["sessionId"] as? String == identity else {
                        throw IPhoneUseError(
                            "runner_session_changed", "Runner session changed during input dispatch")
                    }
                    callback()
                }
            })
        if let identity, response["sessionId"] as? String != identity {
            throw TransportError(
                description: "Runner session changed; reconnect and observe", possiblySent: true)
        }
        if let expectedDisplay {
            try Self.validatePreviewDisplay(
                NativeDisplay(deviceInfo("displays", timeout: 3)), expected: expectedDisplay)
        }
        return response
    }

    func status() throws -> [String: Any] {
        let response = try request("ping", timeout: 3)
        guard response["ok"] as? Bool == true else {
            throw IPhoneUseError("runner_unavailable", "Runner health check failed")
        }
        var result = metadata()
        result["sequence"] = response["sequence"]
        let recordingStatus = recording?.status() ?? ["state": "idle"]
        result["recording"] = recordingStatus
        result["preview"] = recording?.previewStatus ?? ["state": "stopped"]
        result["connection"] = authorization.snapshot()
        result["recordingSupport"] = [
            "supported": recordingPlatformSupported, "method": "native_rtp", "source": "owned_native_rtp",
            "codec": "hevc",
            "connectionPolicy": "on_explicit_record_or_preview_start", "hidServiceOpened": false,
            "availability": !recordingPlatformSupported
                ? "unsupported_platform"
                : (recordingStatus["reconnectRequired"] as? Bool == true
                    ? "reconnect_required"
                    : (recordingStatus["mediaConnectionOpen"] as? Bool == true ? "prepared" : "not_checked"))
        ]
        return result
    }
    func cancelCurrent() { recordingCancellation.cancel() }

    func stop() -> [String: Any] {
        let monitorExited = authorization.stop()
        recordingCancellation.cancel()
        let recordingCleanup = recording?.close() ?? ["recordingCleanupAcknowledged": true]
        var acknowledged = false
        if identity != nil {
            acknowledged = (try? request("shutdown", timeout: 5)["ok"] as? Bool) == true
        }
        let cleanup = runner?.stop() ?? ["runnerProcessExited": true]
        transport = nil
        identity = nil
        runnerPID = nil
        deviceLock = nil
        return [
            "shutdownAcknowledged": acknowledged && cleanup["runnerProcessExited"] as? Bool == true
                && recordingCleanup["recordingCleanupAcknowledged"] as? Bool == true,
            "runnerShutdownAcknowledged": acknowledged, "recordingCleanup": recordingCleanup,
            "authorizationMonitorExited": monitorExited,
            "runnerProcessExited": cleanup["runnerProcessExited"] ?? false, "runnerCleanup": cleanup
        ]
    }
}
