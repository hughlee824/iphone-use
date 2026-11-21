import Foundation
import SQLite3
import Darwin

/// Only diagnostic copies live here. The recorder never opens a device or edits a session recovery journal.
final class DiagnosticDatabase {
    let connection: OpaquePointer
    init(root: URL) throws {
        try SessionPaths.secureDirectory(root)
        let directory = root.appendingPathComponent("diagnostics")
        try SessionPaths.secureDirectory(directory)
        // Foundation can shorten /private/tmp to the /tmp symlink once a state root exists.
        // Resolve only the verified private directory. SQLite must still reject a symlink at the database itself.
        guard let canonical = realpath(directory.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(canonical) }
        let file = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent("history.sqlite3")
        try Self.prepareFile(file)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW
        let status = sqlite3_open_v2(file.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw IPhoneUseError("diagnostics_storage_error", "SQLite returned status \(status) while opening history")
        }
        connection = handle
        sqlite3_busy_timeout(handle, 500)
        try execute("PRAGMA auto_vacuum=INCREMENTAL")
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA secure_delete=ON")
        try execute("""
            CREATE TABLE IF NOT EXISTS sessions(
              id TEXT PRIMARY KEY, started REAL NOT NULL, closed REAL, clean INTEGER NOT NULL DEFAULT 0
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS events(
              seq INTEGER PRIMARY KEY, session TEXT NOT NULL, time REAL NOT NULL, json BLOB NOT NULL)
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS frames(
              session TEXT NOT NULL, ref TEXT NOT NULL, time REAL NOT NULL, bytes INTEGER NOT NULL,
              png BLOB NOT NULL, ax BLOB, context BLOB, PRIMARY KEY(session, ref))
            """)
        try execute("CREATE INDEX IF NOT EXISTS events_session ON events(session, seq)")
        try execute("CREATE INDEX IF NOT EXISTS frames_time ON frames(time)")
    }
    private static func prepareFile(_ file: URL) throws {
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor >= 0 {
            close(descriptor)
            return
        }
        guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
            info.st_mode & 0o077 == 0 else {
            throw IPhoneUseError("unsafe_diagnostic_store", "Expected a private, user-owned diagnostic database")
        }
    }

    deinit { sqlite3_close(connection) }

    static var failure: IPhoneUseError {
        IPhoneUseError("diagnostics_storage_error", "Could not read or write the local diagnostic store")
    }

    private func databaseError(_ phase: String) -> IPhoneUseError {
        let code = sqlite3_extended_errcode(connection)
        return IPhoneUseError("diagnostics_storage_error", "SQLite returned status \(code) during \(phase)")
    }

    enum Value {
        case text(String), number(Double), bytes(Data), null
    }

    func query(_ sql: String, _ values: [Value] = [], row: (OpaquePointer) throws -> Void) throws {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &raw, nil) == SQLITE_OK, let statement = raw else {
            throw databaseError("prepare")
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(statement)
            case SQLITE_DONE: return
            default: throw databaseError("step")
            }
        }
    }

    private func bind(_ values: [Value], to statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let field = Int32(index + 1)
            let status: Int32
            switch value {
            case .text(let text): status = sqlite3_bind_text(statement, field, text, -1, transient)
            case .number(let number): status = sqlite3_bind_double(statement, field, number)
            case .null: status = sqlite3_bind_null(statement, field)
            case .bytes(let bytes):
                status = bytes.withUnsafeBytes {
                    sqlite3_bind_blob64(statement, field, $0.baseAddress, UInt64($0.count), transient)
                }
            }
            guard status == SQLITE_OK else { throw databaseError("bind") }
        }
    }

    func execute(_ sql: String, _ values: [Value] = []) throws { try query(sql, values) { _ in } }

    func transaction<T>(write: Bool = true, _ body: () throws -> T) throws -> T {
        try execute(write ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    static func data(_ row: OpaquePointer, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(row, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column)))
    }
}
