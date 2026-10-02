import Foundation
import Darwin
import BridgeCore

/// Crash/force-quit durability is independent of an in-memory button state.
final class PrivateState {
    let root: URL
    let marker: URL
    var pending: [String: JSONValue]?
    private(set) var blocked = false

    init() throws {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Miruun", isDirectory: true)
        marker = root.appendingPathComponent("pending-operation.json")
        try Self.privateDirectory(root)
        try Self.privateDirectory(root.appendingPathComponent("Backups", isDirectory: true))
        if FileManager.default.fileExists(atPath: marker.path) {
            blocked = true
            let attributes = try FileManager.default.attributesOfItem(atPath: marker.path)
            if attributes[.type] as? FileAttributeType == .typeRegular,
               (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
               (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
               ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 65_536,
               let data = try? Data(contentsOf: marker),
               let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                pending = value.object
            }
        }
    }

    static func privateDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } else {
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    func begin(_ request: [String: JSONValue]) throws {
        guard !blocked else { throw CocoaError(.fileWriteFileExists) }
        // Deliberately excludes consent flags and any backend config. A marker
        // is not reusable authority to run a saved request on next launch.
        let keys: Set<String> = ["thread_id", "provider", "model", "expected_cwd", "backend", "home", "backup_directory", "request_id"]
        var value = request.filter { keys.contains($0.key) }
        value["started_at"] = .string(ISO8601DateFormatter().string(from: Date()))
        let data = try JSONEncoder().encode(JSONValue.object(value))
        let descriptor = open(marker.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        blocked = true; pending = value
        // Make the pending marker durable before a mutation subprocess starts.
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.synchronize(); try file.close()
        let directory = open(root.path, O_RDONLY)
        guard directory >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw CocoaError(.fileWriteUnknown) }
        pending = value; blocked = true
    }

    func finish(certain: Bool) throws {
        guard certain else { return }
        // Keep the receipt/backup. Remove only this app's transient lock after
        // a definitive result, never on metadata-only verification.
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        pending = nil; blocked = false
    }
}
