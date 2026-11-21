import Foundation
import SQLite3
import XCTest
@testable import IPhoneUseCore

final class DiagnosticFrameTests: XCTestCase {
    private func fixture() throws -> (SessionHost, HostRequestExecution) {
        let root = URL(fileURLWithPath: "/private/tmp/guard-history-" + UUID().uuidString)
        let paths = SessionPaths(directory: root.appendingPathComponent("session"))
        try SessionPaths.secureDirectory(paths.directory)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let config = HostConfiguration(session: "fixture", device: "fixture", xctestrun: "", idleTimeoutSeconds: 20,
                                       backend: "apple-native")
        let host = SessionHost(config: config, paths: paths, backend: ControlledBackend(),
                               diagnosticPreferences: DiagnosticPreferences())
        let admission = HostRequest(["version": 2, "session": "fixture", "op": "tap", "id": UUID().uuidString,
                                     "reference": "o1", "x": 10, "y": 20], config: config) { _, _ in }
        XCTAssertTrue(admission.validate())
        return (host, HostRequestExecution(host: host, admission: admission))
    }

    func testExactGuardBytesAndReturnedFrameAreSeparateAndRejectedFrameIsShared() throws {
        for rejected in [false, true] {
            let (host, execution) = try fixture()
            let capture = try observationFixture()
            _ = try host.observations.store(capture)
            let result = try host.observations.store(capture)
            let guardPNG = rejected ? capture.screenshot : try screenPNG(width: 12, height: 18)
            execution.response["observation"] = ["phase": rejected ? "pre_input_rejection" : "after",
                                                 "ok": true, "result": result]
            execution.response["outcome"] = rejected ? "not_dispatched" : "unknown"
            execution.recordEvent(elapsedMs: 1, guardPNG: guardPNG)
            let database = try XCTUnwrap(host.diagnostics?.database)
            var frames: [String: Data] = [:]
            try database.query("SELECT ref,png,context FROM frames") { row in
                let facts = try jsonObject(XCTUnwrap(DiagnosticDatabase.data(row, 2)))
                XCTAssertEqual(facts["sourceObservation"] as? String, "o1")
                XCTAssertEqual(facts["observation"] as? String, "o2")
                let key = try XCTUnwrap(facts["guardFrame"] as? String)
                if rejected { XCTAssertEqual(key, "o2") } else { XCTAssertTrue(key.hasPrefix("guard-")) }
                frames[String(cString: sqlite3_column_text(row, 0))] = DiagnosticDatabase.data(row, 1)
            }
            XCTAssertEqual(frames["o2"], capture.screenshot)
            XCTAssertEqual(frames.count, rejected ? 1 : 2)
            XCTAssertTrue(frames.values.contains(guardPNG))
        }
    }

    func testArchiveWriteFailurePreservesInputAndFallsBackToRedactedTimeline() throws {
        let (host, execution) = try fixture()
        let database = try XCTUnwrap(host.diagnostics?.database)
        try database.execute("""
            CREATE TRIGGER fail_frame BEFORE INSERT ON frames BEGIN SELECT RAISE(ABORT,'fixture'); END
            """)
        execution.response["outcome"] = "unknown"
        execution.response["ok"] = false
        execution.response["result"] = ["transportStatus": "sent", "verificationStatus": "not_checked"]
        execution.recordEvent(elapsedMs: 1, guardPNG: Data([1]))
        XCTAssertEqual(execution.response["eventRecordingError"] as? String, "diagnostics_storage_error")
        XCTAssertEqual(execution.response["outcome"] as? String, "unknown")
        try database.query("SELECT json FROM events") { row in
            let event = try jsonObject(XCTUnwrap(DiagnosticDatabase.data(row, 0)))
            XCTAssertEqual(event["transportStatus"] as? String, "sent")
            XCTAssertEqual(event["level"] as? String, "error")
            XCTAssertNil(event["guardFrame"])
        }
    }
}
