import XCTest
import Foundation
import CryptoKit
import Darwin
import CSQLite
@testable import BridgeEngine

final class CodexHistoryMigrationTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var repository: URL!
    private let threadID = "11111111-1111-4111-8111-111111111111"
    private let otherThreadID = "22222222-2222-4222-8222-222222222222"
    private let updateSeconds: Int64 = 1_790_000_000
    private let updateMilliseconds: Int64 = 1_790_000_000_456
    private var rolloutPath: String { "sessions/2026/10/08/rollout-" + threadID + ".jsonl" }
    // Captured from Codex 0.160.1's own empty, synthetic state_5 database.
    private let nativeTriggers = [
        """
        CREATE TRIGGER threads_created_at_ms_after_insert
        AFTER INSERT ON threads
        WHEN NEW.created_at_ms IS NULL
        BEGIN
            UPDATE threads
            SET created_at_ms = NEW.created_at * 1000
            WHERE id = NEW.id;
        END
        """,
        """
        CREATE TRIGGER threads_created_at_ms_after_update
        AFTER UPDATE OF created_at ON threads
        WHEN NEW.created_at != OLD.created_at
         AND NEW.created_at_ms IS OLD.created_at_ms
        BEGIN
            UPDATE threads
            SET created_at_ms = NEW.created_at * 1000
            WHERE id = NEW.id;
        END
        """,
        """
        CREATE TRIGGER threads_recency_at_after_insert
        AFTER INSERT ON threads
        WHEN NEW.recency_at_ms = 0
        BEGIN
            UPDATE threads
            SET recency_at = NEW.updated_at,
                recency_at_ms = COALESCE(NEW.updated_at_ms, NEW.updated_at * 1000)
            WHERE id = NEW.id;
        END
        """,
        """
        CREATE TRIGGER threads_updated_at_ms_after_insert
        AFTER INSERT ON threads
        WHEN NEW.updated_at_ms IS NULL
        BEGIN
            UPDATE threads
            SET updated_at_ms = NEW.updated_at * 1000
            WHERE id = NEW.id;
        END
        """,
        """
        CREATE TRIGGER threads_updated_at_ms_after_update
        AFTER UPDATE OF updated_at ON threads
        WHEN NEW.updated_at != OLD.updated_at
         AND NEW.updated_at_ms IS OLD.updated_at_ms
        BEGIN
            UPDATE threads
            SET updated_at_ms = NEW.updated_at * 1000
            WHERE id = NEW.id;
        END
        """,
    ]

    override func setUpWithError() throws {
        root = try NativeFileSafety.temporaryDirectory().appendingPathComponent("miruun-migration-test-" + UUID().uuidString)
        home = root.appendingPathComponent("home")
        repository = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func write(_ path: String, data: Data, in directory: URL? = nil) throws {
        let target = (directory ?? home).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }

    @discardableResult
    private func writeRollout(in directory: URL? = nil, id: String? = nil, path: String? = nil, historyBase: Any = NSNull()) throws -> Data {
        let id = id ?? threadID
        let metadata: [String: Any] = [
            "type": "session_meta", "timestamp": "2026-10-08T01:00:00Z",
            "payload": ["id": id, "cwd": "/unchanged/project", "history_base": historyBase],
        ]
        var bytes = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        bytes.append(Data("\n{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"call_id\":\"call_synthetic\",\"arguments\":\"{\\\"cmd\\\":\\\"printf unchanged\\\"}\"}}\n{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"call_synthetic\",\"output\":\"unchanged\"}}\n{\"type\":\"compacted\",\"payload\":{\"message\":\"Existing summary — retain byte for byte\"}}\n".utf8))
        try write(path ?? rolloutPath, data: bytes, in: directory)
        return bytes
    }

    private func execute(_ sql: String, database: URL) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &connection), SQLITE_OK)
        defer { sqlite3_close_v2(connection) }
        let db = try XCTUnwrap(connection)
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        XCTAssertEqual(result, SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        guard result == SQLITE_OK else { throw NSError(domain: "MigrationTestSQLite", code: Int(result)) }
    }

    private func scalar(_ sql: String, database: URL) throws -> String {
        var connection: OpaquePointer?, statement: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement); sqlite3_close_v2(connection) }
        XCTAssertEqual(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0)))
    }

    private func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }

    private func makeState(in directory: URL? = nil, storedPath: String? = nil, storedID: String? = nil) throws {
        let source = directory ?? home!
        let path = storedPath ?? source.appendingPathComponent(rolloutPath).path
        try execute("""
            CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, history_mode TEXT, cwd TEXT, creator_account_id TEXT, updated_at INTEGER, updated_at_ms INTEGER);
            INSERT INTO threads VALUES (\(quoted(storedID ?? threadID)), \(quoted(path)), 'legacy', '/unchanged/project', 'original-creator', \(updateSeconds), \(updateMilliseconds));
            """, database: source.appendingPathComponent("state_5.sqlite"))
    }

    private func snapshot(of source: URL? = nil) throws -> CodexHistoryBackup.Snapshot {
        try CodexHistoryBackup.create(home: source ?? home, repository: repository)
    }

    private func addNativeTimestampColumns(to database: URL) throws {
        try execute("""
            ALTER TABLE threads ADD COLUMN created_at INTEGER NOT NULL DEFAULT 100;
            ALTER TABLE threads ADD COLUMN created_at_ms INTEGER;
            ALTER TABLE threads ADD COLUMN recency_at INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE threads ADD COLUMN recency_at_ms INTEGER NOT NULL DEFAULT 0;
            """, database: database)
    }

    private func assertManifest(_ snapshot: CodexHistoryBackup.Snapshot, at directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        for entry in snapshot.files {
            let data = try Data(contentsOf: directory.appendingPathComponent(entry.relativePath))
            XCTAssertEqual(Int64(data.count), entry.byteCount, entry.relativePath, file: file, line: line)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, entry.sha256, entry.relativePath, file: file, line: line)
        }
    }

    private func assertRejectedButExportable(_ snapshot: CodexHistoryBackup.Snapshot, name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let destination = root.appendingPathComponent("rejected-" + name)
        XCTAssertThrowsError(try CodexHistoryBackup.migrate(snapshot, repository: repository, destination: destination), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), file: file, line: line)
        let raw = root.appendingPathComponent("raw-" + name)
        try CodexHistoryBackup.export(snapshot, repository: repository, destination: raw)
        try assertManifest(snapshot, at: raw, file: file, line: line)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".miruun-export-") }, file: file, line: line)
    }

    func testMigrationPreservesHistoryAndMemoryWhileRelocatingLocalState() throws {
        let rollout = try writeRollout()
        let archivedPath = "archived_sessions/rollout-" + otherThreadID + ".jsonl"
        let archived = try writeRollout(id: otherThreadID, path: archivedPath)
        let memory = Data("Existing durable memory; do not regenerate.\n".utf8)
        try write("memories/MEMORY.md", data: memory)
        try write("attachments/example.bin", data: Data([0, 1, 0xff]))
        try write("auth.json", data: Data("DO_NOT_COPY_AUTH".utf8))
        try write("config.toml", data: Data("DO_NOT_COPY_CONFIG".utf8))
        try makeState()
        let state = home.appendingPathComponent("state_5.sqlite")
        try execute("INSERT INTO threads VALUES (\(quoted(otherThreadID)), \(quoted(home.appendingPathComponent(archivedPath).path)), 'legacy', '/unchanged/archive-project', 'archived-creator', \(updateSeconds), \(updateMilliseconds))", database: state)
        for name in ["remote_control_enrollments", "rollout_migration_state", "rollout_migration_skipped_rollouts"] {
            try execute("CREATE TABLE \(name)(value TEXT); INSERT INTO \(name) VALUES ('source-machine-state')", database: state)
        }
        try execute("CREATE TABLE backfill_state(status TEXT); INSERT INTO backfill_state VALUES ('complete')", database: state)
        let memoryDB = home.appendingPathComponent("memories_1.sqlite")
        try execute("""
            CREATE TABLE stage1_outputs(thread_id TEXT PRIMARY KEY, raw_memory TEXT, rollout_summary TEXT);
            INSERT INTO stage1_outputs VALUES (\(quoted(threadID)), 'raw memory', 'existing summary');
            CREATE TABLE jobs(status TEXT, worker_id TEXT, ownership_token TEXT, lease_until INTEGER, last_success_watermark INTEGER);
            INSERT INTO jobs VALUES ('done', 'old-worker', 'old-owner', 1234, 9876);
            CREATE TABLE consolidation_progress(watermark INTEGER);
            INSERT INTO consolidation_progress VALUES (7654);
            """, database: memoryDB)
        let excluded = ["goals_1.sqlite", "queue_1.sqlite"]
        for name in excluded {
            try execute("CREATE TABLE synthetic(value TEXT); INSERT INTO synthetic VALUES ('pending work')", database: home.appendingPathComponent(name))
        }
        let original = try snapshot()
        let sourceState = try Data(contentsOf: state)
        let sourceMemory = try Data(contentsOf: memoryDB)
        let sourceRolloutTime = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(rolloutPath).path)[.modificationDate] as? Date
        let destination = root.appendingPathComponent("migrated")
        try CodexHistoryBackup.migrate(original, repository: repository, destination: destination)

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(rolloutPath)), rollout)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(archivedPath)), archived)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("memories/MEMORY.md")), memory)
        let relocatedState = destination.appendingPathComponent("state_5.sqlite")
        XCTAssertEqual(try scalar("SELECT rollout_path FROM threads WHERE id = \(quoted(threadID))", database: relocatedState), destination.appendingPathComponent(rolloutPath).path)
        XCTAssertEqual(try scalar("SELECT rollout_path FROM threads WHERE id = \(quoted(otherThreadID))", database: relocatedState), destination.appendingPathComponent(archivedPath).path)
        XCTAssertEqual(try scalar("SELECT id || '|' || cwd || '|' || creator_account_id FROM threads WHERE id = \(quoted(threadID))", database: relocatedState), threadID + "|/unchanged/project|original-creator")
        for path in [rolloutPath, archivedPath] {
            let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent(path).path)[.modificationDate] as? Date)
            XCTAssertEqual(modified.timeIntervalSince1970, Double(updateMilliseconds) / 1000, accuracy: 0.000001, path)
        }
        XCTAssertEqual(try scalar("SELECT updated_at || '|' || updated_at_ms FROM threads WHERE id = \(quoted(threadID))", database: relocatedState), "\(updateSeconds)|\(updateMilliseconds)")
        XCTAssertEqual(try scalar("SELECT status FROM backfill_state", database: relocatedState), "complete")
        for name in ["remote_control_enrollments", "rollout_migration_state", "rollout_migration_skipped_rollouts"] {
            XCTAssertEqual(try scalar("SELECT count(*) FROM \(name)", database: relocatedState), "0", name)
        }
        let relocatedMemory = destination.appendingPathComponent("memories_1.sqlite")
        XCTAssertEqual(try scalar("SELECT thread_id || '|' || raw_memory || '|' || rollout_summary FROM stage1_outputs", database: relocatedMemory), threadID + "|raw memory|existing summary")
        XCTAssertEqual(try scalar("SELECT status || '|' || last_success_watermark FROM jobs", database: relocatedMemory), "done|9876")
        XCTAssertEqual(try scalar("SELECT count(*) FROM jobs WHERE worker_id IS NULL AND ownership_token IS NULL AND lease_until IS NULL", database: relocatedMemory), "1")
        XCTAssertEqual(try scalar("SELECT watermark FROM consolidation_progress", database: relocatedMemory), "7654")
        for name in excluded + ["auth.json", "config.toml"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path), name)
        }

        let published = try JSONDecoder().decode(CodexHistoryBackup.Snapshot.self, from: Data(contentsOf: destination.appendingPathComponent("miruun-backup.json")))
        XCTAssertNotEqual(published.id, original.id)
        XCTAssertEqual(published.sourceHome, destination.path)
        XCTAssertEqual(Set(published.files.map(\.relativePath)), Set(original.files.map(\.relativePath)).subtracting(excluded))
        try assertManifest(published, at: destination)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("miruun-migration.json"))) as? [String: Any])
        XCTAssertEqual(receipt["sourceSnapshotID"] as? String, original.id)
        XCTAssertEqual(receipt["migratedSnapshotID"] as? String, published.id)
        XCTAssertEqual(receipt["destinationHome"] as? String, destination.path)
        XCTAssertEqual(receipt["excludedFiles"] as? [String], excluded)
        XCTAssertEqual(receipt["modelRequests"] as? Int, 0)
        XCTAssertEqual(try Data(contentsOf: state), sourceState)
        XCTAssertEqual(try Data(contentsOf: memoryDB), sourceMemory)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(rolloutPath).path)[.modificationDate] as? Date, sourceRolloutTime)
        XCTAssertEqual(try scalar("SELECT updated_at || '|' || updated_at_ms FROM threads WHERE id = \(quoted(threadID))", database: state), "\(updateSeconds)|\(updateMilliseconds)")
        XCTAssertEqual(try CodexHistoryBackup.snapshots(home: home, repository: repository), [original])
        let raw = root.appendingPathComponent("original-export")
        try CodexHistoryBackup.export(original, repository: repository, destination: raw)
        try assertManifest(original, at: raw)
        for name in excluded { XCTAssertTrue(FileManager.default.fileExists(atPath: raw.appendingPathComponent(name).path)) }
    }

    func testLegacyRolloutsWithoutStateDatabaseCanMigrate() throws {
        let rollout = try writeRollout()
        try write("memories/MEMORY.md", data: Data("existing memory".utf8))
        let original = try snapshot()
        let destination = root.appendingPathComponent("without-state")
        try CodexHistoryBackup.migrate(original, repository: repository, destination: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(rolloutPath)), rollout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("state_5.sqlite").path))
        let published = try JSONDecoder().decode(CodexHistoryBackup.Snapshot.self, from: Data(contentsOf: destination.appendingPathComponent("miruun-backup.json")))
        try assertManifest(published, at: destination)
    }

    func testNativeTimestampTriggersAndCompletedSchemaMigrationsArePreserved() throws {
        try writeRollout()
        try makeState()
        let state = home.appendingPathComponent("state_5.sqlite")
        try addNativeTimestampColumns(to: state)
        for sql in nativeTriggers { try execute(sql, database: state) }
        try execute("CREATE TABLE _sqlx_migrations(version BIGINT PRIMARY KEY, success BOOLEAN NOT NULL); INSERT INTO _sqlx_migrations VALUES (1, 1)", database: state)
        let original = try snapshot()
        let destination = root.appendingPathComponent("native-triggers")
        try CodexHistoryBackup.migrate(original, repository: repository, destination: destination)
        let migratedState = destination.appendingPathComponent("state_5.sqlite")
        XCTAssertEqual(try scalar("SELECT rollout_path FROM threads", database: migratedState), destination.appendingPathComponent(rolloutPath).path)
        XCTAssertEqual(try scalar("SELECT count(*) FROM sqlite_master WHERE type = 'trigger'", database: migratedState), "5")
        for sql in nativeTriggers {
            let name = try XCTUnwrap(sql.split(whereSeparator: \.isWhitespace).dropFirst(2).first)
            XCTAssertEqual(try scalar("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = \(quoted(String(name)))", database: migratedState), sql)
        }
        XCTAssertEqual(try scalar("SELECT created_at || '|' || updated_at || '|' || recency_at FROM threads", database: migratedState), "100|\(updateSeconds)|0")
        XCTAssertEqual(try scalar("SELECT success FROM _sqlx_migrations WHERE version = 1", database: migratedState), "1")
    }

    func testNullMillisecondTimestampFallsBackToSeconds() throws {
        try writeRollout()
        try makeState()
        let state = home.appendingPathComponent("state_5.sqlite")
        try execute("UPDATE threads SET updated_at_ms = NULL", database: state)
        let original = try snapshot()
        let destination = root.appendingPathComponent("seconds-timestamp")
        try CodexHistoryBackup.migrate(original, repository: repository, destination: destination)
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent(rolloutPath).path)[.modificationDate] as? Date)
        XCTAssertEqual(modified.timeIntervalSince1970, Double(updateSeconds), accuracy: 0.000001)
        for database in [state, destination.appendingPathComponent("state_5.sqlite")] {
            XCTAssertEqual(try scalar("SELECT updated_at FROM threads", database: database), String(updateSeconds))
            XCTAssertEqual(try scalar("SELECT count(*) FROM threads WHERE updated_at_ms IS NULL", database: database), "1")
        }
    }

    func testInvalidThreadTimestampsDoNotPublishMigration() throws {
        for (name, seconds, milliseconds) in [
            ("text-ms", "123", "'not-a-time'"),
            ("null-seconds", "NULL", "NULL"),
            ("text-seconds", "'not-a-time'", "NULL"),
            ("negative-ms", "123", "-1"),
        ] {
            let source = home.appendingPathComponent(name)
            try writeRollout(in: source)
            try makeState(in: source)
            try execute("UPDATE threads SET updated_at = \(seconds), updated_at_ms = \(milliseconds)", database: source.appendingPathComponent("state_5.sqlite"))
            try assertRejectedButExportable(snapshot(of: source), name: name)
        }
    }

    func testUnfinishedHistoryBackfillCannotResumeInMigratedHome() throws {
        for status in ["pending", "running", "unknown", "NULL"] {
            let source = home.appendingPathComponent("backfill-" + status)
            try writeRollout(in: source)
            try makeState(in: source)
            try execute("CREATE TABLE backfill_state(status TEXT); INSERT INTO backfill_state VALUES (\(status == "NULL" ? "NULL" : quoted(status)))", database: source.appendingPathComponent("state_5.sqlite"))
            try assertRejectedButExportable(snapshot(of: source), name: "backfill-" + status)
        }
    }

    func testModifiedOrUnknownTriggersCannotRunDuringMigration() throws {
        for name in ["modified-native-trigger", "unknown-trigger"] {
            let source = home.appendingPathComponent(name)
            try writeRollout(in: source)
            try makeState(in: source)
            let state = source.appendingPathComponent("state_5.sqlite")
            try addNativeTimestampColumns(to: state)
            let trigger = name == "modified-native-trigger"
                ? nativeTriggers[0].replacingOccurrences(of: "NEW.created_at * 1000", with: "0")
                : "CREATE TRIGGER unexpected AFTER UPDATE ON threads BEGIN DELETE FROM threads; END"
            try execute(trigger, database: state)
            try assertRejectedButExportable(snapshot(of: source), name: name)
            XCTAssertEqual(try scalar("SELECT count(*) FROM threads", database: state), "1")
        }
    }

    func testUnfinishedSchemaMigrationsAreRejectedForStateAndMemory() throws {
        for databaseName in ["state_5.sqlite", "memories_1.sqlite"] {
            for success in ["0", "NULL", "2"] {
                let name = databaseName + "-migration-" + success
                let source = home.appendingPathComponent(name)
                try writeRollout(in: source)
                if databaseName == "state_5.sqlite" { try makeState(in: source) }
                try execute("CREATE TABLE _sqlx_migrations(version BIGINT PRIMARY KEY, success BOOLEAN); INSERT INTO _sqlx_migrations VALUES (1, \(success))", database: source.appendingPathComponent(databaseName))
                try assertRejectedButExportable(snapshot(of: source), name: name)
            }
        }
    }

    func testExistingNestedAndLinkedDestinationsAreRejectedWithoutOverwriting() throws {
        let rollout = try writeRollout()
        let original = try snapshot()
        let existing = root.appendingPathComponent("existing")
        let marker = Data("preserve existing files".utf8)
        try write("marker", data: marker, in: existing)
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: existing)
        for destination in [existing, home.appendingPathComponent("nested"), repository.appendingPathComponent("nested"), linked.appendingPathComponent("nested")] {
            XCTAssertThrowsError(try CodexHistoryBackup.migrate(original, repository: repository, destination: destination), destination.path)
        }
        XCTAssertEqual(try Data(contentsOf: existing.appendingPathComponent("marker")), marker)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent(rolloutPath)), rollout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: existing.appendingPathComponent("nested").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("nested").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.appendingPathComponent("nested").path))
    }

    func testCorruptBackupObjectDoesNotPublishMigration() throws {
        try writeRollout()
        let original = try snapshot()
        let entry = try XCTUnwrap(original.files.first)
        let object = repository.appendingPathComponent("objects").appendingPathComponent(entry.sha256)
        let valid = try Data(contentsOf: object)
        var corrupt = valid
        corrupt[0] ^= 0xff
        try corrupt.write(to: object)
        let destination = root.appendingPathComponent("corrupt")
        XCTAssertThrowsError(try CodexHistoryBackup.migrate(original, repository: repository, destination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".miruun-export-") })
        try valid.write(to: object)
        try CodexHistoryBackup.migrate(original, repository: repository, destination: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testUnsupportedHistoryFormatsRemainAvailableForRawExport() throws {
        for name in ["unknown-state", "unknown-memory", "unknown-table", "paginated-database", "paginated-archive", "history-base"] {
            let source = home.appendingPathComponent(name)
            try writeRollout(in: source, historyBase: name == "history-base" ? ["type": "paginated"] : NSNull())
            switch name {
            case "unknown-state":
                try execute("CREATE TABLE synthetic(value TEXT)", database: source.appendingPathComponent("state_99.sqlite"))
            case "unknown-memory":
                try execute("CREATE TABLE synthetic(value TEXT)", database: source.appendingPathComponent("memories_99.sqlite"))
            case "unknown-table":
                try makeState(in: source)
                try execute("CREATE TABLE future_table(value TEXT)", database: source.appendingPathComponent("state_5.sqlite"))
            case "paginated-database":
                try execute("CREATE TABLE synthetic(value TEXT)", database: source.appendingPathComponent("thread_history_1.sqlite"))
            case "paginated-archive":
                try write("paginated_history.jsonl.zst", data: Data([0x28, 0xb5, 0x2f, 0xfd]), in: source)
            default: break
            }
            try assertRejectedButExportable(snapshot(of: source), name: name)
        }
    }

    func testInconsistentThreadLocationsAndIDsDoNotPublishPartialCopies() throws {
        for name in ["missing-rollout", "external-rollout", "wrong-id", "paginated-mode"] {
            let source = home.appendingPathComponent(name)
            try writeRollout(in: source)
            let path: String?
            switch name {
            case "missing-rollout": path = source.appendingPathComponent("sessions/missing.jsonl").path
            case "external-rollout":
                let outside = root.appendingPathComponent("outside-rollout.jsonl")
                try writeRollout(in: root, path: outside.lastPathComponent)
                path = outside.path
            default: path = nil
            }
            try makeState(in: source, storedPath: path, storedID: name == "wrong-id" ? otherThreadID : nil)
            if name == "paginated-mode" {
                try execute("UPDATE threads SET history_mode = 'paginated'", database: source.appendingPathComponent("state_5.sqlite"))
            }
            try assertRejectedButExportable(snapshot(of: source), name: name)
        }
    }

    func testUnfinishedMemoryJobsFailClosedAndKeepOriginalBackup() throws {
        for status in ["pending", "running", "error", "NULL"] {
            let source = home.appendingPathComponent("job-" + status)
            try writeRollout(in: source)
            try execute("""
                CREATE TABLE jobs(status TEXT, worker_id TEXT, ownership_token TEXT, lease_until INTEGER, last_success_watermark INTEGER);
                INSERT INTO jobs VALUES (\(status == "NULL" ? "NULL" : quoted(status)), 'worker', 'owner', 1234, 9876);
                """, database: source.appendingPathComponent("memories_1.sqlite"))
            try assertRejectedButExportable(snapshot(of: source), name: "job-" + status)
        }
    }
}
