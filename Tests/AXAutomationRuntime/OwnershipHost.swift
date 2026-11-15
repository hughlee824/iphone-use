import Foundation
import Darwin
@testable import IPhoneUseCore

// No Apple device calls. Exercise production process spawning, descriptor transfer, locks,
// controller compensation and acknowledgement handling, with a file standing in for the preference.
@main
struct OwnershipHost {
    static func main() throws {
        let args = CommandLine.arguments
        if args[1] == "notifier" {
            let root = URL(fileURLWithPath: args[2])
            try InheritedDeviceLock.validate(device: args[3])
            try pause(root: root, journal: URL(fileURLWithPath: args[4]), helperPID: Int32(args[5]))
            return
        }
        if args[1] == "helper" {
            do { try helper(args) } catch {
                print("Helper rejected: \(error)")
                exit(3)
            }
            return
        }
        let root = URL(fileURLWithPath: args[2]), device = args[3], scenario = args[4]
        let state = root.appendingPathComponent(args[1] == "admit" ? "successor-state" : "owner-state")
        try SessionPaths.secureDirectory(state)
        do {
            let owner = try SessionDeviceLock(root: state, device: device)
            if args[1] == "admit" {
                try withExtendedLifetime(owner) {
                    try Data("true".utf8).write(to: root.appendingPathComponent("preference"))
                    print("{\"acquired\":true}")
                }
                return
            }
            let journalRoot = root.appendingPathComponent("journal")
            let controller = AXAutomation(device: device, root: journalRoot) { journal, token, enabled, cancelled in
                try AXAutomationProcess(ownership: owner).run(
                    device: device, journal: journal, token: token, enabled: enabled, cancelled: cancelled,
                    executable: URL(fileURLWithPath: args[0]),
                    prefix: ["helper", "--fixture-root", root.path, "--scenario", scenario],
                    timeout: scenario == "timeout" ? 2 : 12)
            }
            controller.start(cancelled: { false })
            let cleanup = controller.close()
            try saveJSON(cleanup, to: root.appendingPathComponent("cleanup.json"))
        } catch {
            let result = try jsonData(["acquired": false, "code": (error as? IPhoneUseError)?.code ?? "failed"])
            print(String(data: result, encoding: .utf8)!)
            exit(2)
        }
    }

    static func helper(_ args: [String]) throws {
        alarm(20)
        let fields = Dictionary(uniqueKeysWithValues: stride(from: 2, to: args.count, by: 2).map {
            (args[$0], args[$0 + 1])
        })
        let root = URL(fileURLWithPath: fields["--fixture-root"]!)
        let journal = URL(fileURLWithPath: fields["--journal"]!)
        let token = fields["--token"]!, device = fields["--device"]!, scenario = fields["--scenario"]!
        let enabled = fields["--enabled"] == "true"
        if !enabled, scenario == "before-validation" { try pause(root: root, journal: journal) }
        if fields["--close-stdin"] == "true" { Darwin.close(STDIN_FILENO) }
        try AXAutomationHost.withOwnership(device: device, journal: journal, token: token, enabled: enabled) {
            if !enabled, ["after-validation", "timeout"].contains(scenario) {
                try pause(root: root, journal: journal)
            }
            try Data((enabled ? "true" : "false").utf8).write(to: root.appendingPathComponent("preference"))
            let log = root.appendingPathComponent("writes")
            if !FileManager.default.fileExists(atPath: log.path) {
                FileManager.default.createFile(atPath: log.path, contents: nil)
            }
            let file = try FileHandle(forWritingTo: log)
            try file.seekToEnd(); try file.write(contentsOf: Data((enabled ? "true\n" : "false\n").utf8))
            try file.close()
            if !enabled, scenario == "after-write" { try pause(root: root, journal: journal) }
            if !enabled, scenario == "notification" {
                let notification = CoreDevice.commandProcess(input: .standardInput, log: .nullDevice)
                notification.executableURL = URL(fileURLWithPath: args[0])
                notification.arguments = ["notifier", root.path, device, journal.path, String(getpid())]
                try notification.run()
                notification.waitUntilExit()
                guard notification.terminationStatus == 0 else {
                    throw IPhoneUseError("fixture_notification_failed", "Notification subprocess failed")
                }
            }
            try saveJSON(["device": device, "token": token, "enabled": enabled,
                          "writeAcknowledged": true, "notificationAcknowledged": true],
                         to: URL(fileURLWithPath: fields["--output"]!))
        }
    }

    static func pause(root: URL, journal: URL, helperPID: Int32? = nil) throws {
        var facts: [String: Any] = ["pid": getpid(), "journal": journal.path]
        if let helperPID { facts["helperPID"] = helperPID }
        try saveJSON(facts, to: root.appendingPathComponent("ready.json"))
        let gate = root.appendingPathComponent("continue")
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !FileManager.default.fileExists(atPath: gate.path) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw IPhoneUseError("fixture_timeout", "Gate not opened")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
