import Foundation
import SQLite3

final class SessionDiagnostics {
    let database: DiagnosticDatabase
    let preferences: DiagnosticPreferences
    let session: String
    let mode: String
    init(root: URL, session: String, mode: String, preferences: DiagnosticPreferences) throws {
        database = try DiagnosticDatabase(root: root)
        self.session = session
        self.mode = mode
        self.preferences = preferences
        try database.execute("INSERT INTO sessions(id,started) VALUES(?,?)", [.text(session), .number(now)])
    }

    private var now: Double { Date().timeIntervalSince1970 }

    func lifecycle(_ operation: String, level: DiagnosticLevel, clean: Bool? = nil,
                   cleanup: [String: Any] = [:]) throws {
        try database.transaction {
            if let clean {
                try database.execute("UPDATE sessions SET closed=?,clean=? WHERE id=?",
                               [.number(now), .number(clean ? 1 : 0), .text(session)])
            }
            var facts: [String: Any] = ["operation": operation]
            facts["cleanupConfirmed"] = clean
            for key in ["backendStopped", "runnerProcessExited", "shutdownAcknowledged", "observationCacheRemoved"] {
                facts[key] = cleanup[key] as? Bool
            }
            let automation = cleanup["axAutomation"] as? [String: Any]
            facts["axCleanupPending"] = automation?["cleanupPending"] as? Bool
            facts["axDisableConfirmed"] = (automation?["disable"] as? [String: Any])?["acknowledged"] as? Bool
            try event(facts, level: level)
            try database.expire(preferences, now: now)
        }
    }

    func event(_ facts: [String: Any], level: DiagnosticLevel) throws {
        guard preferences.level.admits(level) else { return }
        let time = now
        var record = facts
        record["version"] = 1
        record["time"] = time
        record["level"] = level.rawValue
        record["session"] = session
        record["mode"] = mode
        try database.execute("INSERT INTO events(session,time,json) VALUES(?,?,?)",
                       [.text(session), .number(time), .bytes(try jsonData(record))])
    }

    /// Called after dispatch, including for the exact preflight PNG. No file I/O occurs inside the input guard.
    func frame(_ reference: String, png: Data, snapshotData: Data?,
               keeping referenceToKeep: String? = nil) throws -> Bool {
        let bytes = png.count + (snapshotData?.count ?? 0)
        let limit = preferences.evidenceMiB * 1024 * 1024
        guard preferences.captureEvidence, bytes <= limit else { return false }
        let time = now
        // The caller holds a write transaction across quota enforcement, evidence and its timeline record.
        try database.expireFrames(preferences, now: time, writer: session)
        var used = 0
        try database.query("SELECT COALESCE(SUM(bytes),0) FROM frames") { used = Int(sqlite3_column_int64($0, 0)) }
        if used + bytes > limit {
            var evictions: [Double] = []
            try database.query("""
                SELECT rowid,bytes FROM frames WHERE (session=? OR session IN
                (SELECT id FROM sessions WHERE clean=1)) AND NOT(session=? AND ref=?) ORDER BY time,rowid
                """, [.text(session), .text(session), .text(referenceToKeep ?? "")]) { row in
                if used + bytes > limit {
                    let size = Int(sqlite3_column_int64(row, 1))
                    evictions.append(sqlite3_column_double(row, 0))
                    used -= size
                }
            }
            guard used + bytes <= limit else { return false }
            for eviction in evictions {
                try database.execute("DELETE FROM frames WHERE rowid=?", [.number(eviction)])
            }
        }
        try database.execute("INSERT INTO frames(session,ref,time,bytes,png,ax) VALUES(?,?,?,?,?,?)",
                       [.text(session), .text(reference), .number(time), .number(Double(bytes)),
                        .bytes(png), snapshotData.map(DiagnosticDatabase.Value.bytes) ?? .null])
        return true
    }
}

extension DiagnosticDatabase {
    func expireFrames(_ prefs: DiagnosticPreferences, now: Double, writer: String?) throws {
        try execute("""
            DELETE FROM frames WHERE time<=? AND (session=? OR session IN (SELECT id FROM sessions WHERE clean=1))
            """, [.number(now - Double(prefs.evidenceHours) * 3600), writer.map(Value.text) ?? .null])
    }

    func expire(_ prefs: DiagnosticPreferences, now: Double) throws {
        try expireFrames(prefs, now: now, writer: nil)
        let cutoff = now - Double(prefs.historyDays) * 86400
        try execute("""
            DELETE FROM events WHERE time<=? AND session IN (SELECT id FROM sessions WHERE clean=1)
            """, [.number(cutoff)])
        try execute("""
            DELETE FROM sessions WHERE clean=1 AND closed<=? AND id NOT IN (SELECT session FROM frames)
            AND id NOT IN (SELECT session FROM events)
            """, [.number(cutoff)])
    }
}
