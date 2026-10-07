import XCTest
import Foundation
import Darwin
import CSQLite
@testable import BridgeEngine

final class CodexHistoryBackupTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var repository: URL!

    override func setUpWithError() throws {
        root = try NativeFileSafety.temporaryDirectory().appendingPathComponent("miruun-history-test-" + UUID().uuidString)
        home = root.appendingPathComponent("home")
        repository = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try write("history.jsonl", data: Data("{\"text\":\"first conversation\"}\n".utf8))
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func write(_ relativePath: String, data: Data, in directory: URL? = nil) throws {
        let destination = (directory ?? home).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
    }

    private func create() throws -> CodexHistoryBackup.Snapshot {
        try CodexHistoryBackup.create(home: home, repository: repository)
    }

    private func history() throws -> [CodexHistoryBackup.Snapshot] {
        try CodexHistoryBackup.snapshots(home: home, repository: repository)
    }

    private func export(_ snapshot: CodexHistoryBackup.Snapshot, name: String) throws -> URL {
        let destination = root.appendingPathComponent(name)
        try CodexHistoryBackup.export(snapshot, repository: repository, destination: destination)
        return destination
    }

    private func manifestURL(for snapshot: CodexHistoryBackup.Snapshot) throws -> URL {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: repository.appendingPathComponent("snapshots"), includingPropertiesForKeys: nil))
        return try XCTUnwrap(enumerator.compactMap { $0 as? URL }.first { $0.lastPathComponent == snapshot.id + ".json" })
    }

    private func rewriteManifest(_ snapshot: CodexHistoryBackup.Snapshot, edit: (inout [String: Any]) -> Void) throws {
        let manifest = try manifestURL(for: snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        edit(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: manifest)
    }

    private func objectNames() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: repository.appendingPathComponent("objects").path))
    }

    private func scalar(_ sql: String, database: URL) throws -> String {
        var connection: OpaquePointer?, statement: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement); sqlite3_close_v2(connection) }
        XCTAssertEqual(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0)))
    }

    func testAllSupportedHistoryAndMemoryFilesRoundTripWithoutCredentials() throws {
        let files: [String: Data] = [
            "history.jsonl": Data("{\"text\":\"first conversation\"}\n".utf8),
            "session_index.jsonl": Data("{\"id\":\"synthetic\"}\n".utf8),
            "paginated_history.jsonl.zst": Data([0x28, 0xb5, 0x2f, 0xfd, 0, 1, 2]),
            "AGENTS.md": Data("记忆中的偏好\n".utf8),
            "sessions/2026/10/07/rollout-synthetic.jsonl": Data("{\"type\":\"session_meta\"}\n".utf8),
            "archived_sessions/archived.jsonl": Data("archived conversation\n".utf8),
            "memories/MEMORY.md": Data("durable memory\n".utf8),
            "memories/skills/example/SKILL.md": Data("nested skill\n".utf8),
            "memories_v2/rollout_summaries/summary.md": Data("another memory format\n".utf8),
            "attachments/会话/file.bin": Data([0, 1, 2, 0xff, 0x7f]),
        ]
        for (path, data) in files { try write(path, data: data) }
        try write("auth.json", data: Data("DO_NOT_COPY_CREDENTIALS".utf8))
        try write("config.toml", data: Data("DO_NOT_COPY_CONFIG".utf8))
        try write("logs/private.log", data: Data("DO_NOT_COPY_LOGS".utf8))
        try write("unrelated.sqlite", data: Data("not a selected database".utf8))

        let snapshot = try create()
        XCTAssertEqual(snapshot.sourceHome, home.path)
        XCTAssertEqual(Set(snapshot.files.map(\.relativePath)), Set(files.keys))
        XCTAssertEqual(try history(), [snapshot])
        let destination = try export(snapshot, name: "exported")
        for (path, expected) in files {
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(path)), expected, path)
            XCTAssertEqual(snapshot.files.first { $0.relativePath == path }?.byteCount, Int64(expected.count))
        }
        for path in ["auth.json", "config.toml", "logs", "unrelated.sqlite"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(path).path), path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("miruun-backup.json").path))
    }

    func testSnapshotsObjectsAndExportsHavePrivatePermissions() throws {
        try write("sessions/nested/rollout.jsonl", data: Data("private conversation".utf8))
        let snapshot = try create()
        let destination = try export(snapshot, name: "exported")
        for directory in [repository!, destination] {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
            for url in [directory] + enumerator.compactMap({ $0 as? URL }) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let expected = attributes[.type] as? FileAttributeType == .typeDirectory ? 0o700 : 0o600
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, expected, url.lastPathComponent)
            }
        }
    }

    func testUnchangedFilesReuseVersionAndObjects() throws {
        let bytes = try Data(contentsOf: home.appendingPathComponent("history.jsonl"))
        try write("sessions/same-content.jsonl", data: bytes)
        let first = try create()
        let objects = try objectNames()
        let second = try create()
        XCTAssertEqual(first, second)
        XCTAssertEqual(try history(), [first])
        XCTAssertEqual(try objectNames(), objects)
        XCTAssertEqual(objects.count, 1, "Two identical files should share one stored object")
    }

    func testChangedAndDeletedFilesPreserveEarlierVersions() throws {
        let original = try Data(contentsOf: home.appendingPathComponent("history.jsonl"))
        try write("memories/MEMORY.md", data: Data("old memory".utf8))
        let first = try create()
        let changed = Data("new conversation\n".utf8)
        try write("history.jsonl", data: changed)
        try FileManager.default.removeItem(at: home.appendingPathComponent("memories/MEMORY.md"))
        let second = try create()
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try history().map(\.id), [second.id, first.id])
        let before = try export(first, name: "before")
        let after = try export(second, name: "after")
        XCTAssertEqual(try Data(contentsOf: before.appendingPathComponent("history.jsonl")), original)
        XCTAssertEqual(try Data(contentsOf: before.appendingPathComponent("memories/MEMORY.md")), Data("old memory".utf8))
        XCTAssertEqual(try Data(contentsOf: after.appendingPathComponent("history.jsonl")), changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: after.appendingPathComponent("memories/MEMORY.md").path))
    }

    func testDifferentHomesKeepSeparateVersionHistories() throws {
        let otherHome = root.appendingPathComponent("other-home")
        try write("history.jsonl", data: Data("other home".utf8), in: otherHome)
        let first = try create()
        let second = try CodexHistoryBackup.create(home: otherHome, repository: repository)
        XCTAssertNotEqual(first.sourceHome, second.sourceHome)
        XCTAssertEqual(try history(), [first])
        XCTAssertEqual(try CodexHistoryBackup.snapshots(home: otherHome, repository: repository), [second])
    }

    func testSQLiteBackupIncludesCommittedWALAndLeavesSourceBytesUntouched() throws {
        let source = home.appendingPathComponent("state_5.sqlite")
        var live: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &live), SQLITE_OK)
        defer { sqlite3_close_v2(live) }
        XCTAssertEqual(sqlite3_exec(live, "CREATE TABLE synthetic(value TEXT); INSERT INTO synthetic VALUES ('base'); PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO synthetic VALUES ('committed-wal')", nil, nil, nil), SQLITE_OK)
        let wal = home.appendingPathComponent("state_5.sqlite-wal")
        let sourceBefore = try Data(contentsOf: source)
        let walBefore = try Data(contentsOf: wal)
        let permissionsBefore = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber
        let snapshot = try create()
        XCTAssertEqual(try create(), snapshot, "Unchanged SQLite WAL content should reuse its version")
        XCTAssertEqual(Set(snapshot.files.map(\.relativePath)), ["history.jsonl", "state_5.sqlite"])
        let destination = try export(snapshot, name: "exported")
        XCTAssertEqual(try scalar("SELECT group_concat(value, ',') FROM synthetic", database: destination.appendingPathComponent("state_5.sqlite")), "base,committed-wal")
        XCTAssertEqual(try scalar("PRAGMA journal_mode", database: destination.appendingPathComponent("state_5.sqlite")), "delete")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("state_5.sqlite-wal").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("state_5.sqlite-shm").path))
        XCTAssertEqual(try Data(contentsOf: source), sourceBefore)
        XCTAssertEqual(try Data(contentsOf: wal), walBefore)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber, permissionsBefore)
    }

    func testEverySupportedSQLiteFamilyIsIncludedAndReadable() throws {
        let names = ["state_5.sqlite", "memories_1.sqlite", "memories_v2_2.sqlite", "thread_history_1.sqlite", "goals_1.sqlite", "queue_1.sqlite"]
        for name in names {
            var connection: OpaquePointer?
            XCTAssertEqual(sqlite3_open(home.appendingPathComponent(name).path, &connection), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(connection, "CREATE TABLE synthetic(value TEXT); INSERT INTO synthetic VALUES ('saved')", nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_close_v2(connection), SQLITE_OK)
        }
        let snapshot = try create()
        XCTAssertEqual(Set(snapshot.files.map(\.relativePath)), Set(names + ["history.jsonl"]))
        let destination = try export(snapshot, name: "exported")
        for name in names { XCTAssertEqual(try scalar("SELECT value FROM synthetic", database: destination.appendingPathComponent(name)), "saved") }
    }

    func testSymlinkedHistoryFileIsRejectedWithoutPublishingVersion() throws {
        let source = home.appendingPathComponent("history.jsonl")
        let outside = root.appendingPathComponent("outside.jsonl")
        try FileManager.default.moveItem(at: source, to: outside)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        XCTAssertThrowsError(try create())
        XCTAssertEqual(try history(), [])
        XCTAssertEqual(try Data(contentsOf: outside), Data("{\"text\":\"first conversation\"}\n".utf8))
    }

    func testSymlinkedHistoryDirectoryIsRejected() throws {
        let outside = root.appendingPathComponent("outside")
        try write("rollout.jsonl", data: Data("outside data".utf8), in: outside)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("sessions"), withDestinationURL: outside)
        XCTAssertThrowsError(try create())
        XCTAssertEqual(try history(), [])
    }

    func testHardlinkedHistoryFileIsRejectedWithoutChangingPermissions() throws {
        let source = home.appendingPathComponent("history.jsonl")
        let alias = root.appendingPathComponent("outside-alias.jsonl")
        XCTAssertEqual(chmod(source.path, 0o640), 0)
        XCTAssertEqual(link(source.path, alias.path), 0)
        XCTAssertThrowsError(try create())
        XCTAssertEqual(try history(), [])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: alias.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }

    func testFIFOIsRejectedWithoutWaitingForWriter() throws {
        try FileManager.default.removeItem(at: home.appendingPathComponent("history.jsonl"))
        XCTAssertEqual(mkfifo(home.appendingPathComponent("history.jsonl").path, 0o600), 0)
        XCTAssertThrowsError(try create())
        XCTAssertEqual(try history(), [])
    }

    func testInvalidSQLiteDoesNotPublishPartialVersion() throws {
        try write("state_5.sqlite", data: Data("not a sqlite database".utf8))
        XCTAssertThrowsError(try create())
        XCTAssertEqual(try history(), [])
    }

    func testRepositoryCannotBeInsideSourceOrUseSymlinkAncestor() throws {
        XCTAssertThrowsError(try CodexHistoryBackup.create(home: home, repository: home.appendingPathComponent("backups")))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)
        XCTAssertThrowsError(try CodexHistoryBackup.create(home: alias, repository: repository))
        XCTAssertThrowsError(try CodexHistoryBackup.create(home: home, repository: alias.appendingPathComponent("backups")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("backups").path))
    }

    func testExportRejectsExistingOrNestedDestination() throws {
        let snapshot = try create()
        let destination = root.appendingPathComponent("existing")
        try write("marker.txt", data: Data("preserve me".utf8), in: destination)
        XCTAssertThrowsError(try CodexHistoryBackup.export(snapshot, repository: repository, destination: destination))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("marker.txt")), Data("preserve me".utf8))
        XCTAssertThrowsError(try CodexHistoryBackup.export(snapshot, repository: repository, destination: home.appendingPathComponent("restored")))
        XCTAssertThrowsError(try CodexHistoryBackup.export(snapshot, repository: repository, destination: repository.appendingPathComponent("restored")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("restored").path))
    }

    func testManifestPathTraversalIsRejected() throws {
        let snapshot = try create()
        try rewriteManifest(snapshot) { object in
            var entries = object["files"] as! [[String: Any]]
            entries[0]["relativePath"] = "../escaped.jsonl"
            object["files"] = entries
        }
        XCTAssertThrowsError(try history())
        XCTAssertThrowsError(try export(snapshot, name: "exported"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("exported").path))
    }

    func testManifestObjectPathTraversalIsRejected() throws {
        let snapshot = try create()
        try rewriteManifest(snapshot) { object in
            var entries = object["files"] as! [[String: Any]]
            entries[0]["sha256"] = "../../home/auth.json"
            object["files"] = entries
        }
        XCTAssertThrowsError(try history())
        XCTAssertThrowsError(try export(snapshot, name: "exported"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("exported").path))
    }

    func testCorruptedObjectFailsExportBeforeDestinationIsPublished() throws {
        let snapshot = try create()
        let entry = try XCTUnwrap(snapshot.files.first)
        let object = repository.appendingPathComponent("objects").appendingPathComponent(entry.sha256)
        try Data(repeating: 0x78, count: Int(entry.byteCount)).write(to: object)
        XCTAssertThrowsError(try export(snapshot, name: "exported"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("exported").path))
    }

    func testSymlinkedStoredObjectIsRejected() throws {
        let snapshot = try create()
        let entry = try XCTUnwrap(snapshot.files.first)
        let object = repository.appendingPathComponent("objects").appendingPathComponent(entry.sha256)
        try FileManager.default.removeItem(at: object)
        try FileManager.default.createSymbolicLink(at: object, withDestinationURL: home.appendingPathComponent("history.jsonl"))
        XCTAssertThrowsError(try export(snapshot, name: "exported"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("exported").path))
    }

    func testEmptyHomeReportsNoDataInsteadOfPublishingVersion() throws {
        try FileManager.default.removeItem(at: home.appendingPathComponent("history.jsonl"))
        XCTAssertThrowsError(try create())
        XCTAssertEqual(try history(), [])
    }

    func testManifestCannotIncludeAuthenticationFile() throws {
        let snapshot = try create()
        try rewriteManifest(snapshot) { object in
            var entries = object["files"] as! [[String: Any]]
            entries[0]["relativePath"] = "auth.json"
            object["files"] = entries
        }
        XCTAssertThrowsError(try history())
        XCTAssertThrowsError(try export(snapshot, name: "exported"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("exported").path))
    }

    func testHardlinkedStoredObjectIsRejectedWithoutChangingOtherFile() throws {
        let snapshot = try create()
        let entry = try XCTUnwrap(snapshot.files.first)
        let object = repository.appendingPathComponent("objects").appendingPathComponent(entry.sha256)
        let alias = root.appendingPathComponent("object-alias")
        XCTAssertEqual(link(object.path, alias.path), 0)
        let before = try Data(contentsOf: alias)
        XCTAssertThrowsError(try export(snapshot, name: "exported"))
        XCTAssertEqual(try Data(contentsOf: alias), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("exported").path))
    }

    func testConcurrentRepositoryOperationIsRejected() throws {
        let snapshot = try create()
        let state = try NativeStateStore(root: repository)
        try state.withLock {
            XCTAssertThrowsError(try create())
            XCTAssertThrowsError(try history())
            XCTAssertThrowsError(try export(snapshot, name: "exported"))
        }
        XCTAssertEqual(try history(), [snapshot])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("exported").path))
    }

    func testSQLiteSidecarsRejectLinksAndFIFOs() throws {
        let database = home.appendingPathComponent("state_5.sqlite")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "CREATE TABLE synthetic(value TEXT)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close_v2(connection), SQLITE_OK)
        let outside = root.appendingPathComponent("outside-sidecar")
        let original = Data("must remain untouched".utf8)
        try original.write(to: outside)
        let wal = home.appendingPathComponent("state_5.sqlite-wal")
        try FileManager.default.createSymbolicLink(at: wal, withDestinationURL: outside)
        XCTAssertThrowsError(try create())
        try FileManager.default.removeItem(at: wal)
        let sharedMemory = home.appendingPathComponent("state_5.sqlite-shm")
        XCTAssertEqual(link(outside.path, sharedMemory.path), 0)
        XCTAssertThrowsError(try create())
        try FileManager.default.removeItem(at: sharedMemory)
        let journal = home.appendingPathComponent("state_5.sqlite-journal")
        XCTAssertEqual(mkfifo(journal.path, 0o600), 0)
        XCTAssertThrowsError(try create())
        XCTAssertEqual(try history(), [])
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    func testMissingObjectDoesNotAppearAsAvailableVersion() throws {
        let snapshot = try create()
        let entry = try XCTUnwrap(snapshot.files.first)
        try FileManager.default.removeItem(at: repository.appendingPathComponent("objects").appendingPathComponent(entry.sha256))
        XCTAssertThrowsError(try history())
        XCTAssertThrowsError(try export(snapshot, name: "exported"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("exported").path))
    }
}
