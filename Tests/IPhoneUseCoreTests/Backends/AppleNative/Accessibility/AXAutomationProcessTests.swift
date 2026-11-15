import Foundation
import Darwin
import XCTest
@testable import IPhoneUseCore

final class AXAutomationProcessTests: XCTestCase {
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ax-helper-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testSupersededHelperCannotDispatchAndMutationLockRejectsOverlap() throws {
        let journal = try root().appendingPathComponent("journal.json")
        let owner = try SessionDeviceLock(root: journal.deletingLastPathComponent(), device: "device")
        let lease = try owner.inheritedLease(for: "device")
        defer { try? lease.close() }
        let old = UUID().uuidString, current = UUID().uuidString
        try saveJSON(["device": "device", "token": current, "enabled": false], to: journal)
        XCTAssertThrowsError(try AXAutomationHost.withOwnership(
            device: "device", journal: journal, token: old, enabled: true,
            controlDescriptor: lease.fileDescriptor) { XCTFail("Stale helper dispatched") })
        try AXAutomationHost.withOwnership(device: "device", journal: journal, token: current, enabled: false,
            controlDescriptor: lease.fileDescriptor) {
            XCTAssertThrowsError(try AXAutomationHost.withOwnership(
                device: "device", journal: journal, token: current, enabled: false,
            controlDescriptor: lease.fileDescriptor) { XCTFail("Overlapping mutation") })
        }
        try AXAutomationHost.withOwnership(device: "device", journal: journal, token: current, enabled: false,
            controlDescriptor: lease.fileDescriptor) {}
        try FileManager.default.removeItem(at: journal)
        XCTAssertThrowsError(try AXAutomationHost.withOwnership(
            device: "device", journal: journal, token: current, enabled: false,
            controlDescriptor: lease.fileDescriptor) { XCTFail("Removed owner dispatched") })
    }

    func testBoundedProcessAndReplyIdentity() throws {
        let directory = try root(), token = UUID().uuidString
        let owner = try SessionDeviceLock(root: directory, device: "device")
        let script = directory.appendingPathComponent("helper.py")
        let journal = directory.appendingPathComponent("journal.json")
        func run(_ source: String, cancelled: @escaping () -> Bool = { false }) throws -> [String: Any] {
            try source.write(to: script, atomically: true, encoding: .utf8)
            return try AXAutomationProcess(ownership: owner).run(
                device: "device", journal: journal, token: token, enabled: true, cancelled: cancelled,
                executable: URL(fileURLWithPath: "/usr/bin/python3"), prefix: ["-I", "-B", script.path], timeout: 1)
        }
        let prefix = "import sys,json; a=dict(zip(sys.argv[1::2],sys.argv[2::2])); "
        let reply = prefix
            + "json.dump({'device':a['--device'],'token':a['--token'],'enabled':True},open(a['--output'],'w'))"
        XCTAssertEqual(try run(reply)["token"] as? String, token)
        XCTAssertThrowsError(try run(prefix + "json.dump({'token':'wrong'},open(a['--output'],'w'))"))
        XCTAssertThrowsError(try run(prefix + "open(a['--output'],'w').write('x'*70000)"))
        XCTAssertThrowsError(try run("import sys; sys.exit(2)"))
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try run("import time; time.sleep(60)"))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        XCTAssertThrowsError(try run("raise Exception('must not run')", cancelled: { true }))
        let resultPath = directory.appendingPathComponent("ax-result-\(token).json").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: resultPath))
    }
    func testNotificationRequiresAcknowledgedWriteAndExactResponse() {
        var notifications = 0
        let failed = AXAutomationHost.apply(enabled: true, write: { _ in [:] }, notify: {
            notifications += 1; return [:]
        })
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(failed["notificationAcknowledged"] as? Bool, false)
        for enabled in [true, false] {
            let good = AXAutomationHost.apply(enabled: enabled, write: {
                XCTAssertEqual($0, enabled); return ["writeAcknowledged": true]
            }, notify: { ["notifications": [["name": "com.apple.accessibility.cache.automation.enabled"]]] })
            XCTAssertEqual(good["notificationAcknowledged"] as? Bool, true)
            let bad = AXAutomationHost.apply(enabled: enabled, write: { _ in ["writeAcknowledged": true] }, notify: {
                throw IPhoneUseError("injected", "Notification lost")
            })
            XCTAssertEqual(bad["writeAcknowledged"] as? Bool, true)
            XCTAssertEqual(bad["notificationAcknowledged"] as? Bool, false)
            XCTAssertNotNil(bad["notificationError"])
        }
        let wrong = AXAutomationHost.apply(enabled: true, write: { _ in ["writeAcknowledged": true] }, notify: {
            ["notifications": [["name": "different"]]]
        })
        XCTAssertEqual(wrong["notificationAcknowledged"] as? Bool, false)
    }

}
