import Foundation
import Darwin

// Serial service requests; AX and screenshot have independent instances and may run in parallel.
// A timeout retires the entire process: semantic AX replies cannot safely be reassigned to a new request.
final class NativeObservationWorker {
    final class Connection {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let mailbox = ObservationWorkerOutput()
        let drained = DispatchGroup()
        let generation = UUID().uuidString
        var cleanup: [String: Any]?
    }
    let device: String
    let kind: String
    let executable: URL
    let arguments: [String]
    private let requestTimeout: TimeInterval
    private let transaction = NSLock()
    private var connection: Connection?
    private let revoked = NativeCancellation()
    private var cleanup: [String: Any] = ["connectionClosed": true, "tunnelClosed": true]

    init(device: String, kind: String, executable: URL = Bundle.main.executableURL!,
         arguments: [String] = ["_observation-worker"], requestTimeout: TimeInterval = 16) {
        precondition(requestTimeout.isFinite && requestTimeout > 0 && requestTimeout <= 16)
        self.device = device; self.kind = kind; self.executable = executable; self.arguments = arguments
        self.requestTimeout = requestTimeout
    }
    func prewarm(cancelled: () -> Bool = { false }) throws {
        transaction.lock(); defer { transaction.unlock() }
        do { _ = try open(deadline: uptime + 12, cancelled: cancelled) } catch { retire(); throw error }
    }
    func read(startBefore: TimeInterval? = nil, focusPoint: CGPoint? = nil,
              cancelled: () -> Bool) throws -> [String: Any] {
        transaction.lock(); defer { transaction.unlock() }
        let deadline = uptime + requestTimeout
        // Only read-only acquisitions are retried, on a NEW generation, within the original deadline.
        for attempt in 0..<2 {
            if let startBefore, uptime >= startBefore { throw samplingEnded }
            do {
                let current = try open(deadline: deadline, cancelled: cancelled)
                let identifier = UUID().uuidString
                if let startBefore, uptime >= startBefore { throw samplingEnded }
                var command: [String: Any] = ["op": "capture", "id": identifier, "generation": current.generation]
                if let focusPoint { command["focusPoint"] = ["x": focusPoint.x, "y": focusPoint.y] }
                command["screenshotStartDeadline"] = startBefore
                try send(command, to: current)
                let response = try wait(current, deadline: deadline, cancelled: cancelled)
                guard response["event"] as? String == "result", response["id"] as? String == identifier,
                    let payload = response["value"] as? [String: Any], payload["deviceID"] as? String == device,
                    connection === current, !revoked.isCancelled, !cancelled(), uptime < deadline else {
                    throw IPhoneUseError(
                        "observation_worker_stale", "Observation response no longer belongs to this request")
                }
                var result = payload
                result["connectionLease"] = [
                    "generation": current.generation, "requestID": identifier, "state": "current"
                ]
                return result
            } catch let error as IPhoneUseError where error.code == "capture_timeout" {
                throw error // An idle, healthy connection may outlive the sampling window.
            } catch {
                retire()
                if attempt == 1 || revoked.isCancelled || cancelled() || uptime >= deadline
                    || startBefore.map({ uptime >= $0 }) == true
                    || (error as? IPhoneUseError)?.code == "observation_service_failed" { throw error }
            }
        }
        throw IPhoneUseError("observation_worker_unavailable", "Observation connection unavailable")
    }
    func close() -> [String: Any] {
        revoked.cancel()
        transaction.lock(); defer { transaction.unlock() }
        retire()
        return cleanup
    }
    private var samplingEnded: IPhoneUseError {
        IPhoneUseError("capture_timeout", "Tap screenshot sampling has ended")
    }
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func open(deadline: TimeInterval, cancelled: () -> Bool) throws -> Connection {
        guard !revoked.isCancelled, !cancelled(), uptime < deadline else {
            throw IPhoneUseError("native_cancelled", "Observation session closed or expired")
        }
        if let connection, connection.process.isRunning { return connection }
        retire()
        let current = Connection()
        current.process.executableURL = executable
        current.process.arguments = arguments + [
            "--device", device, "--kind", kind, "--generation", current.generation
        ]
        current.process.standardInput = current.input
        current.process.standardOutput = current.output
        current.process.standardError = FileHandle.nullDevice
        guard fcntl(current.input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw IPhoneUseError("observation_worker_pipe", "Cannot protect observation command pipe")
        }
        try current.process.run()
        connection = current
        try? current.input.fileHandleForReading.close()
        try? current.output.fileHandleForWriting.close()
        current.drained.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                current.mailbox.finish(); try? current.output.fileHandleForReading.close(); current.drained.leave()
            }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = Darwin.read(current.output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count > 0 {
                    current.mailbox.append(Data(buffer.prefix(count)))
                } else if count < 0 && errno == EINTR { continue } else { break }
            }
        }
        let ready = try wait(current, deadline: deadline, cancelled: cancelled)
        guard ready["event"] as? String == "ready" else {
            throw IPhoneUseError("observation_worker_unavailable", "Observation service did not become ready")
        }
        return current
    }
    private func send(_ command: [String: Any], to current: Connection) throws {
        var data = try jsonData(command); data.append(10)
        try current.input.fileHandleForWriting.write(contentsOf: data)
    }
    private func wait(
        _ current: Connection, deadline: TimeInterval, cancelled: () -> Bool
    ) throws -> [String: Any] {
        while uptime < deadline, !revoked.isCancelled, !cancelled(), connection === current {
            if let value = try current.mailbox.next() {
                guard value["generation"] as? String == current.generation else {
                    throw IPhoneUseError("observation_worker_stale", "Observation connection generation changed")
                }
                if value["event"] as? String == "closed" {
                    cleanup = value["cleanup"] as? [String: Any] ?? [:]
                    current.cleanup = cleanup
                    let failureCode = value["errorKind"] as? String == "connection"
                        ? "observation_connection_failed" : "observation_service_failed"
                    throw IPhoneUseError(
                        value["error"] is String ? failureCode : "observation_worker_closed",
                        value["error"] as? String ?? "Observation service closed")
                }
                return value
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        throw IPhoneUseError("observation_worker_timeout", "Observation request cancelled or expired")
    }
    private func retire() {
        guard let current = connection else { return }
        connection = nil // Revoke publication before requesting shutdown or draining a late result.
        cleanup = current.cleanup ?? ["connectionClosed": false, "tunnelClosed": false]
        try? send(["op": "close", "generation": current.generation], to: current)
        try? current.input.fileHandleForWriting.close()
        let deadline = uptime + 5
        while current.process.isRunning, uptime < deadline {
            if let value = try? current.mailbox.next(), value["event"] as? String == "closed",
                value["generation"] as? String == current.generation {
                cleanup = value["cleanup"] as? [String: Any] ?? [:]
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if current.process.isRunning { current.process.terminate() }
        if !waitForExit(current.process, timeout: 0.5) { kill(current.process.processIdentifier, SIGKILL) }
        let exited = waitForExit(current.process, timeout: 1)
        let drained = current.drained.wait(timeout: .now() + 1) == .success
        if !drained { try? current.output.fileHandleForReading.close() }
        while let value = try? current.mailbox.next() {
            if value["event"] as? String == "closed", value["generation"] as? String == current.generation {
                cleanup = value["cleanup"] as? [String: Any] ?? [:]
            }
        }
        cleanup["processExited"] = exited
        if !exited {
            cleanup["connectionClosed"] = false
            cleanup["tunnelClosed"] = false
        }
    }
    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        // waitUntilExit pumps the calling run loop and can wait indefinitely on Foundation
        // exit notification work, even after isRunning is false. Keep every exit wait bounded.
        let deadline = uptime + timeout
        while process.isRunning, uptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return !process.isRunning
    }
}
