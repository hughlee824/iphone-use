import Foundation
import SQLite3
import Darwin

public enum DiagnosticHistory {
    static var root: URL { SessionPaths.stateRoot(environment: ProcessInfo.processInfo.environment) }

    public struct Selection {
        public let includeEvidence: Bool
        public let references: Set<String>
        public init(includeEvidence: Bool = false, references: [String] = []) {
            self.includeEvidence = includeEvidence || !references.isEmpty
            self.references = Set(references)
        }
    }

    public static func export(session: String?, destination: URL, selection: Selection) throws -> [String: Any] {
        let database = try DiagnosticDatabase(root: root)
        let prefs = try DiagnosticPreferences.configured()
        return try export(database: database, preferences: prefs, session: session, destination: destination,
                          selection: selection)
    }

    static func export(database: DiagnosticDatabase, preferences: DiagnosticPreferences, session: String?,
                       destination: URL, selection: Selection) throws -> [String: Any] {
        let now = Date().timeIntervalSince1970
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path,
                                             isDirectory: &isDirectory), isDirectory.boolValue else {
            throw IPhoneUseError("diagnostics_destination", "Choose an existing output directory")
        }
        // Stage on the destination filesystem. Publish a complete archive once, without overwriting an existing file.
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".iphone-use-" + UUID().uuidString)
        try SessionPaths.secureDirectory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        let bundle = stage.appendingPathComponent("diagnostics")
        try SessionPaths.secureDirectory(bundle)
        let manifest = try database.transaction(write: false) {
            var selected: String?
            try database.query("SELECT id FROM sessions WHERE (? IS NULL OR id=?) ORDER BY started DESC LIMIT 1",
                         [session.map(DiagnosticDatabase.Value.text) ?? .null,
                          session.map(DiagnosticDatabase.Value.text) ?? .null]) {
                selected = String(cString: sqlite3_column_text($0, 0))
            }
            guard let selected else { throw IPhoneUseError("diagnostics_not_found", "No matching diagnostic session") }
            let events = try writeTimeline(database, selected, after: now - Double(preferences.historyDays) * 86400,
                                           directory: bundle)
            let frames = try writeFrames(database, selected, after: now - Double(preferences.evidenceHours) * 3600,
                                         directory: bundle, selection: selection)
            let facts: [String: Any] = ["version": 1, "session": selected, "events": events,
                                        "includesEvidence": selection.includeEvidence, "availableFrames": frames]
            try saveJSON(facts, to: bundle.appendingPathComponent("manifest.json"))
            return facts
        }
        let archive = stage.appendingPathComponent("bundle.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", bundle.path, archive.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw IPhoneUseError("diagnostics_archive_failed", "ZIP writer exit status: \(process.terminationStatus)")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        guard link(archive.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return manifest.merging(["archive": destination.path]) { first, _ in first }
    }

    private static func writeTimeline(_ database: DiagnosticDatabase, _ session: String, after: Double,
                                      directory: URL) throws -> Int {
        let path = directory.appendingPathComponent("timeline.jsonl")
        guard FileManager.default.createFile(atPath: path.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw IPhoneUseError("diagnostics_export_failed", "Could not create timeline file")
        }
        let file = try FileHandle(forWritingTo: path)
        defer { try? file.close() }
        var count = 0
        try database.query("SELECT json FROM events WHERE session=? AND time>? ORDER BY seq",
                     [.text(session), .number(after)]) { row in
            guard var data = DiagnosticDatabase.data(row, 0) else { throw DiagnosticDatabase.failure }
            data.append(10)
            try file.write(contentsOf: data)
            count += 1
        }
        return count
    }

    private static func writeFrames(_ database: DiagnosticDatabase, _ session: String, after: Double,
                                    directory: URL, selection: Selection) throws -> [[String: Any]] {
        var frames: [[String: Any]] = []
        let columns = selection.includeEvidence ? "png,ax" : "NULL,NULL"
        try database.query("SELECT ref,ax IS NOT NULL,context," + columns
                     + " FROM frames WHERE session=? AND time>? ORDER BY time,rowid",
                     [.text(session), .number(after)]) { row in
            let ref = String(cString: sqlite3_column_text(row, 0))
            guard ref.range(of: #"^(o[1-9][0-9]*|guard-[A-F0-9-]{36})\z"#, options: .regularExpression) != nil
            else { throw DiagnosticDatabase.failure }
            var frame = try DiagnosticDatabase.data(row, 2).map(jsonObject) ?? [:]
            frame["ref"] = ref
            frame["hasAX"] = sqlite3_column_int(row, 1) == 1
            if selection.includeEvidence && (selection.references.isEmpty || selection.references.contains(ref)),
                let png = DiagnosticDatabase.data(row, 3) {
                frame["included"] = true
                let folder = directory.appendingPathComponent(ref)
                try SessionPaths.secureDirectory(folder)
                try png.write(to: folder.appendingPathComponent("screen.png"))
                try DiagnosticDatabase.data(row, 4)?.write(to: folder.appendingPathComponent("ax.json"))
            }
            frames.append(frame)
        }
        let available = Set(frames.compactMap { $0["ref"] as? String })
        guard selection.references.isSubset(of: available) else {
            throw IPhoneUseError("diagnostics_frame_unavailable", "One or more selected frames are unavailable")
        }
        return frames
    }
}
