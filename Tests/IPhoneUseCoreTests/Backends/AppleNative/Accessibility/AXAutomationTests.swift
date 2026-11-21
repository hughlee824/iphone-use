import Foundation
import XCTest
@testable import IPhoneUseCore

final class AXAutomationTests: XCTestCase {
    let acknowledged: [String: Any] = ["writeAcknowledged": true, "notificationAcknowledged": true]

    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ax-automation-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testEnableOnceAndDisableOnceWithJournalBeforeDispatch() throws {
        var writes: [Bool] = []
        let controller = AXAutomation(device: "device", root: try root()) { journal, token, enabled, _ in
            let marker = try jsonObject(Data(contentsOf: journal))
            XCTAssertEqual(marker["token"] as? String, token)
            XCTAssertEqual(marker["enabled"] as? Bool, enabled)
            writes.append(enabled)
            return self.acknowledged
        }
        controller.start(cancelled: { false })
        controller.start(cancelled: { false })
        XCTAssertEqual(writes, [true])
        XCTAssertEqual(controller.status["state"] as? String, "enabled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: controller.journal.path))
        XCTAssertEqual(controller.close()["acknowledged"] as? Bool, true)
        XCTAssertEqual(controller.close()["acknowledged"] as? Bool, true)
        controller.start(cancelled: { false })
        XCTAssertEqual(writes, [true, false])
        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.journal.path))
    }

    func testFailedWriteOrNotificationCompensatesWithoutReplayingEnable() throws {
        for failure in [[:], ["writeAcknowledged": true], ["notificationAcknowledged": true]] {
            var writes: [Bool] = []
            let controller = AXAutomation(device: "device", root: try root()) { _, _, enabled, _ in
                writes.append(enabled)
                return enabled ? failure : self.acknowledged
            }
            controller.start(cancelled: { false })
            XCTAssertEqual(writes, [true, false])
            XCTAssertEqual(controller.status["state"] as? String, "unavailable")
            XCTAssertEqual(controller.close()["acknowledged"] as? Bool, true)
            XCTAssertEqual(writes, [true, false])
        }
    }

    func testUnknownWriteAndFailedCleanupRemainPendingForNextSession() throws {
        let directory = try root()
        var writes: [Bool] = []
        let failed = AXAutomation(device: "device", root: directory) { _, _, enabled, _ in
            writes.append(enabled)
            throw IPhoneUseError("injected", "Lost reply")
        }
        failed.start(cancelled: { false })
        XCTAssertEqual(failed.close()["acknowledged"] as? Bool, false)
        XCTAssertEqual(writes, [true, false, false])
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.journal.path))
        writes = []
        let recovered = AXAutomation(device: "device", root: directory) { _, _, enabled, _ in
            writes.append(enabled)
            return self.acknowledged
        }
        recovered.start(cancelled: { false })
        XCTAssertEqual(writes, [false, true])
        XCTAssertEqual(recovered.close()["acknowledged"] as? Bool, true)
        XCTAssertEqual(writes, [false, true, false])
    }

    func testFailedRecoveryDoesNotEnable() throws {
        let directory = try root()
        try Data("incomplete old journal".utf8).write(to: directory.appendingPathComponent("ax-automation-device.json"))
        var writes: [Bool] = []
        let controller = AXAutomation(device: "device", root: directory) { _, _, enabled, _ in
            writes.append(enabled)
            return [:]
        }
        controller.start(cancelled: { false })
        XCTAssertEqual(writes, [false])
        XCTAssertEqual(controller.status["state"] as? String, "cleanup_pending")
        XCTAssertEqual(controller.close()["acknowledged"] as? Bool, false)
        XCTAssertEqual(writes, [false, false])
    }

    func testCancellationStillClosesButDoesNotStartEnable() throws {
        var cancelled = false
        var writes: [Bool] = []
        let controller = AXAutomation(device: "device", root: try root()) { _, _, enabled, isCancelled in
            XCTAssertFalse(isCancelled())
            writes.append(enabled)
            return self.acknowledged
        }
        controller.start(cancelled: { cancelled })
        cancelled = true
        XCTAssertEqual(controller.close()["acknowledged"] as? Bool, true)
        XCTAssertEqual(writes, [true, false])
        let inactive = AXAutomation(device: "device", root: try root()) { _, _, _, _ in
            XCTFail("Cancelled startup must not dispatch"); return [:]
        }
        inactive.start(cancelled: { true })
        XCTAssertEqual(inactive.close()["acknowledged"] as? Bool, true)
    }

    func testJournalFailurePreventsWrite() throws {
        let directory = try root().appendingPathComponent("not-a-directory")
        try Data().write(to: directory)
        let controller = AXAutomation(device: "device", root: directory) { _, _, _, _ in
            XCTFail("Journal must exist before dispatch"); return [:]
        }
        controller.start(cancelled: { false })
        XCTAssertEqual(controller.status["state"] as? String, "cleanup_pending")
        XCTAssertEqual(controller.close()["acknowledged"] as? Bool, false)
    }

    func testBackendStopReportsFailedDisableAndRunsDespiteCancellation() throws {
        for success in [false, true] {
            let directory = try root()
            let backend = AppleDeviceBackend(
                config: HostConfiguration(session: "fixture", device: "device", xctestrun: "",
                                          idleTimeoutSeconds: 60, backend: "apple-native"),
                paths: SessionPaths(directory: directory), axpReader: nil)
            var writes: [Bool] = []
            let controller = AXAutomation(device: "device", root: directory) { _, _, enabled, cancelled in
                XCTAssertFalse(cancelled())
                writes.append(enabled)
                return enabled || success ? self.acknowledged : [:]
            }
            backend.axAutomation = controller
            controller.start(cancelled: { false })
            backend.cancelCurrent()
            let cleanup = backend.stop()
            XCTAssertEqual(cleanup["shutdownAcknowledged"] as? Bool, success)
            XCTAssertEqual(cleanup["backendStopped"] as? Bool, true)
            XCTAssertEqual((cleanup["axAutomation"] as? [String: Any])?["cleanupPending"] as? Bool, !success)
            _ = backend.stop()
            XCTAssertEqual(writes, [true, false])
        }
    }

}
