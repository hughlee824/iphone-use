import Foundation
import Darwin

// Isolated native helper: same CLI binary, owned USB transport, no external runtime.
final class AXPReader {
    private var persistent: NativeObservationWorker?

    func prepare(device: String, cancelled: () -> Bool) throws {
        let worker = NativeObservationWorker(device: device, kind: "ax")
        persistent = worker
        try worker.prewarm(cancelled: cancelled)
    }
    func close() -> [String: Any] { persistent?.close() ?? [:] }

    let executable: URL
    let arguments: [String]

    init(executable: URL = Bundle.main.executableURL!, arguments: [String] = ["_axp-observe"]) {
        self.executable = executable
        self.arguments = arguments
    }

    func read(device: String, cancelled: () -> Bool) throws -> [String: Any] {
        if let persistent { return try persistent.read(cancelled: cancelled) }
        let process = Process(), pipe = Pipe(), output = AXPOutput()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        process.executableURL = executable
        process.arguments = arguments + ["--device", device]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = pipe
        let drained = DispatchGroup()
        try process.run()
        try? pipe.fileHandleForWriting.close()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { drained.leave() }
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                output.append(chunk)
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 16
        var interrupted = false
        while process.isRunning {
            if cancelled() || output.exceeded || ProcessInfo.processInfo.systemUptime >= deadline {
                interrupted = true
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 2
                while process.isRunning, ProcessInfo.processInfo.systemUptime < grace {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        let closed = drained.wait(timeout: .now() + 1) == .success
        try? pipe.fileHandleForReading.close()
        guard !interrupted, closed, !output.exceeded, process.terminationStatus == 0 else {
            throw IPhoneUseError("axp_unavailable", "AXP helper failed or exceeded its budget; use the screenshot")
        }
        return try jsonObject(output.data)
    }
}

private final class AXPOutput {
    private let lock = NSLock()
    private var bytes = Data()
    private var overflow = false
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    var exceeded: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !overflow, bytes.count + chunk.count <= 12 * 1024 * 1024 else {
            overflow = true
            return
        }
        bytes.append(chunk)
    }
}
