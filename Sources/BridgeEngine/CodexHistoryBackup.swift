import Foundation
import CryptoKit
import Darwin

/// Versioned local copies of history and memory under one explicitly selected CODEX_HOME.
/// Authentication/configuration are excluded; export never restores into the live home.
public enum CodexHistoryBackup {
    public struct Entry: Codable, Equatable, Sendable {
        public let relativePath: String
        public let sha256: String
        public let byteCount: Int64
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public let formatVersion: Int
        public let id: String
        public let createdAt: Date
        public let sourceHome: String
        public let files: [Entry]
    }

    public enum Failure: Error, LocalizedError {
        case noData, sourceChanged, invalidSnapshot, corruptObject
        public var errorDescription: String? {
            switch self {
            case .noData: return "所选 Codex 目录没有可备份的聊天或记忆文件"
            case .sourceChanged: return "备份期间源文件发生变化，请稍后重试；未生成新版本"
            case .invalidSnapshot: return "备份版本清单无效，已停止"
            case .corruptObject: return "备份内容缺失或校验失败，已停止"
            }
        }
    }

    public static var defaultRepository: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Miruun/HistoryBackups", isDirectory: true)
    }

    private static let manifestSizeLimit = 64 * 1024 * 1024
    private static let directories: Set<String> = ["sessions", "archived_sessions", "memories", "memories_v2", "attachments"]
    private static let standalone: Set<String> = ["history.jsonl", "session_index.jsonl", "paginated_history.jsonl.zst", "AGENTS.md"]
    private static let databasePrefixes = ["state_", "memories_", "memories_v2_", "thread_history_", "goals_", "queue_"]

    /// Returns the latest existing version when its file contents are unchanged.
    public static func create(home: URL, repository: URL = defaultRepository) throws -> Snapshot {
        let (home, repository) = try locations(home: home, repository: repository)
        let sources = try sourceFiles(home)
        guard !sources.isEmpty else { throw Failure.noData }
        let state = try NativeStateStore(root: repository)
        return try state.withLock {
            let objects = repository.appendingPathComponent("objects", isDirectory: true)
            let manifests = manifestDirectory(home: home, repository: repository)
            try privateDirectory(objects)
            try privateDirectory(manifests)
            let staging = repository.appendingPathComponent(".pending-" + UUID().uuidString, isDirectory: true)
            guard mkdir(staging.path, 0o700) == 0 else { throw NativeStorageError.writeFailed }
            defer { try? FileManager.default.removeItem(at: staging) }
            var entries: [Entry] = []
            for source in sources {
                let temporary = staging.appendingPathComponent(UUID().uuidString)
                let result: (sha256: String, byteCount: Int64)
                if source.isDatabase {
                    try validateSQLiteFiles(source.url)
                    try NativeFileSafety.writeExclusive(Data(), to: temporary)
                    try NativeBackup.backupSQLite(source: source.url, destination: temporary)
                    try validateSQLiteFiles(source.url)
                    let fd = open(temporary.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw NativeStorageError.writeFailed }
                    let synced = fsync(fd) == 0
                    close(fd)
                    guard synced else { throw NativeStorageError.writeFailed }
                    result = try stream(temporary)
                } else {
                    result = try stream(source.url, to: temporary, expected: source.info)
                }
                let entry = Entry(relativePath: source.path, sha256: result.sha256, byteCount: result.byteCount)
                let object = objects.appendingPathComponent(entry.sha256)
                if try exists(object) {
                    try verify(entry, at: object)
                    try FileManager.default.removeItem(at: temporary)
                } else {
                    guard renamex_np(temporary.path, object.path, UInt32(RENAME_EXCL)) == 0 else {
                        throw NativeStorageError.writeFailed
                    }
                }
                entries.append(entry)
            }
            // Plain files must remain unchanged over the whole operation. Each database
            // is an SQLite online-backup snapshot; there is no cross-database transaction.
            let after = try sourceFiles(home)
            guard sources.count == after.count,
                  zip(sources, after).allSatisfy({ before, after in
                      before.path == after.path && unchanged(before.info, after.info, contents: !before.isDatabase)
                  }) else { throw Failure.sourceChanged }
            try NativeFileSafety.syncDirectory(objects)
            let previous = try readSnapshots(home: home, repository: repository)
            if let latest = previous.first, latest.files == entries { return latest }
            let snapshot = Snapshot(formatVersion: 1, id: UUID().uuidString.lowercased(), createdAt: Date(),
                                    sourceHome: home.path, files: entries)
            let temporary = staging.appendingPathComponent("manifest.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(snapshot)
            guard manifestData.count <= manifestSizeLimit else { throw Failure.invalidSnapshot }
            try NativeFileSafety.writeExclusive(manifestData, to: temporary)
            let destination = manifests.appendingPathComponent(snapshot.id + ".json")
            guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw NativeStorageError.writeFailed
            }
            try NativeFileSafety.syncDirectory(manifests)
            try NativeFileSafety.syncDirectory(repository)
            return snapshot
        }
    }

    /// Lists only complete manifests for this source home, newest first.
    public static func snapshots(home: URL, repository: URL = defaultRepository) throws -> [Snapshot] {
        let (home, repository) = try locations(home: home, repository: repository)
        guard try exists(repository) else { return [] }
        let state = try NativeStateStore(root: repository)
        return try state.withLock { try readSnapshots(home: home, repository: repository) }
    }

    /// Materializes a verified version in a new directory. Publication is atomic.
    public static func export(_ snapshot: Snapshot, repository: URL = defaultRepository, destination: URL) throws {
        try validate(snapshot)
        let home = URL(fileURLWithPath: snapshot.sourceHome, isDirectory: true)
        let (_, repository) = try locations(home: home, repository: repository)
        let destination = try NativeFileSafety.validated(destination)
        try NativeFileSafety.noSymlinks(destination)
        guard !NativeFileSafety.within(destination, repository), !NativeFileSafety.within(repository, destination),
              !NativeFileSafety.within(destination, home), !NativeFileSafety.within(home, destination),
              !(try exists(destination)) else { throw NativeStorageError.unsafePath }
        try directory(destination.deletingLastPathComponent())
        guard try exists(repository) else { throw Failure.invalidSnapshot }
        let state = try NativeStateStore(root: repository)
        try state.withLock {
            let manifest = manifestDirectory(home: home, repository: repository).appendingPathComponent(snapshot.id + ".json")
            guard try readSnapshot(manifest, home: home) == snapshot else { throw Failure.invalidSnapshot }
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".miruun-export-" + UUID().uuidString, isDirectory: true)
            guard mkdir(staging.path, 0o700) == 0 else { throw NativeStorageError.writeFailed }
            defer { try? FileManager.default.removeItem(at: staging) }
            for entry in snapshot.files {
                let target = staging.appendingPathComponent(entry.relativePath)
                try privateDirectory(target.deletingLastPathComponent())
                let object = repository.appendingPathComponent("objects").appendingPathComponent(entry.sha256)
                _ = try storedFile(object)
                let result = try stream(object, to: target)
                guard result.sha256 == entry.sha256, result.byteCount == entry.byteCount else { throw Failure.corruptObject }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try NativeFileSafety.writeExclusive(try encoder.encode(snapshot), to: staging.appendingPathComponent("miruun-backup.json"))
            // Persist every newly created directory before exposing the completed tree.
            try syncTree(staging)
            guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw NativeStorageError.writeFailed
            }
            try NativeFileSafety.syncDirectory(destination.deletingLastPathComponent())
        }
    }

    private struct SourceFile {
        let path: String
        let url: URL
        let info: stat
        var isDatabase: Bool { CodexHistoryBackup.isDatabase(path) }
    }

    private static func sourceFiles(_ home: URL) throws -> [SourceFile] {
        try directory(home)
        var files: [SourceFile] = []
        func visit(_ url: URL, path: String, isDirectory: Bool) throws {
            try NativeFileSafety.noSymlinks(url)
            let info = try metadata(url)
            if isDirectory {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw NativeStorageError.unsafePath }
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    let childInfo = try metadata(child)
                    try visit(child, path: path + "/" + child.lastPathComponent, isDirectory: (childInfo.st_mode & S_IFMT) == S_IFDIR)
                }
            } else {
                guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw NativeStorageError.unsafePath }
                files.append(SourceFile(path: path, url: url, info: info))
            }
        }
        for url in try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            if directories.contains(name) { try visit(url, path: name, isDirectory: true) }
            else if standalone.contains(name) || isDatabase(name) { try visit(url, path: name, isDirectory: false) }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func isDatabase(_ path: String) -> Bool {
        guard !path.contains("/"), path.hasSuffix(".sqlite") else { return false }
        return databasePrefixes.contains { prefix in
            guard path.hasPrefix(prefix) else { return false }
            let version = path.dropFirst(prefix.count).dropLast(".sqlite".count)
            return !version.isEmpty && version.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    private static func validateSQLiteFiles(_ database: URL) throws {
        // SQLite reads sidecars itself even though they are never copied as objects.
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let file = URL(fileURLWithPath: database.path + suffix)
            guard try exists(file) else { continue }
            let info = try metadata(file)
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
                throw NativeStorageError.unsafePath
            }
        }
    }

    private static func locations(home: URL, repository: URL) throws -> (URL, URL) {
        let home = try NativeFileSafety.validated(home)
        let repository = try NativeFileSafety.validated(repository)
        try NativeFileSafety.noSymlinks(home)
        try NativeFileSafety.noSymlinks(repository)
        guard !NativeFileSafety.within(repository, home), !NativeFileSafety.within(home, repository) else {
            throw NativeStorageError.unsafePath
        }
        return (home, repository)
    }

    private static func manifestDirectory(home: URL, repository: URL) -> URL {
        repository.appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(digest(Data(home.path.utf8)), isDirectory: true)
    }

    private static func readSnapshots(home: URL, repository: URL) throws -> [Snapshot] {
        let manifests = manifestDirectory(home: home, repository: repository)
        guard try exists(manifests) else { return [] }
        try directory(manifests)
        var objectSizes: [String: Int64] = [:]
        let snapshots = try FileManager.default.contentsOfDirectory(at: manifests, includingPropertiesForKeys: nil)
            .map { url in
                guard url.pathExtension == "json" else { throw Failure.invalidSnapshot }
                let snapshot = try readSnapshot(url, home: home)
                for entry in snapshot.files {
                    if let size = objectSizes[entry.sha256] {
                        guard size == entry.byteCount else { throw Failure.invalidSnapshot }
                    } else {
                        let object = repository.appendingPathComponent("objects").appendingPathComponent(entry.sha256)
                        let info = try storedFile(object)
                        guard info.st_size == entry.byteCount else { throw Failure.corruptObject }
                        objectSizes[entry.sha256] = entry.byteCount
                    }
                }
                return snapshot
            }
        return snapshots.sorted { $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt }
    }

    private static func readSnapshot(_ url: URL, home: URL) throws -> Snapshot {
        _ = try storedFile(url)
        let data = try NativeFileSafety.readRegular(url, limit: manifestSizeLimit)
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { throw Failure.invalidSnapshot }
        try validate(snapshot)
        guard snapshot.sourceHome == home.path, url.lastPathComponent == snapshot.id + ".json" else {
            throw Failure.invalidSnapshot
        }
        return snapshot
    }

    private static func validate(_ snapshot: Snapshot) throws {
        guard snapshot.formatVersion == 1, let uuid = UUID(uuidString: snapshot.id),
              uuid.uuidString.lowercased() == snapshot.id, snapshot.id.count == 36,
              snapshot.createdAt.timeIntervalSinceReferenceDate.isFinite, !snapshot.files.isEmpty,
              snapshot.sourceHome.hasPrefix("/") else { throw Failure.invalidSnapshot }
        _ = try NativeFileSafety.validated(URL(fileURLWithPath: snapshot.sourceHome, isDirectory: true))
        var previous: String?
        for entry in snapshot.files {
            let path = entry.relativePath
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }),
                  (components.count > 1 && directories.contains(String(components[0]))) ||
                    (components.count == 1 && (standalone.contains(path) || isDatabase(path))),
                  entry.sha256.count == 64, entry.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
                  entry.byteCount >= 0, previous == nil || previous! < path,
                  previous == nil || !path.hasPrefix(previous! + "/") else { throw Failure.invalidSnapshot }
            previous = path
        }
    }

    private static func verify(_ entry: Entry, at url: URL) throws {
        _ = try storedFile(url)
        let result = try stream(url)
        guard result.sha256 == entry.sha256, result.byteCount == entry.byteCount else { throw Failure.corruptObject }
    }

    /// Copies and hashes in bounded chunks; all reads bind to one unlinked-free inode.
    private static func stream(_ source: URL, to destination: URL? = nil, expected: stat? = nil) throws -> (sha256: String, byteCount: Int64) {
        try NativeFileSafety.noSymlinks(source)
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NativeStorageError.unsafePath }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_nlink == 1, before.st_size >= 0 else {
            throw NativeStorageError.unsafePath
        }
        if let expected, !unchanged(expected, before) { throw Failure.sourceChanged }
        var output: Int32 = -1
        if let destination {
            try NativeFileSafety.noSymlinks(destination)
            output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw NativeStorageError.writeFailed }
        }
        defer { if output >= 0 { close(output) } }
        var hash = SHA256(), bytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw NativeStorageError.unsafePath }
            if count == 0 { break }
            bytes += Int64(count)
            guard bytes <= before.st_size else { throw Failure.sourceChanged }
            hash.update(data: Data(buffer.prefix(count)))
            if output >= 0 {
                try buffer.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < count {
                        let written = Darwin.write(output, raw.baseAddress!.advanced(by: offset), count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw NativeStorageError.writeFailed }
                        offset += written
                    }
                }
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, unchanged(before, after),
              unchanged(after, try metadata(source)), bytes == before.st_size else { throw Failure.sourceChanged }
        if output >= 0 {
            guard fsync(output) == 0 else { throw NativeStorageError.writeFailed }
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }

    private static func unchanged(_ first: stat, _ second: stat, contents: Bool = true) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && second.st_nlink == 1 &&
            first.st_mode == second.st_mode && first.st_uid == second.st_uid &&
            (!contents || (first.st_size == second.st_size &&
                first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec &&
                first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec))
    }

    private static func storedFile(_ url: URL) throws -> stat {
        try NativeFileSafety.noSymlinks(url)
        let info = try metadata(url)
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), (info.st_mode & 0o777) == 0o600 else { throw NativeStorageError.unsafePath }
        return info
    }

    private static func metadata(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw NativeStorageError.unsafePath }
        return info
    }

    private static func exists(_ url: URL) throws -> Bool {
        try NativeFileSafety.noSymlinks(url)
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw NativeStorageError.unsafePath }
        return false
    }

    private static func directory(_ url: URL) throws {
        try NativeFileSafety.noSymlinks(url)
        guard (try metadata(url).st_mode & S_IFMT) == S_IFDIR else { throw NativeStorageError.unsafePath }
    }

    private static func privateDirectory(_ url: URL) throws {
        try NativeFileSafety.noSymlinks(url)
        if !(try exists(url)) {
            try privateDirectory(url.deletingLastPathComponent())
            guard mkdir(url.path, 0o700) == 0 else { throw NativeStorageError.writeFailed }
            try NativeFileSafety.syncDirectory(url.deletingLastPathComponent())
        }
        let info = try metadata(url)
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), chmod(url.path, 0o700) == 0 else {
            throw NativeStorageError.unsafePath
        }
    }

    private static func syncTree(_ directory: URL) throws {
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if (try metadata(child).st_mode & S_IFMT) == S_IFDIR { try syncTree(child) }
        }
        try NativeFileSafety.syncDirectory(directory)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
