import Foundation
import Darwin
import CSQLite

/// Rewrites only a verified, private copy. The caller publishes it after this succeeds.
enum CodexHistoryMigration {
    enum Failure: Error, LocalizedError {
        case unsupportedFormat(String)
        case invalidSession(String)
        case invalidDatabase(String)
        case unfinishedMemoryJobs
        case unfinishedHistoryBackfill
        case rollbackFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let path):
                return "暂不支持迁移此聊天或数据库格式：\(path)。备份仍可原样导出"
            case .invalidSession(let path):
                return "聊天首记录、线程 ID 或路径无效：\(path)，已停止迁移"
            case .invalidDatabase(let name):
                return "数据库结构、内容或完整性检查失败：\(name)，已停止迁移"
            case .unfinishedMemoryJobs:
                return "记忆数据库包含未完成或未知状态的任务。备份仍可原样导出；请先完成或处理旧记忆任务，再重新备份"
            case .unfinishedHistoryBackfill:
                return "聊天索引仍在回填或状态未知。备份仍可原样导出；请等待 Codex 完成索引后重新备份"
            case .rollbackFailed:
                return "迁移副本的数据库回滚失败，已停止；不能发布此副本"
            }
        }
    }

    private static let stateTables: Set<String> = [
        "_sqlx_migrations", "backfill_state", "external_agent_config_imports",
        "project_idempotency_keys", "project_roots", "projects", "remote_control_enrollments",
        "rollout_migration_skipped_rollouts", "rollout_migration_state", "sqlite_sequence",
        "thread_attachments", "thread_dynamic_tools", "thread_sections", "thread_spawn_edges", "threads"
    ]
    private static let memoryTables: Set<String> = [
        "_sqlx_migrations", "consolidation_progress", "jobs", "stage1_outputs"
    ]
    // Codex 0.160.1 timestamp triggers are retained for future native writes.
    // Match their bodies too: a familiar name alone does not make a trigger safe.
    private static let stateTriggers: [String: String] = [
        "threads_created_at_ms_after_insert": """
            CREATE TRIGGER threads_created_at_ms_after_insert
            AFTER INSERT ON threads WHEN NEW.created_at_ms IS NULL
            BEGIN UPDATE threads SET created_at_ms = NEW.created_at * 1000 WHERE id = NEW.id; END
            """,
        "threads_updated_at_ms_after_insert": """
            CREATE TRIGGER threads_updated_at_ms_after_insert
            AFTER INSERT ON threads WHEN NEW.updated_at_ms IS NULL
            BEGIN UPDATE threads SET updated_at_ms = NEW.updated_at * 1000 WHERE id = NEW.id; END
            """,
        "threads_created_at_ms_after_update": """
            CREATE TRIGGER threads_created_at_ms_after_update
            AFTER UPDATE OF created_at ON threads
            WHEN NEW.created_at != OLD.created_at AND NEW.created_at_ms IS OLD.created_at_ms
            BEGIN UPDATE threads SET created_at_ms = NEW.created_at * 1000 WHERE id = NEW.id; END
            """,
        "threads_updated_at_ms_after_update": """
            CREATE TRIGGER threads_updated_at_ms_after_update
            AFTER UPDATE OF updated_at ON threads
            WHEN NEW.updated_at != OLD.updated_at AND NEW.updated_at_ms IS OLD.updated_at_ms
            BEGIN UPDATE threads SET updated_at_ms = NEW.updated_at * 1000 WHERE id = NEW.id; END
            """,
        "threads_recency_at_after_insert": """
            CREATE TRIGGER threads_recency_at_after_insert
            AFTER INSERT ON threads WHEN NEW.recency_at_ms = 0
            BEGIN UPDATE threads SET recency_at = NEW.updated_at,
            recency_at_ms = COALESCE(NEW.updated_at_ms, NEW.updated_at * 1000) WHERE id = NEW.id; END
            """
    ]

    static func prepare(staging: URL, snapshot: CodexHistoryBackup.Snapshot,
                        destination: URL) throws -> [String] {
        var sessionIDs: [String: String] = [:]
        var removed: [String] = []
        let paths = Set(snapshot.files.map(\.relativePath))
        for entry in snapshot.files {
            let path = entry.relativePath
            if isSession(path) {
                guard path.hasSuffix(".jsonl") else { throw Failure.unsupportedFormat(path) }
                sessionIDs[path] = try sessionID(staging.appendingPathComponent(path), path: path)
            } else if path == "paginated_history.jsonl.zst" {
                throw Failure.unsupportedFormat(path)
            } else if !path.contains("/"), path.hasSuffix(".sqlite") {
                if versionedDatabase(path, prefix: "queue_") || versionedDatabase(path, prefix: "goals_") {
                    removed.append(path)
                } else if path != "state_5.sqlite" && path != "memories_1.sqlite" {
                    throw Failure.unsupportedFormat(path)
                }
            }
        }
        if paths.contains("state_5.sqlite") {
            try withDatabase(staging.appendingPathComponent("state_5.sqlite")) { database in
                let tables = try validateSchema(database, allowed: stateTables, triggers: stateTriggers, name: "state_5.sqlite")
                guard tables.contains("threads") else { throw Failure.invalidDatabase("state_5.sqlite") }
                if tables.contains("backfill_state") {
                    try query(database, sql: "SELECT status FROM backfill_state") { statement in
                        guard string(statement, column: 0) == "complete" else { throw Failure.unfinishedHistoryBackfill }
                    }
                }
                let columns = try columnNames(database, sql: "PRAGMA table_info(threads)")
                guard columns.isSuperset(of: ["id", "rollout_path", "updated_at"]) else {
                    throw Failure.invalidDatabase("state_5.sqlite")
                }
                let mode = columns.contains("history_mode") ? "history_mode" : "'legacy'"
                let millis = columns.contains("updated_at_ms") ? "updated_at_ms" : "NULL"
                let sql = "SELECT id, rollout_path, \(mode), updated_at, \(millis) FROM threads"
                var rollouts: [(id: String, relativePath: String, updatedAt: Int64)] = []
                try query(database, sql: sql) { statement in
                    guard let id = string(statement, column: 0),
                          let oldPath = string(statement, column: 1) else {
                        throw Failure.invalidDatabase("state_5.sqlite")
                    }
                    guard string(statement, column: 2) == "legacy" else {
                        throw Failure.unsupportedFormat("threads.history_mode")
                    }
                    let path = try relativeRollout(oldPath, home: snapshot.sourceHome)
                    guard paths.contains(path), sessionIDs[path] == id else {
                        throw Failure.invalidSession(path)
                    }
                    let updatedAt: Int64
                    if sqlite3_column_type(statement, 4) == SQLITE_NULL {
                        guard sqlite3_column_type(statement, 3) == SQLITE_INTEGER else {
                            throw Failure.invalidDatabase("threads.updated_at")
                        }
                        let (value, overflow) = sqlite3_column_int64(statement, 3).multipliedReportingOverflow(by: 1000)
                        guard !overflow else { throw Failure.invalidDatabase("threads.updated_at") }
                        updatedAt = value
                    } else {
                        guard sqlite3_column_type(statement, 4) == SQLITE_INTEGER else {
                            throw Failure.invalidDatabase("threads.updated_at_ms")
                        }
                        updatedAt = sqlite3_column_int64(statement, 4)
                    }
                    guard updatedAt >= 0 else { throw Failure.invalidDatabase("threads.updated_at") }
                    rollouts.append((id, path, updatedAt))
                }
                for rollout in rollouts {
                    try query(database, sql: "UPDATE threads SET rollout_path = ? WHERE id = ?",
                              bindings: [destination.appendingPathComponent(rollout.relativePath).path, rollout.id]) { _ in }
                    guard sqlite3_changes(database) == 1 else {
                        throw Failure.invalidDatabase("state_5.sqlite")
                    }
                    try restoreModificationTime(staging.appendingPathComponent(rollout.relativePath), milliseconds: rollout.updatedAt)
                }
                // Backfill's watermark is relative to CODEX_HOME. Preserve it and
                // completed status: forcing a rescan can reset DB-only memory policy.
                for (table, sql) in [
                    ("remote_control_enrollments", "DELETE FROM remote_control_enrollments"),
                    ("rollout_migration_state", "DELETE FROM rollout_migration_state"),
                    ("rollout_migration_skipped_rollouts", "DELETE FROM rollout_migration_skipped_rollouts")
                ] where tables.contains(table) {
                    try execute(database, sql: sql)
                }
            }
        }
        if paths.contains("memories_1.sqlite") {
            try withDatabase(staging.appendingPathComponent("memories_1.sqlite")) { database in
                let tables = try validateSchema(database, allowed: memoryTables, name: "memories_1.sqlite")
                if tables.contains("jobs") {
                    let columns = try columnNames(database, sql: "PRAGMA table_info(jobs)")
                    guard columns.isSuperset(of: ["status", "worker_id", "ownership_token", "lease_until",
                                                  "last_success_watermark"]) else {
                        throw Failure.invalidDatabase("memories_1.sqlite")
                    }
                    try query(database, sql: "SELECT status FROM jobs") { statement in
                        guard string(statement, column: 0) == "done" else { throw Failure.unfinishedMemoryJobs }
                    }
                    // Preserve success watermarks and outputs: deleting jobs loses deduplication.
                    // Unfinished jobs cannot safely be cancelled using retry_remaining alone.
                    try execute(database, sql: "UPDATE jobs SET worker_id = NULL, ownership_token = NULL, lease_until = NULL")
                }
            }
        }
        for path in removed { try FileManager.default.removeItem(at: staging.appendingPathComponent(path)) }
        return removed.sorted()
    }

    private static func isSession(_ path: String) -> Bool {
        path.hasPrefix("sessions/") || path.hasPrefix("archived_sessions/")
    }

    private static func versionedDatabase(_ path: String, prefix: String) -> Bool {
        guard path.hasPrefix(prefix), path.hasSuffix(".sqlite") else { return false }
        let version = path.dropFirst(prefix.count).dropLast(".sqlite".count)
        return !version.isEmpty && version.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func relativeRollout(_ path: String, home: String) throws -> String {
        let prefix = home == "/" ? "/" : home + "/"
        guard path.hasPrefix(prefix), !path.contains("\0") else { throw Failure.invalidSession(path) }
        let relative = String(path.dropFirst(prefix.count))
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard isSession(relative), relative.hasSuffix(".jsonl"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Failure.invalidSession(path)
        }
        return relative
    }

    /// Read only the first record; large rollouts must not be loaded into memory.
    private static func sessionID(_ url: URL, path: String) throws -> String {
        try NativeFileSafety.noSymlinks(url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.invalidSession(path) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1 else { throw Failure.invalidSession(path) }
        let limit = 1_048_576
        var record = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure.invalidSession(path) }
            if count == 0 { break }
            let end = buffer.prefix(count).firstIndex(of: 10) ?? count
            guard record.count <= limit - end else { throw Failure.invalidSession(path) }
            record.append(contentsOf: buffer.prefix(end))
            if end < count { break }
        }
        guard let metadata = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
              metadata["type"] as? String == "session_meta",
              let payload = metadata["payload"] as? [String: Any],
              let id = payload["id"] as? String,
              let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id.lowercased() else {
            throw Failure.invalidSession(path)
        }
        if let historyBase = payload["history_base"], !(historyBase is NSNull) {
            throw Failure.unsupportedFormat(path + ": session_meta.history_base")
        }
        return id
    }

    private static func validateSchema(_ database: OpaquePointer, allowed: Set<String>, triggers: [String: String] = [:],
                                       name: String) throws -> Set<String> {
        var tables: Set<String> = []
        try query(database, sql: "SELECT type, name, sql FROM sqlite_master WHERE type IN ('table', 'view', 'trigger')") { statement in
            guard let type = string(statement, column: 0), let table = string(statement, column: 1),
                  let sql = string(statement, column: 2) else { throw Failure.invalidDatabase(name) }
            if type == "trigger", let expected = triggers[table], normalizedSQL(sql) == normalizedSQL(expected) {
                return
            }
            guard type == "table", allowed.contains(table), sql.uppercased().hasPrefix("CREATE TABLE ") else {
                throw Failure.invalidDatabase(name)
            }
            tables.insert(table)
        }
        if tables.contains("_sqlx_migrations") {
            try query(database, sql: "SELECT success FROM _sqlx_migrations") { statement in
                guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER, sqlite3_column_int(statement, 0) == 1 else {
                    throw Failure.invalidDatabase(name)
                }
            }
        }
        return tables
    }

    private static func normalizedSQL(_ sql: String) -> String {
        sql.split(whereSeparator: \.isWhitespace).joined(separator: " ").uppercased()
    }

    private static func restoreModificationTime(_ url: URL, milliseconds: Int64) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.invalidSession(url.lastPathComponent) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw Failure.invalidSession(url.lastPathComponent)
        }
        // Native legacy indexing derives updated_at from the rollout's mtime.
        // A freshly copied mtime would also invalidate existing memory watermarks.
        var times = [info.st_atimespec, timespec(tv_sec: Int(milliseconds / 1000), tv_nsec: Int(milliseconds % 1000) * 1_000_000)]
        guard futimens(descriptor, &times) == 0 else { throw Failure.invalidSession(url.lastPathComponent) }
    }

    private static func columnNames(_ database: OpaquePointer, sql: String) throws -> Set<String> {
        var columns: Set<String> = []
        try query(database, sql: sql) { statement in
            guard let column = string(statement, column: 1) else { throw Failure.invalidDatabase("列定义") }
            columns.insert(column)
        }
        return columns
    }

    private static func withDatabase(_ url: URL, body: (OpaquePointer) throws -> Void) throws {
        try NativeFileSafety.noSymlinks(url)
        let name = url.lastPathComponent
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw Failure.invalidDatabase(name)
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            var sidecar = stat()
            guard lstat(url.path + suffix, &sidecar) != 0, errno == ENOENT else {
                throw Failure.invalidDatabase(name)
            }
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let database = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw Failure.invalidDatabase(name)
        }
        var closed = false
        defer { if !closed { sqlite3_close_v2(database) } }
        try execute(database, sql: "PRAGMA trusted_schema=OFF")
        try execute(database, sql: "PRAGMA locking_mode=EXCLUSIVE")
        try query(database, sql: "PRAGMA journal_mode") { statement in
            guard string(statement, column: 0) == "delete" else { throw Failure.invalidDatabase(name) }
        }
        try integrity(database, name: name)
        try execute(database, sql: "BEGIN IMMEDIATE")
        do {
            try body(database)
            try integrity(database, name: name)
            try execute(database, sql: "COMMIT")
        } catch {
            guard sqlite3_exec(database, "ROLLBACK", nil, nil, nil) == SQLITE_OK else {
                throw Failure.rollbackFailed
            }
            throw error
        }
        guard sqlite3_close(database) == SQLITE_OK else { throw Failure.invalidDatabase(name) }
        closed = true
    }

    private static func integrity(_ database: OpaquePointer, name: String) throws {
        var count = 0
        try query(database, sql: "PRAGMA integrity_check") { statement in
            guard string(statement, column: 0) == "ok" else { throw Failure.invalidDatabase(name) }
            count += 1
        }
        guard count == 1 else { throw Failure.invalidDatabase(name) }
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure.invalidDatabase("SQLite 操作")
        }
    }

    private static func query(_ database: OpaquePointer, sql: String, bindings: [String] = [],
                              row: (OpaquePointer) throws -> Void) throws {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &handle, nil) == SQLITE_OK, let statement = handle else {
            if let handle { sqlite3_finalize(handle) }
            throw Failure.invalidDatabase("SQLite 语句")
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            guard !value.contains("\0"), value.withCString({
                sqlite3_bind_text(statement, Int32(index + 1), $0, -1,
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }) == SQLITE_OK else { throw Failure.invalidDatabase("SQLite 参数") }
        }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw Failure.invalidDatabase("SQLite 结果") }
            try row(statement)
        }
    }

    private static func string(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard let value = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8),
              !value.contains("\0") else { return nil }
        return value
    }
}
