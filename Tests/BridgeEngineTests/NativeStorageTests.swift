import XCTest
import Foundation
import Darwin
import CSQLite
@testable import BridgeEngine

final class NativeStorageTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var rollout: URL!
    override func setUpWithError() throws {
        // Resolve macOS /var -> /private/var in our own disposable fixture only.
        root = try NativeFileSafety.temporaryDirectory().appendingPathComponent("bridge-native-test-" + UUID().uuidString)
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        rollout = home.appendingPathComponent("selected.jsonl")
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"original\"}}\n".utf8).write(to: rollout)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE synthetic(value TEXT); INSERT INTO synthetic VALUES ('committed')", nil, nil, nil), SQLITE_OK)
        try Data("DO_NOT_COPY_CREDENTIALS".utf8).write(to: home.appendingPathComponent("auth.json"))
        try Data("DO_NOT_COPY_CONFIG".utf8).write(to: home.appendingPathComponent("config.toml"))
    }
    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }
    private func backup(to name: String = "backup", id: String = "original", consent: Bool = true) throws -> [String: Any] {
        try NativeBackup.create(home: home, rollout: rollout, destination: root.appendingPathComponent(name), threadID: id, consentSharedState: consent)
    }
    func testNoConsentOrWrongIDCreatesNoBackup() throws {
        XCTAssertThrowsError(try backup(consent: false))
        XCTAssertThrowsError(try backup(id: "different-thread"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backup").path))
    }
    func testPrivateBackupContainsOnlyExplicitFilesAndConsistentSQLite() throws {
        let receipt = try backup()
        XCTAssertEqual(receipt["complete"] as? Bool, true)
        let destination = root.appendingPathComponent("backup")
        let files = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), Set(["selected-rollout.jsonl", "state_5.sqlite", "receipt.json"]))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        for file in files { XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600) }
        let receiptText = String(data: try JSONSerialization.data(withJSONObject: receipt), encoding: .utf8)!
        XCTAssertFalse(receiptText.contains("DO_NOT_COPY"))
        var db: OpaquePointer?, query: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(destination.appendingPathComponent("state_5.sqlite").path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_finalize(query); sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT value FROM synthetic", -1, &query, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(query, 0)), "committed")
    }
    func testExistingBackupIsNeverOverwritten() throws {
        _ = try backup()
        let receipt = root.appendingPathComponent("backup/receipt.json")
        let before = try Data(contentsOf: receipt)
        XCTAssertThrowsError(try backup())
        XCTAssertEqual(try Data(contentsOf: receipt), before)
    }
    func testSourceSymlinkAndDestinationInsideHomeRejected() throws {
        let alias = home.appendingPathComponent("alias.jsonl")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: rollout)
        XCTAssertThrowsError(try NativeBackup.create(home: home, rollout: alias, destination: root.appendingPathComponent("backup"), threadID: "original", consentSharedState: true))
        XCTAssertThrowsError(try NativeBackup.create(home: home, rollout: rollout, destination: home.appendingPathComponent("backup"), threadID: "original", consentSharedState: true))
    }
    func testPathTraversalOutsideHomeRejected() throws {
        let outside = root.appendingPathComponent("outside.jsonl")
        try Data(contentsOf: rollout).write(to: outside)
        XCTAssertThrowsError(try NativeBackup.create(home: home, rollout: outside, destination: root.appendingPathComponent("backup"), threadID: "original", consentSharedState: true))
    }
    func testMissingDatabasePreservesIncompleteEvidence() throws {
        try FileManager.default.removeItem(at: home.appendingPathComponent("state_5.sqlite"))
        XCTAssertThrowsError(try backup())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("backup/selected-rollout.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backup/receipt.json").path))
    }
    func testSQLiteBackupIncludesCommittedWAL() throws {
        var live: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &live), SQLITE_OK)
        defer { sqlite3_close_v2(live) }
        XCTAssertEqual(sqlite3_exec(live, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO synthetic VALUES ('wal-committed')", nil, nil, nil), SQLITE_OK)
        _ = try backup()
        var saved: OpaquePointer?, statement: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(root.appendingPathComponent("backup/state_5.sqlite").path, &saved, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement); sqlite3_close_v2(saved) }
        XCTAssertEqual(sqlite3_prepare_v2(saved, "SELECT COUNT(*) FROM synthetic", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW); XCTAssertEqual(sqlite3_column_int(statement, 0), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backup/state_5.sqlite-wal").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backup/state_5.sqlite-shm").path))
        var mode: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(saved, "PRAGMA journal_mode", -1, &mode, nil), SQLITE_OK)
        defer { sqlite3_finalize(mode) }
        XCTAssertEqual(sqlite3_step(mode), SQLITE_ROW)
        XCTAssertEqual(String(cString: try XCTUnwrap(sqlite3_column_text(mode, 0))), "delete")
    }
    func testStateWritesArePrivateAndReadOnlyLockIsExclusive() throws {
        let state = try NativeStateStore(root: root.appendingPathComponent("state"))
        let id = UUID().uuidString.lowercased()
        let path = try state.write(name: "preflight-" + id + ".json", value: ["preflight_id": id, "consumed": false])
        XCTAssertEqual(try state.readPreflight(id: id)["preflight_id"] as? String, id)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try state.withLock { XCTAssertThrowsError(try state.withLock { true }) }
    }
    func testStateRejectsTraversalAndSymlinkManifests() throws {
        let state = try NativeStateStore(root: root.appendingPathComponent("state"))
        XCTAssertThrowsError(try state.write(name: "../bad.json", value: [:]))
        XCTAssertThrowsError(try state.readPreflight(id: "../secret"))
        let id = UUID().uuidString.lowercased()
        try FileManager.default.createSymbolicLink(at: state.root.appendingPathComponent("preflight-" + id + ".json"), withDestinationURL: rollout)
        XCTAssertThrowsError(try state.readPreflight(id: id))
    }
    func testHardlinkedLockDoesNotChangeOtherFilePermissions() throws {
        let state = try NativeStateStore(root: root.appendingPathComponent("state"))
        let other = root.appendingPathComponent("unrelated.txt")
        try Data("unrelated".utf8).write(to: other)
        XCTAssertEqual(chmod(other.path, 0o640), 0)
        XCTAssertEqual(link(other.path, state.root.appendingPathComponent("switch.lock").path), 0)
        XCTAssertThrowsError(try state.withLock { true })
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: other.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }
    func testHardlinkedRolloutIsRejectedBeforeBackup() throws {
        let alias = root.appendingPathComponent("outside-alias.jsonl")
        XCTAssertEqual(link(rollout.path, alias.path), 0)
        XCTAssertThrowsError(try backup())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backup").path))
    }
    func testFIFORolloutIsRejectedWithoutWaitingForWriter() throws {
        let fifo = home.appendingPathComponent("fifo.jsonl")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try NativeBackup.create(home: home, rollout: fifo, destination: root.appendingPathComponent("backup"), threadID: "original", consentSharedState: true))
    }
}
