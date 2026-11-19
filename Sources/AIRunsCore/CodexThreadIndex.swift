import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// A Codex thread as the Codex app and CLI list it.
public struct CodexThread: Equatable, Sendable {
    public var id: String
    /// The name the Codex sidebar shows (`threads.name`). Nil when unnamed.
    public var name: String?
    /// `user`, `voice_chat` or `agent_created_thread` for user conversations;
    /// `subagent`, `guardian_review` and others for Codex's own helpers.
    public var threadSource: String?
    public var archived: Bool

    public init(id: String, name: String?, threadSource: String?, archived: Bool) {
        self.id = id
        self.name = name
        self.threadSource = threadSource
        self.archived = archived
    }

    /// User conversations that older source filters mistook for internal helpers.
    /// Share this decision with startup recovery so it cannot diverge again.
    public var wasMisclassifiedAsInternal: Bool {
        guard let source = threadSource?.lowercased() else { return false }
        return source == "voice_chat" || source == "agent_created_thread"
    }

    /// Codex's own helper threads: naming, reviews, subagents. Rows without a
    /// source are older user threads.
    public var isInternal: Bool {
        guard let source = threadSource?.lowercased(), !source.isEmpty else { return false }
        return source != "user" && !wasMisclassifiedAsInternal
    }
}

/// Reads thread names and kinds from `~/.codex/state_5.sqlite`, read-only.
/// It is Codex's private database, not an API: any surprise yields nil.
public enum CodexThreadIndex {
    public static func database(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".codex/state_5.sqlite")
    }

    public static func thread(id: String, database: URL) -> CodexThread? {
        #if canImport(SQLite3)
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let sql = "SELECT id, name, thread_source, archived FROM threads WHERE id = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            let value = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return CodexThread(id: text(0) ?? id, name: text(1), threadSource: text(2),
                           archived: sqlite3_column_int(statement, 3) != 0)
        #else
        return nil
        #endif
    }
}
