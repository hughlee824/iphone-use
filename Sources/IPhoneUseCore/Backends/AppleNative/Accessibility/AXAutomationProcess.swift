import Foundation
import Darwin
import AppleNativeBridge

// Fixed-operation child, bounded independently of MobileDevice's uninterruptible C calls.
// No external executable/runtime; CoreDevice is the existing Apple notification transport.
struct AXAutomationProcess {
    let ownership: SessionDeviceLock

    func run(
        device: String, journal: URL, token: String, enabled: Bool, cancelled: @escaping () -> Bool,
        executable: URL = Bundle.main.executableURL!, prefix: [String] = ["_ax-automation"], timeout: Double = 28
    ) throws -> [String: Any] {
        let process = Process()
        let output = journal.deletingLastPathComponent().appendingPathComponent("ax-result-\(token).json")
        defer { try? FileManager.default.removeItem(at: output) }
        process.executableURL = executable
        process.arguments = prefix + ["--device", device, "--journal", journal.path, "--token", token,
                                      "--enabled", enabled ? "true" : "false", "--output", output.path]
        let lease = try ownership.inheritedLease(for: device)
        defer { try? lease.close() }
        // Process duplicates this handle to fd 0 before exec; no unlock/close/reopen gap.
        // All other descriptors remain CLOEXEC. The helper never reads stdin.
        process.standardInput = lease
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard !cancelled() else { throw IPhoneUseError("ax_automation_cancelled", "AX enable cancelled before launch") }
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning, !cancelled(), ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let interrupted = process.isRunning
        if interrupted { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        guard !interrupted, process.terminationStatus == 0 else {
            throw IPhoneUseError(
                "ax_automation_uncertain", "AX preference helper failed or timed out; cleanup required")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 65536 else {
            throw IPhoneUseError("ax_automation_invalid", "AX preference helper output exceeded its limit")
        }
        let result = try jsonObject(Data(contentsOf: output))
        guard result["token"] as? String == token, result["device"] as? String == device,
              result["enabled"] as? Bool == enabled else {
            throw IPhoneUseError("ax_automation_invalid", "AX preference helper identity mismatch")
        }
        return result
    }
}

public enum AXAutomationHost {
    public static func run(device: String, journal: URL, token: String, enabled: Bool, output: URL) throws {
        umask(0o077)
        // Also bounds an orphan if its parent is killed. SIGALRM terminates this helper only.
        alarm(25)
        defer { alarm(0) }
        try withOwnership(device: device, journal: journal, token: token, enabled: enabled) {
            var facts = apply(
                enabled: enabled, write: { ASSetAXAutomation(device, $0) as? [String: Any] ?? [:] }, notify: {
                    try CoreDevice.read([
                        "device", "notification", "post", "--device", device,
                        "--name", "com.apple.accessibility.cache.automation.enabled"
                    ], timeout: 5, inheritedInput: .standardInput)
                })
            facts["token"] = token; facts["device"] = device; facts["enabled"] = enabled
            try saveJSON(facts, to: output)
        }
    }

    static func apply(
        enabled: Bool, write: (Bool) -> [String: Any], notify: () throws -> [String: Any]
    ) -> [String: Any] {
        var facts = write(enabled)
        facts["notificationAcknowledged"] = false
        if facts["writeAcknowledged"] as? Bool == true {
            do {
                let notifications = try notify()["notifications"] as? [[String: Any]] ?? []
                facts["notificationAcknowledged"] = notifications.count == 1
                    && notifications[0]["name"] as? String == "com.apple.accessibility.cache.automation.enabled"
            } catch { facts["notificationError"] = String(describing: error) }
        }
        return facts
    }

    static func withOwnership(
        device: String, journal: URL, token: String, enabled: Bool,
        controlDescriptor: Int32 = STDIN_FILENO, operation: () throws -> Void
    ) throws {
        try InheritedDeviceLock.validate(device: device, descriptor: controlDescriptor)
        guard device.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil,
              UUID(uuidString: token) != nil else {
            throw IPhoneUseError("ax_automation_invalid", "Invalid automation helper identity")
        }
        let descriptor = Darwin.open(journal.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw IPhoneUseError("ax_automation_lock", "Cannot open AX mutation lock") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw IPhoneUseError("ax_automation_busy", "Previous AX helper still owns the mutation lock")
        }
        let marker = try jsonObject(Data(contentsOf: journal))
        guard marker["token"] as? String == token, marker["device"] as? String == device,
              marker["enabled"] as? Bool == enabled else {
            throw IPhoneUseError("ax_automation_superseded", "AX helper ownership was revoked")
        }
        try operation()
    }
}
