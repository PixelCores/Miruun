import Foundation
import CryptoKit
import Darwin
import CSQLite

/// Snapshot only the selected rollout and committed shared-state databases.
/// Never opens auth.json/config.toml and never changes/restores the live store.
public enum NativeBackup {
    public static func create(home: URL, rollout: URL, destination: URL, threadID: String, consentSharedState: Bool) throws -> [String: Any] {
        guard consentSharedState else { throw NativeStorageError.consentRequired }
        let home = try NativeFileSafety.validated(home)
        let source = try NativeFileSafety.validated(rollout)
        let target = try NativeFileSafety.validated(destination)
        try NativeFileSafety.noSymlinks(home)
        try NativeFileSafety.noSymlinks(source)
        try NativeFileSafety.noSymlinks(target)
        guard NativeFileSafety.within(source, home), source.pathExtension == "jsonl", !NativeFileSafety.within(target, home) else {
            throw NativeStorageError.invalidRollout
        }
        let bytes = try NativeFileSafety.readRegular(source, limit: 64 * 1024 * 1024)
        guard let text = String(data: bytes, encoding: .utf8),
              let first = text.split(whereSeparator: \.isNewline).first(where: { !String($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              let meta = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
              meta["type"] as? String == "session_meta", let payload = meta["payload"] as? [String: Any],
              !threadID.isEmpty, payload["id"] as? String == threadID else { throw NativeStorageError.invalidRollout }
        // Parent must already exist. mkdir has exclusive/no-overwrite semantics.
        guard mkdir(target.path, 0o700) == 0 else { throw NativeStorageError.unsafePath }
        do {
            let saved = target.appendingPathComponent("selected-rollout.jsonl")
            try NativeFileSafety.writeExclusive(bytes, to: saved)
            var records: [[String: String]] = [["name": saved.lastPathComponent, "sha256": digest(bytes)]]
            let databases = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !databases.isEmpty else { throw NativeStorageError.noDatabases }
            for database in databases {
                try NativeFileSafety.noSymlinks(database)
                var info = stat()
                guard lstat(database.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw NativeStorageError.unsafePath }
                let destination = target.appendingPathComponent(database.lastPathComponent)
                try NativeFileSafety.writeExclusive(Data(), to: destination)
                try backupSQLite(source: database, destination: destination)
                var after = stat()
                guard lstat(database.path, &after) == 0, after.st_dev == info.st_dev, after.st_ino == info.st_ino,
                      after.st_nlink == 1, after.st_mode == info.st_mode else { throw NativeStorageError.backupIncomplete }
                let fd = open(destination.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw NativeStorageError.backupIncomplete }
                let synced = fsync(fd) == 0; close(fd)
                guard synced, chmod(destination.path, 0o600) == 0 else { throw NativeStorageError.backupIncomplete }
                records.append(["name": destination.lastPathComponent, "sha256": try fileDigest(destination)])
            }
            let receipt: [String: Any] = ["complete": true, "selected_thread_id": threadID,
                "selected_rollout_sha256": records[0]["sha256"]!, "files": records,
                "warning": "包含私人对话/共享状态，仅留本机。不自动恢复，避免覆盖后续合法修改"]
            try NativeFileSafety.writeExclusive(JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]), to: target.appendingPathComponent("receipt.json"))
            try NativeFileSafety.syncDirectory(target)
            try NativeFileSafety.syncDirectory(target.deletingLastPathComponent())
            return receipt
        } catch {
            // Never clean up incomplete evidence or continue to a resume.
            throw NativeStorageError.backupIncomplete
        }
    }
    private static func backupSQLite(source: URL, destination: URL) throws {
        guard sqlite3_libversion_number() >= 3_031_000 else { throw NativeStorageError.backupIncomplete }
        var sourceDB: OpaquePointer?, destinationDB: OpaquePointer?
        guard sqlite3_open_v2(source.path, &sourceDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            if let sourceDB { sqlite3_close_v2(sourceDB) }; throw NativeStorageError.backupIncomplete
        }
        defer { sqlite3_close_v2(sourceDB) }
        guard sqlite3_open_v2(destination.path, &destinationDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            if let destinationDB { sqlite3_close_v2(destinationDB) }; throw NativeStorageError.backupIncomplete
        }
        defer { sqlite3_close_v2(destinationDB) }
        sqlite3_busy_timeout(sourceDB, 5_000); sqlite3_busy_timeout(destinationDB, 5_000)
        guard let backup = sqlite3_backup_init(destinationDB, "main", sourceDB, "main") else { throw NativeStorageError.backupIncomplete }
        var finished = false
        defer { if !finished { sqlite3_backup_finish(backup) } }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NativeStorageError.backupIncomplete }
            let code = sqlite3_backup_step(backup, 256)
            if code == SQLITE_DONE {
                let finish = sqlite3_backup_finish(backup); finished = true
                guard finish == SQLITE_OK else { throw NativeStorageError.backupIncomplete }
                // A copied WAL header can require absent WAL/SHM sidecars on a
                // read-only reopen. Normalize only this private snapshot, using
                // exclusive locking so SQLite does not create a shared-memory file.
                guard sqlite3_exec(destinationDB, "PRAGMA locking_mode=EXCLUSIVE", nil, nil, nil) == SQLITE_OK else {
                    throw NativeStorageError.backupIncomplete
                }
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(destinationDB, "PRAGMA journal_mode=DELETE", -1, &statement, nil) == SQLITE_OK else {
                    throw NativeStorageError.backupIncomplete
                }
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW,
                      let mode = sqlite3_column_text(statement, 0), String(cString: mode) == "delete",
                      sqlite3_step(statement) == SQLITE_DONE else { throw NativeStorageError.backupIncomplete }
                return
            }
            if code == SQLITE_BUSY || code == SQLITE_LOCKED { usleep(50_000) }
            else if code != SQLITE_OK { throw NativeStorageError.backupIncomplete }
        }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func fileDigest(_ url: URL) throws -> String {
        let stream = try FileHandle(forReadingFrom: url); defer { try? stream.close() }
        var hash = SHA256()
        while let chunk = try stream.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
