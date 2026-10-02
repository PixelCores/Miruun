import Foundation
import Darwin
import CryptoKit

public enum ContinuityPhase: String, Sendable, Equatable {
    case waiting, ready, updated, blocked
}

public struct ContinuityStatus: Sendable, Equatable {
    public let phase: ContinuityPhase
    public let message: String
    public let backupPath: String?

    public init(phase: ContinuityPhase, message: String, backupPath: String? = nil) {
        self.phase = phase
        self.message = message
        self.backupPath = backupPath
    }
}

/// Call serially every two seconds. This guard only maintains the user config;
/// it never opens sessions/databases or starts a backend. Enabling it authorizes
/// copying a selected local provider's inline bearer into file-based API auth.
/// Two stable samples and a final byte comparison detect observed conflicts.
/// Atomic rename is not a compare-and-swap: a writer that ignores this guard can
/// still replace config/auth after the final check. Stop it before restarting GUI.
public final class ContinuityGuard {
    private struct Snapshot: Equatable {
        let config: Data
        let auth: Data?
    }

    private enum Failure: Error {
        case unsafeFiles, missingAuth, invalidConfig, invalidAuth, unsupportedAuth, overrides
        case unsupportedProvider, unsafeEndpoint, oauthRoute, conflict, backup, write, clientsActive, clientsUnknown, pending

        var message: String {
            switch self {
            case .unsafeFiles: return "配置或登录文件无法安全读取；需要当前用户拥有的普通文件，不能使用链接或超限文件。"
            case .missingAuth: return "未找到可用的文件认证或代理 Key；请在 CC Switch 选择已配置的本机代理接入。"
            case .invalidConfig: return "配置无法安全解析；守护已停止，不会猜测或改写不支持的 TOML。"
            case .invalidAuth: return "登录文件格式或 API Key 无效；守护未修改配置。"
            case .unsupportedAuth: return "发现混合或不支持的认证方式；守护未修改配置或凭据。"
            case .overrides: return "配置包含 profile、凭据存储或登录覆盖；无法保证原生历史接入，守护已停止。"
            case .unsupportedProvider: return "目标 provider 的认证或能力设置无法完整保留；守护未修改配置。"
            case .unsafeEndpoint: return "目标必须是明确的本机 loopback HTTP/HTTPS 地址，不能含用户信息、查询或片段。"
            case .oauthRoute: return "ChatGPT/OAuth 登录仍有非 Miruun 管理的地址或 provider 覆盖；请先在 CC Switch 恢复官方入口，再重启 GUI。"
            case .conflict: return "配置或登录文件在保存前已变化；保留备份，本次未覆盖。"
            case .backup: return "无法完成私有配置备份；守护未修改配置。"
            case .write: return "配置保存未获完整持久化确认；保留备份，守护不会自动恢复。"
            case .clientsActive: return "连接配置待更新；请退出 Codex/ChatGPT 及其他 Codex 后端，随后会自动完成。"
            case .clientsUnknown: return "无法确认 Codex/ChatGPT 已退出；守护未开始写入。"
            case .pending: return "前一次连接配置更新未获得完整确认；请保留备份并人工复核，守护不会重试或自动恢复。"
            }
        }
    }

    private let home: URL
    private let backupDirectory: URL
    private let clientsAreRunning: () throws -> Bool
    private static let endpointMarker = "# miruun-managed-openai-base-url"
    private var previous: Snapshot?
    private var backupPath: String?
    private var blockedStatus: ContinuityStatus?
    private var transactionStarted = false
    private var pendingFile: URL {
        let identifier = SHA256.hash(data: Data(home.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return backupDirectory.appendingPathComponent("pending-" + identifier + ".json")
    }

    public init(home: URL, backupDirectory: URL, clientsAreRunning: @escaping () throws -> Bool = {
        try !NativeDiscovery.activeClients(backend: URL(fileURLWithPath: "/codex")).isEmpty
    }) {
        self.home = home
        self.backupDirectory = backupDirectory
        self.clientsAreRunning = clientsAreRunning
    }

    public func check() -> ContinuityStatus {
        if let blockedStatus { return blockedStatus }
        backupPath = nil
        transactionStarted = false
        do {
            try checkPending()
            let snapshot = try readSnapshot()
            let (replacement, apiKey) = try plannedSnapshot(snapshot)
            guard replacement != snapshot else {
                previous = snapshot
                return apiKey
                    ? ContinuityStatus(phase: .ready, message: "本机代理配置已就绪，可打开 Codex 核对续聊与账号。")
                    : ContinuityStatus(phase: .waiting, message: "当前为 ChatGPT/OAuth 登录且无地址覆盖；保持官方入口，不修改凭据。")
            }
            try requireClosed()
            guard previous == snapshot else {
                previous = snapshot
                return ContinuityStatus(phase: .waiting, message: apiKey
                    ? "检测到接入配置，等待下一次相同采样后保存。"
                    : "检测到 OAuth 回切，等待下一次相同采样后移除 Miruun 的本机地址覆盖。")
            }
            try save(replacement, expected: snapshot)
            previous = replacement
            return ContinuityStatus(phase: .updated, message: apiKey
                ? "已备份并完成代理配置与认证接入，可以重新打开 Codex 验证续聊。"
                : "已备份并移除 Miruun 的本机地址覆盖，未改 provider 或凭据；请停止其他配置写入并重启 GUI，核对 OAuth 登录。", backupPath: backupPath)
        } catch Failure.missingAuth {
            previous = nil
            return ContinuityStatus(phase: .waiting, message: Failure.missingAuth.message, backupPath: backupPath)
        } catch Failure.clientsActive {
            previous = nil
            if transactionStarted {
                let status = ContinuityStatus(phase: .blocked, message: Failure.pending.message, backupPath: backupPath)
                blockedStatus = status
                return status
            }
            return ContinuityStatus(phase: .waiting, message: Failure.clientsActive.message, backupPath: backupPath)
        } catch {
            previous = nil
            let message = transactionStarted ? Failure.pending.message : (error as? Failure)?.message ?? Failure.unsafeFiles.message
            let status = ContinuityStatus(phase: .blocked, message: message, backupPath: backupPath)
            if transactionStarted { blockedStatus = status }
            return status
        }
    }

    private func readSnapshot() throws -> Snapshot {
        try ownedDirectory(home)
        let config = try ownedFile(home.appendingPathComponent("config.toml"), limit: 1_024 * 1_024)
        let auth: Data?
        do { auth = try ownedFile(home.appendingPathComponent("auth.json"), limit: 65_536) }
        catch Failure.missingAuth { auth = nil }
        return Snapshot(config: config, auth: auth)
    }

    private func ownedDirectory(_ url: URL) throws {
        try NativeFileSafety.noSymlinks(url)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { throw Failure.unsafeFiles }
    }

    private func ownedFile(_ url: URL, limit: Int) throws -> Data {
        var before = stat()
        try NativeFileSafety.noSymlinks(url)
        guard lstat(url.path, &before) == 0 else {
            if url.lastPathComponent == "auth.json", errno == ENOENT { throw Failure.missingAuth }
            throw Failure.unsafeFiles
        }
        guard before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_uid == getuid() else { throw Failure.unsafeFiles }
        let data = try NativeFileSafety.readRegular(url, limit: limit)
        var after = stat()
        guard lstat(url.path, &after) == 0, after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_uid == getuid(), after.st_nlink == 1, after.st_mode == before.st_mode,
              after.st_size == before.st_size, after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { throw Failure.unsafeFiles }
        return data
    }

    private func apiKey(_ data: Data) throws -> String? {
        guard let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidAuth }
        let allowed: Set<String> = ["OPENAI_API_KEY", "auth_mode", "tokens", "last_refresh"]
        guard Set(auth.keys).isSubset(of: allowed) else { throw Failure.unsupportedAuth }
        let mode = auth["auth_mode"] as? String
        if let rawMode = auth["auth_mode"], !(rawMode is NSNull), mode == nil { throw Failure.invalidAuth }
        guard mode == nil || mode == "apikey" || mode == "chatgpt" else { throw Failure.unsupportedAuth }
        let tokens = auth["tokens"]
        if let tokens, !(tokens is NSNull), !(tokens is [String: Any]) { throw Failure.invalidAuth }
        let hasTokens = tokens != nil && !(tokens is NSNull) && !((tokens as? [String: Any])?.isEmpty == true)
        let key = auth["OPENAI_API_KEY"] as? String
        if mode == "chatgpt" || hasTokens {
            guard mode != "apikey", key == nil || key?.isEmpty == true else { throw Failure.unsupportedAuth }
            return nil
        }
        guard let key, (1...8_192).contains(key.utf8.count), key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw Failure.invalidAuth
        }
        return key
    }

    private func plannedSnapshot(_ snapshot: Snapshot) throws -> (Snapshot, Bool) {
        guard let text = String(data: snapshot.config, encoding: .utf8) else { throw Failure.invalidConfig }
        let root: CatalogTable
        do { root = try CatalogTOML.parse(text) } catch { throw Failure.invalidConfig }
        let overrides: Set<String> = ["profile", "profiles", "forced_login_method", "forced_chatgpt_workspace_id", "chatgpt_base_url"]
        guard overrides.isDisjoint(with: root.entries.keys) else { throw Failure.overrides }
        if let store = root.entries["cli_auth_credentials_store"] {
            guard case .string("file") = store else { throw Failure.overrides }
        }
        let provider: String
        if let value = root.entries["model_provider"] {
            guard case let .string(id) = value, !id.isEmpty else { throw Failure.invalidConfig }
            provider = id
        } else { provider = "openai" }
        if case let .table(definitions)? = root.entries["model_providers"], definitions.entries["openai"] != nil {
            throw Failure.unsupportedProvider
        }
        let currentKey: String?
        if let auth = snapshot.auth { currentKey = try apiKey(auth) }
        else { currentKey = nil }
        if provider == "openai" {
            guard snapshot.auth != nil else { throw Failure.missingAuth }
            if currentKey == nil {
                guard let override = root.entries["openai_base_url"] else { return (snapshot, false) }
                guard case let .string(endpoint) = override else { throw Failure.oauthRoute }
                do { try requireLoopback(endpoint) } catch { throw Failure.oauthRoute }
                return (Snapshot(config: try removeOwnedEndpoint(text), auth: snapshot.auth), false)
            }
            guard case let .string(endpoint)? = root.entries["openai_base_url"] else { throw Failure.unsafeEndpoint }
            try requireLoopback(endpoint)
            return (snapshot, true)
        }
        guard case let .table(definitions)? = root.entries["model_providers"],
              case let .table(definition)? = definitions.entries[provider],
              case let .string(endpoint)? = definition.entries["base_url"] else { throw Failure.unsupportedProvider }
        let supported: Set<String> = ["name", "base_url", "wire_api", "requires_openai_auth", "experimental_bearer_token"]
        guard Set(definition.entries.keys).isSubset(of: supported) else { throw Failure.unsupportedProvider }
        if let wire = definition.entries["wire_api"] {
            guard case .string("responses") = wire else { throw Failure.unsupportedProvider }
        }
        try requireLoopback(endpoint)
        let targetAuth: Data?
        if case .bool(false)? = definition.entries["requires_openai_auth"],
           case let .string(token)? = definition.entries["experimental_bearer_token"] {
            guard (1...8_192).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw Failure.invalidAuth }
            if currentKey == token { targetAuth = snapshot.auth }
            else {
                targetAuth = try JSONSerialization.data(withJSONObject: ["auth_mode": "apikey", "OPENAI_API_KEY": token], options: [.sortedKeys])
            }
        } else {
            guard definition.entries["experimental_bearer_token"] == nil,
                  case .bool(true)? = definition.entries["requires_openai_auth"] else { throw Failure.unsupportedProvider }
            guard snapshot.auth != nil else { throw Failure.missingAuth }
            guard currentKey != nil else { throw Failure.oauthRoute }
            targetAuth = snapshot.auth
        }
        return (Snapshot(config: try rewrite(text, endpoint: endpoint), auth: targetAuth), true)
    }

    private func requireClosed() throws {
        let active: Bool
        do { active = try clientsAreRunning() } catch { throw Failure.clientsUnknown }
        guard !active else { throw Failure.clientsActive }
    }

    private func requireLoopback(_ endpoint: String) throws {
        guard (1...8_192).contains(endpoint.utf8.count),
              endpoint.utf8.allSatisfy({ (33...126).contains($0) && $0 != 92 }),
              endpoint.range(of: #"%(?![0-9A-Fa-f]{2})"#, options: .regularExpression) == nil,
              let components = URLComponents(string: endpoint), components.url != nil,
              components.scheme == "http" || components.scheme == "https",
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              let separator = endpoint.range(of: "://") else { throw Failure.unsafeEndpoint }
        let authority = endpoint[separator.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }.lowercased()
        guard authority.range(of: #"^(?:127\.0\.0\.1|localhost|\[::1\])(?::[0-9]{1,5})?$"#, options: .regularExpression) != nil,
              components.port == nil || (1...65_535).contains(components.port!) else { throw Failure.unsafeEndpoint }
    }

    private func rewrite(_ text: String, endpoint: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var lines = text.components(separatedBy: "\n")
        let newline = text.contains("\r\n") ? "\r" : ""
        var replacements = ["model_provider": "openai", "openai_base_url": endpoint]
        var insertion = lines.last == "" ? lines.count - 1 : lines.count
        for index in lines.indices {
            let hasCR = lines[index].hasSuffix("\r")
            let line = hasCR ? String(lines[index].dropLast()) : lines[index]
            let bytes = Array(line.utf8)
            var lexer = CatalogLine(bytes: bytes)
            lexer.skipSpace()
            if lexer.finished || lexer.peek == 35 { continue }
            if lexer.peek == 91 { insertion = index; break }
            let key = try lexer.simpleAssignmentKey()
            let start = lexer.index
            _ = try lexer.value(depth: 0)
            guard let replacement = replacements.removeValue(forKey: key) else { continue }
            let literal = try encoder.encode(replacement)
            lines[index] = String(decoding: bytes[..<start], as: UTF8.self) + String(decoding: literal, as: UTF8.self)
                + String(decoding: bytes[lexer.index...], as: UTF8.self) + (hasCR ? "\r" : "")
            if key == "openai_base_url", !line.trimmingCharacters(in: .whitespaces).hasSuffix(Self.endpointMarker) {
                if hasCR { lines[index].removeLast() }
                lines[index] += " " + Self.endpointMarker + (hasCR ? "\r" : "")
            }
        }
        var added = try ["model_provider", "openai_base_url"].compactMap { key -> String? in
            guard let value = replacements[key] else { return nil }
            let marker = key == "openai_base_url" ? " " + Self.endpointMarker : ""
            return key + " = " + String(decoding: try encoder.encode(value), as: UTF8.self) + marker + newline
        }
        if insertion == lines.count, !text.hasSuffix("\n"), added.last?.hasSuffix("\r") == true { added[added.count - 1].removeLast() }
        lines.insert(contentsOf: added, at: insertion)
        let output = lines.joined(separator: "\n")
        let parsed = try CatalogTOML.parse(output)
        guard case .string("openai")? = parsed.entries["model_provider"],
              case .string(endpoint)? = parsed.entries["openai_base_url"] else { throw Failure.invalidConfig }
        return Data(output.utf8)
    }

    private func removeOwnedEndpoint(_ text: String) throws -> Data {
        var lines = text.components(separatedBy: "\n")
        for index in lines.indices {
            let line = lines[index].hasSuffix("\r") ? String(lines[index].dropLast()) : lines[index]
            var lexer = CatalogLine(bytes: Array(line.utf8))
            lexer.skipSpace()
            if lexer.finished || lexer.peek == 35 { continue }
            if lexer.peek == 91 { break }
            let key = try lexer.simpleAssignmentKey()
            _ = try lexer.value(depth: 0)
            guard key == "openai_base_url" else { continue }
            let comment = String(decoding: lexer.bytes[lexer.index...], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard comment.hasPrefix("#"), comment.hasSuffix(Self.endpointMarker) else { throw Failure.oauthRoute }
            lines.remove(at: index)
            let output = lines.joined(separator: "\n")
            guard try CatalogTOML.parse(output).entries["openai_base_url"] == nil else { throw Failure.invalidConfig }
            return Data(output.utf8)
        }
        throw Failure.oauthRoute
    }

    private func checkPending() throws {
        try NativeFileSafety.noSymlinks(pendingFile)
        var info = stat()
        if lstat(pendingFile.path, &info) != 0 {
            guard errno == ENOENT else { throw Failure.unsafeFiles }
            return
        }
        let data = try ownedFile(pendingFile, limit: 65_536)
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              record["home"] == home.path, let path = record["backup_path"],
              NativeFileSafety.within(try NativeFileSafety.validated(URL(fileURLWithPath: path)), backupDirectory) else {
            throw Failure.pending
        }
        backupPath = path
        throw Failure.pending
    }

    private func save(_ desired: Snapshot, expected: Snapshot) throws {
        let directory: URL
        do {
            try NativeFileSafety.noSymlinks(backupDirectory)
            guard !NativeFileSafety.within(backupDirectory, home) else { throw Failure.backup }
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try ownedDirectory(backupDirectory)
            guard chmod(backupDirectory.path, 0o700) == 0 else { throw Failure.backup }
            directory = backupDirectory.appendingPathComponent("configuration-" + UUID().uuidString, isDirectory: true)
            guard mkdir(directory.path, 0o700) == 0 else { throw Failure.backup }
            let original = directory.appendingPathComponent("config.toml")
            try NativeFileSafety.writeExclusive(expected.config, to: original)
            backupPath = original.path
            if let auth = expected.auth { try NativeFileSafety.writeExclusive(auth, to: directory.appendingPathComponent("auth.json")) }
            else { try NativeFileSafety.writeExclusive(Data("原 auth.json 不存在\n".utf8), to: directory.appendingPathComponent("auth-originally-absent")) }
            try writeReceipt(directory, authExisted: expected.auth != nil, configWritten: false, authWritten: false, complete: false)
            try NativeFileSafety.syncDirectory(directory)
            try NativeFileSafety.syncDirectory(backupDirectory)
        } catch { throw Failure.backup }
        let configTemporary = home.appendingPathComponent(".miruun-config-" + UUID().uuidString + ".tmp")
        let authTemporary = home.appendingPathComponent(".miruun-auth-" + UUID().uuidString + ".tmp")
        defer { _ = unlink(configTemporary.path); _ = unlink(authTemporary.path) }
        do {
            if desired.config != expected.config { try NativeFileSafety.writeExclusive(desired.config, to: configTemporary) }
            if desired.auth != expected.auth {
                guard let auth = desired.auth else { throw Failure.write }
                try NativeFileSafety.writeExclusive(auth, to: authTemporary)
            }
        } catch { throw Failure.write }
        try requireClosed()
        guard try readSnapshot() == expected else { throw Failure.conflict }
        do {
            let record = try JSONSerialization.data(withJSONObject: ["home": home.path, "backup_path": backupPath!], options: [.sortedKeys])
            transactionStarted = true
            try NativeFileSafety.writeExclusive(record, to: pendingFile)
            try NativeFileSafety.syncDirectory(backupDirectory)
            var configWritten = false, authWritten = false
            if desired.auth != expected.auth {
                try requireClosed()
                guard try readSnapshot() == expected else { throw Failure.conflict }
                let path = home.appendingPathComponent("auth.json").path
                let result = expected.auth == nil ? renamex_np(authTemporary.path, path, UInt32(RENAME_EXCL)) : rename(authTemporary.path, path)
                guard result == 0 else { throw Failure.write }
                try NativeFileSafety.syncDirectory(home)
                authWritten = true
                try writeReceipt(directory, authExisted: expected.auth != nil, configWritten: false, authWritten: true, complete: false)
            }
            if desired.config != expected.config {
                try requireClosed()
                guard try readSnapshot() == Snapshot(config: expected.config, auth: desired.auth) else { throw Failure.conflict }
                guard rename(configTemporary.path, home.appendingPathComponent("config.toml").path) == 0 else { throw Failure.write }
                try NativeFileSafety.syncDirectory(home)
                configWritten = true
                try writeReceipt(directory, authExisted: expected.auth != nil, configWritten: true, authWritten: authWritten, complete: false)
            }
            guard try readSnapshot() == desired else { throw Failure.conflict }
            try writeReceipt(directory, authExisted: expected.auth != nil, configWritten: configWritten, authWritten: authWritten, complete: true)
            guard unlink(pendingFile.path) == 0 else { throw Failure.write }
            try NativeFileSafety.syncDirectory(backupDirectory)
            transactionStarted = false
        } catch let failure as Failure { throw failure }
        catch { throw Failure.write }
    }

    private func writeReceipt(_ directory: URL, authExisted: Bool, configWritten: Bool, authWritten: Bool, complete: Bool) throws {
        let data = try JSONSerialization.data(withJSONObject: ["auth_existed": authExisted, "config_written": configWritten, "auth_written": authWritten, "complete": complete], options: [.sortedKeys])
        let temporary = directory.appendingPathComponent(".receipt-" + UUID().uuidString)
        defer { _ = unlink(temporary.path) }
        try NativeFileSafety.writeExclusive(data, to: temporary)
        guard rename(temporary.path, directory.appendingPathComponent("receipt.json").path) == 0 else { throw Failure.write }
        try NativeFileSafety.syncDirectory(directory)
    }
}
