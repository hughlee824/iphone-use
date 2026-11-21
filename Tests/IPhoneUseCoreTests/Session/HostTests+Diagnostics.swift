import Foundation
import XCTest
@testable import IPhoneUseCore

extension HostTests {
    private func member(_ name: String, in archive: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, name]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return data
    }

    func testOfflineExportLinksRunnerFollowupAndOmitsPrivateContentsByDefault() throws {
        let backend = ControlledBackend()
        let capture = try observationFixture()
        let running = try host(timeout: 10, backend: backend)
        let paths = running.paths, session = running.session
        _ = try call(paths, session: session, op: "observe")
        let action = try call(paths, session: session, op: "tap", fields: [
            "reference": "o1:e11", "text": "typed-private-fixture", "token": "private-fixture-token"
        ])
        let actionID = try XCTUnwrap(action["id"] as? String)
        _ = try call(paths, session: session, op: "observe", fields: ["followingAction": actionID])
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [running.finished], timeout: 3)
        let cached = paths.directory.appendingPathComponent("observations")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path))
        let root = paths.directory.deletingLastPathComponent()
        let database = try DiagnosticDatabase(root: root)
        let plain = root.appendingPathComponent("plain.zip")
        let manifest = try DiagnosticHistory.export(database: database, preferences: .init(), session: nil,
                                                    destination: plain, selection: .init())
        XCTAssertEqual(manifest["session"] as? String, session)
        XCTAssertEqual(manifest["includesEvidence"] as? Bool, false)
        let timeline = try XCTUnwrap(String(data: member("timeline.jsonl", in: plain), encoding: .utf8))
        for privateText in ["typed-private-fixture", "private-fixture-token", "screenshotBase64",
                            paths.directory.path, "com.example.fixture"] {
            XCTAssertFalse(timeline.contains(privateText))
        }
        let events = try timeline.split(separator: "\n").map { try jsonObject(Data($0.utf8)) }
        let tap = try XCTUnwrap(events.first {
            $0["operation"] as? String == "tap" && $0["phase"] as? String == "finished"
        })
        XCTAssertEqual(tap["sourceObservation"] as? String, "o1")
        XCTAssertEqual(tap["targetElement"] as? Int, 11)
        let after = try XCTUnwrap(events.first { $0["followingAction"] as? String == actionID })
        XCTAssertEqual(after["observation"] as? String, "o2")
        let shared = root.appendingPathComponent("shared.zip")
        let chosen = DiagnosticHistory.Selection(references: ["o2"])
        let exported = try DiagnosticHistory.export(database: database, preferences: .init(), session: session,
                                                    destination: shared, selection: chosen)
        let frames = try XCTUnwrap(exported["availableFrames"] as? [[String: Any]])
        XCTAssertEqual(frames.filter { $0["included"] as? Bool == true }.compactMap { $0["ref"] as? String }, ["o2"])
        XCTAssertEqual(try member("o2/screen.png", in: shared), capture.screenshot)
        XCTAssertEqual(try jsonObject(member("o2/ax.json", in: shared))["observation"] as? String, "o2")
        XCTAssertThrowsError(try DiagnosticHistory.export(database: database, preferences: .init(), session: nil,
                                                          destination: shared, selection: .init()))
        XCTAssertEqual(backend.actionCount, 1)
        XCTAssertEqual(backend.observeCount, 2)
    }

    func testDebugWithCaptureDisabledKeepsNumericTimingsWithoutFrames() throws {
        var settings = DiagnosticPreferences()
        settings.level = .debug
        settings.captureEvidence = false
        let running = try host(timeout: 10, backend: ControlledBackend(), native: true, diagnostics: settings)
        _ = try call(running.paths, session: running.session, op: "observe")
        _ = try call(running.paths, session: running.session, op: "disconnect")
        wait(for: [running.finished], timeout: 3)
        let database = try DiagnosticDatabase(root: running.paths.directory.deletingLastPathComponent())
        var events: [[String: Any]] = []
        try database.query("SELECT json FROM events") { events.append(try jsonObject(XCTUnwrap(
            DiagnosticDatabase.data($0, 0)))) }
        XCTAssertTrue(events.contains { $0["operation"] as? String == "timings" && $0["level"] as? String == "debug" })
        try database.query("SELECT ref FROM frames") { _ in XCTFail("disabled evidence wrote a frame") }
    }
}
