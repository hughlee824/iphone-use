import XCTest
import SQLite3
@testable import IPhoneUseCore

final class DiagnosticHistoryTests: XCTestCase {
    func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/diag-" + UUID().uuidString)
        try SessionPaths.secureDirectory(root)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    func count(_ database: DiagnosticDatabase, _ sql: String) throws -> Int {
        var result = 0
        try database.query(sql) { result = Int(sqlite3_column_int64($0, 0)) }
        return result
    }

    func testSystemTemporaryAliasWorksButDatabaseSymlinkIsRejected() throws {
        let root = try root()
        let alias = URL(fileURLWithPath: root.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"))
        _ = try DiagnosticDatabase(root: alias)
        let directory = root.appendingPathComponent("diagnostics")
        let file = directory.appendingPathComponent("history.sqlite3")
        let moved = root.appendingPathComponent("unrelated")
        try FileManager.default.moveItem(at: file, to: moved)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: moved)
        XCTAssertThrowsError(try DiagnosticDatabase(root: alias))
    }

    func testPreferencesPersistInSharedConfigurationAndInvalidUpdateDoesNotEnableCapture() throws {
        let root = try root(), env = ["IPHONE_USE_CONFIG_DIR": root.path]
        let defaults = try DiagnosticPreferences.configured(environment: env)
        XCTAssertEqual(defaults.level, .info)
        XCTAssertTrue(defaults.captureEvidence)
        let prefs = try DiagnosticPreferences.configured(environment: env) {
            $0.level = .debug
            $0.captureEvidence = false
        }
        XCTAssertEqual(prefs.level, .debug)
        XCTAssertThrowsError(try DiagnosticPreferences.configured(environment: env) { $0.evidenceMiB = 0 })
        XCTAssertFalse(try DiagnosticPreferences.configured(environment: env).captureEvidence)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("diagnostics.json").path))
        let file = root.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: file)
        XCTAssertThrowsError(try DiagnosticPreferences.configured(environment: env))
    }

    func testLevelFilteringIndependentFromMediaAndCleanSkipsLiveAndPending() throws {
        let root = try root()
        var prefs = DiagnosticPreferences()
        prefs.level = .warn
        for session in ["active", "pending", "finished"] {
            let log = try SessionDiagnostics(root: root, session: session, mode: "runner", preferences: prefs)
            try log.database.transaction {
                for level in DiagnosticLevel.allCases { try log.event(["operation": "tap"], level: level) }
                XCTAssertTrue(try log.frame("o1", png: Data([1]), snapshotData: nil))
            }
            if session != "active" { try log.lifecycle("disconnect", level: .info, clean: session == "finished") }
        }
        let database = try DiagnosticDatabase(root: root)
        XCTAssertEqual(try count(database, "SELECT count(*) FROM events"), 6)
        let future = Date().timeIntervalSince1970 + 8 * 86400
        let dry = try DiagnosticHistory.clean(root: root, preferences: prefs, apply: false, now: future)
        XCTAssertEqual(dry["expired"] as? [String: Int], ["frames": 1, "events": 2])
        XCTAssertEqual(try count(database, "SELECT count(*) FROM frames"), 3)
        _ = try DiagnosticHistory.clean(root: root, preferences: prefs, apply: true, now: future)
        XCTAssertEqual(try count(database, "SELECT count(*) FROM frames WHERE session='finished'"), 0)
        XCTAssertEqual(try count(database, "SELECT count(*) FROM frames WHERE session IN ('active','pending')"), 2)
        XCTAssertEqual(try count(database, "SELECT count(*) FROM events"), 4)
    }

    func testUnconfirmedDisconnectKeepsExpiredEvidenceWhileCleaningFinishedSessions() throws {
        let root = try root()
        let pending = try SessionDiagnostics(root: root, session: "pending", mode: "standard", preferences: .init())
        let finished = try SessionDiagnostics(root: root, session: "finished", mode: "standard", preferences: .init())
        for log in [pending, finished] {
            try log.database.transaction {
                try log.event(["operation": "tap"], level: .info)
                XCTAssertTrue(try log.frame("o1", png: Data([1]), snapshotData: nil))
            }
        }
        try finished.lifecycle("disconnect", level: .info, clean: true)
        let database = pending.database
        // Age both sessions' evidence before the pending host attempts its final cleanup.
        try database.execute("UPDATE frames SET time=0")
        try database.execute("UPDATE events SET time=0")
        try pending.lifecycle("disconnect", level: .error, clean: false,
                              cleanup: ["axAutomation": ["cleanupPending": true]])

        let pendingClose = "SELECT count(*) FROM sessions WHERE id='pending' AND clean=0 AND closed IS NOT NULL"
        XCTAssertEqual(try count(database, pendingClose), 1)
        for table in ["frames", "events"] {
            let expired = "SELECT count(*) FROM " + table + " WHERE time=0 AND session="
            XCTAssertEqual(try count(database, expired + "'pending'"), 1, table)
            XCTAssertEqual(try count(database, expired + "'finished'"), 0, table)
        }
    }

    func testCapacityNeverEvictsAnotherLiveSessionOrProtectedFinalFrame() throws {
        let root = try root()
        var prefs = DiagnosticPreferences()
        prefs.evidenceMiB = 1
        let first = try SessionDiagnostics(root: root, session: "one", mode: "standard", preferences: prefs)
        let second = try SessionDiagnostics(root: root, session: "two", mode: "standard", preferences: prefs)
        let png = Data(repeating: 42, count: 600_000)
        XCTAssertTrue(try first.database.transaction { try first.frame("o1", png: png, snapshotData: nil) })
        XCTAssertFalse(try second.database.transaction { try second.frame("o1", png: png, snapshotData: nil) })
        XCTAssertFalse(try first.database.transaction {
            try first.frame("guard", png: png, snapshotData: nil, keeping: "o1")
        })
        XCTAssertTrue(try first.database.transaction { try first.frame("o2", png: png, snapshotData: nil) })
        try first.lifecycle("disconnect", level: .info, clean: true)
        XCTAssertTrue(try second.database.transaction { try second.frame("o1", png: png, snapshotData: nil) })
        XCTAssertEqual(try count(second.database, "SELECT count(*) FROM frames WHERE session='one'"), 0)
    }

    func testLegacyCleanupRequiresTerminalIdentityAndAllAcknowledgements() throws {
        let root = try root(), now = Date().timeIntervalSince1970
        var dirs: [URL] = []
        for index in 1...5 {
            let session = "s" + String(repeating: String(index), count: 32)
            let dir = root.appendingPathComponent(session)
            try SessionPaths.secureDirectory(dir)
            try Data([1]).write(to: dir.appendingPathComponent("native-events.jsonl"))
            let cleanup: [String: Any] = ["backendStopped": true, "shutdownAcknowledged": index != 3,
                "observationCacheRemoved": true, "axAutomation": ["cleanupPending": index == 5],
                "touchPaste": ["connectionsClosed": true, "pasteboardRestoreAcknowledged": true]]
            try saveJSON(["session": index == 2 ? "another" : session, "endedAt": now - 30 * 86400,
                          "cleanup": cleanup], to: dir.appendingPathComponent("exit.json"))
            if index == 4 { try Data().write(to: dir.appendingPathComponent("ipc.sock")) }
            dirs.append(dir)
        }
        _ = try DiagnosticHistory.clean(root: root, preferences: .init(), apply: false, now: now)
        let firstLog = dirs[0].appendingPathComponent("native-events.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstLog.path))
        _ = try DiagnosticHistory.clean(root: root, preferences: .init(), apply: true, now: now)
        for (index, dir) in dirs.enumerated() {
            let legacyLog = dir.appendingPathComponent("native-events.jsonl")
            XCTAssertEqual(FileManager.default.fileExists(atPath: legacyLog.path), index != 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("exit.json").path))
        }
    }
}
