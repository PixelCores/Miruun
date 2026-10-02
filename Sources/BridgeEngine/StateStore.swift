import Foundation
import Darwin

public enum NativeStorageError: Error, LocalizedError {
    case unsafePath, invalidManifest, operationBusy, writeFailed, consentRequired, invalidRollout, backupIncomplete, noDatabases
    public var code: String {
        switch self {
        case .unsafePath: return "unsafe_path"
        case .invalidManifest: return "invalid_preflight"
        case .operationBusy: return "operation_busy"
        case .writeFailed: return "state_write_failed"
        case .consentRequired: return "backup_consent_required"
        case .invalidRollout: return "invalid_rollout"
        case .backupIncomplete: return "backup_incomplete"
        case .noDatabases: return "state_databases_missing"
        }
    }
    public var message: String { errorDescription ?? "本机操作已停止" }
    public var errorDescription: String? {
        switch self {
        case .unsafePath: return "本机路径或文件权限不安全，已停止"
        case .invalidManifest: return "预检记录无效或不可用，不能继续"
        case .operationBusy: return "另一个操作仍在进行，不会并行或自动重试"
        case .writeFailed: return "无法安全保存本机记录，已停止"
        case .consentRequired: return "缺少共享状态备份的明确同意"
        case .invalidRollout: return "选中 rollout 的路径或 session_meta ID 不匹配"
        case .backupIncomplete: return "备份失败或不完整；保留已写出的本机文件，禁止继续变更"
        case .noDatabases: return "未找到共享状态库，不能建立完整备份"
        }
    }
}

enum NativeFileSafety {
    static func validated(_ url: URL) throws -> URL {
        let components = url.path.utf8.split(separator: 47)
        guard url.isFileURL, url.baseURL == nil, url.host == nil || url.host == "",
              url.query == nil, url.fragment == nil, url.path.hasPrefix("/"), !url.path.contains("\0"),
              !components.contains(where: { $0.elementsEqual([46]) || $0.elementsEqual([46, 46]) }) else {
            throw NativeStorageError.unsafePath
        }
        // Foundation standardization strips /private on macOS, introducing
        // symlink aliases that the subsequent no-follow check must reject.
        return url
    }
    static func temporaryDirectory() throws -> URL {
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw NativeStorageError.unsafePath
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
    static func noSymlinks(_ url: URL) throws {
        var current = try validated(url)
        while true {
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else { throw NativeStorageError.unsafePath }
            } else if errno != ENOENT { throw NativeStorageError.unsafePath }
            if current.path == "/" { break }
            current.deleteLastPathComponent()
        }
    }
    static func within(_ child: URL, _ parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path == "/" ? "/" : parent.path + "/")
    }
    static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NativeStorageError.writeFailed }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw NativeStorageError.writeFailed }
    }
    static func writeExclusive(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NativeStorageError.writeFailed }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let result = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw NativeStorageError.writeFailed }
                offset += result
            }
        }
        guard fsync(fd) == 0 else { throw NativeStorageError.writeFailed }
    }
    static func readRegular(_ url: URL, limit: Int) throws -> Data {
        try noSymlinks(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NativeStorageError.unsafePath }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= Int64(limit) else { throw NativeStorageError.unsafePath }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw NativeStorageError.unsafePath }
            if count == 0 { break }
            guard output.count <= limit - count else { throw NativeStorageError.unsafePath }
            output.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0,
              after.st_dev == info.st_dev, after.st_ino == info.st_ino, after.st_nlink == 1,
              after.st_mode == info.st_mode, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec,
              output.count == Int(info.st_size) else { throw NativeStorageError.unsafePath }
        return output
    }
}

public final class NativeStateStore {
    public let root: URL
    public init(root: URL) throws {
        self.root = try NativeFileSafety.validated(root)
        try NativeFileSafety.noSymlinks(self.root)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(self.root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), chmod(self.root.path, 0o700) == 0 else { throw NativeStorageError.unsafePath }
    }
    public func write(name: String, value: [String: Any]) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              JSONSerialization.isValidJSONObject(value) else { throw NativeStorageError.writeFailed }
        let destination = root.appendingPathComponent(name)
        try NativeFileSafety.noSymlinks(destination)
        let temporary = root.appendingPathComponent(".receipt-" + UUID().uuidString)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        do {
            try NativeFileSafety.writeExclusive(data, to: temporary)
            guard rename(temporary.path, destination.path) == 0 else { throw NativeStorageError.writeFailed }
            try NativeFileSafety.syncDirectory(root)
        } catch {
            // Delete only our unfinished temporary receipt, never a backup or
            // completed receipt. A failed post-rename fsync remains uncertain.
            _ = unlink(temporary.path)
            throw NativeStorageError.writeFailed
        }
        return destination.path
    }
    public func readPreflight(id: String) throws -> [String: Any] {
        guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id.lowercased(), id.count == 36 else {
            throw NativeStorageError.invalidManifest
        }
        let file = root.appendingPathComponent("preflight-" + id + ".json")
        do {
            let data = try NativeFileSafety.readRegular(file, limit: 65_536)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeStorageError.invalidManifest }
            return object
        } catch { throw NativeStorageError.invalidManifest }
    }
    public func withLock<T>(_ operation: () throws -> T) throws -> T {
        let path = root.appendingPathComponent("switch.lock")
        try NativeFileSafety.noSymlinks(path)
        let fd = open(path.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NativeStorageError.unsafePath }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(),
              fchmod(fd, 0o600) == 0 else { throw NativeStorageError.unsafePath }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw NativeStorageError.operationBusy }
        return try operation()
    }
}
