import Foundation
import SQLite3
import Darwin

extension DiagnosticHistory {
    public static func clean(apply: Bool) throws -> [String: Any] {
        try clean(root: root, preferences: DiagnosticPreferences.configured(), apply: apply,
                  now: Date().timeIntervalSince1970)
    }

    static func clean(root: URL, preferences: DiagnosticPreferences, apply: Bool, now: Double) throws -> [String: Any] {
        let database = try DiagnosticDatabase(root: root)
        let cutoff = now - Double(preferences.historyDays) * 86400
        let counts: [String: Int] = try database.transaction(write: apply) {
            var count: [String: Int] = [:]
            for (table, deadline) in [("events", cutoff), ("frames", now - Double(preferences.evidenceHours) * 3600)] {
                try database.query("SELECT count(*) FROM " + table
                             + " WHERE time<=? AND session IN (SELECT id FROM sessions WHERE clean=1)",
                             [.number(deadline)]) { count[table] = Int(sqlite3_column_int64($0, 0)) }
            }
            if apply { try database.expire(preferences, now: now) }
            return count
        }
        if apply { try database.execute("PRAGMA incremental_vacuum") }
        // Legacy hosts never reuse a session UUID. Only confirmed terminal sessions qualify.
        // Limit removal to the old plaintext journal. Leave locks, sockets, empty/ambiguous directories,
        // configuration, exit receipts, recovery journals and independent preview data alone.
        let files = FileManager.default
        var legacy: [String] = []
        var emptyUnverified = 0
        let directories = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for directory in directories where directory.lastPathComponent.range(
            of: #"^s[0-9a-f]{32}\z"#, options: .regularExpression) != nil {
            let name = directory.lastPathComponent
            let log = directory.appendingPathComponent("native-events.jsonl")
            if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
               (try? files.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                emptyUnverified += 1
                continue
            }
            guard regular(log), try isFinished(directory, session: name, before: cutoff) else { continue }
            if apply, unlink(log.path) != 0, errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            legacy.append(name)
        }
        return ["applied": apply, "expired": counts, "legacyActionLogs": legacy.sorted(),
                "unverifiedEmptyDirectoriesSkipped": emptyUnverified]
    }

    private static func regular(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }

    private static func isFinished(_ directory: URL, session: String, before cutoff: Double) throws -> Bool {
        let files = FileManager.default
        let attrs = try files.attributesOfItem(atPath: directory.path)
        let paths = SessionPaths(directory: directory)
        var socket = stat()
        guard attrs[.type] as? FileAttributeType == .typeDirectory, attrs[.ownerAccountID] as? Int == Int(getuid()),
            attrs[.posixPermissions] as? Int == 0o700, regular(paths.exit),
            lstat(paths.socket, &socket) == -1, errno == ENOENT,
            let data = try? Data(contentsOf: paths.exit), let exit = try? jsonObject(data),
            exit["session"] as? String == session, let ended = exit["endedAt"] as? Double, ended <= cutoff,
            let cleanup = exit["cleanup"] as? [String: Any], cleanup["shutdownAcknowledged"] as? Bool == true,
            cleanup["observationCacheRemoved"] as? Bool == true,
            cleanup["backendStopped"] as? Bool == true || cleanup["runnerProcessExited"] as? Bool == true,
            (cleanup["axAutomation"] as? [String: Any])?["cleanupPending"] as? Bool != true,
            let touch = cleanup["touchPaste"] as? [String: Any], touch["connectionsClosed"] as? Bool == true,
            touch["pasteboardRestoreAcknowledged"] as? Bool == true else { return false }
        return true
    }
}
