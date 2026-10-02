import Foundation
import Darwin

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
/// it never opens sessions/databases, starts a backend, or changes auth.json.
/// Two stable samples and a final byte comparison detect observed conflicts.
/// Atomic rename is not a compare-and-swap: a writer that ignores this guard can
/// still replace config/auth after the final check. Stop it before restarting GUI.
public final class ContinuityGuard {
    private struct Snapshot: Equatable {
        let config: Data
        let auth: Data
    }

    private enum Failure: Error {
        case unsafeFiles, invalidConfig, invalidAuth, unsupportedAuth, overrides
        case unsupportedProvider, unsafeEndpoint, oauthRoute, conflict, backup, write

        var message: String {
            switch self {
            case .unsafeFiles: return "配置或登录文件无法安全读取；需要当前用户拥有的普通文件，不能使用链接或超限文件。"
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
            }
        }
    }

    private let home: URL
    private let backupDirectory: URL
    private static let endpointMarker = "# miruun-managed-openai-base-url"
    private var previous: Snapshot?
    private var backupPath: String?

    public init(home: URL, backupDirectory: URL) {
        self.home = home
        self.backupDirectory = backupDirectory
    }

    public func check() -> ContinuityStatus {
        backupPath = nil
        do {
            let snapshot = try readSnapshot()
            let apiKey = try apiKeyReady(snapshot.auth)
            let replacement = try replacementConfig(snapshot.config, apiKey: apiKey)
            guard let replacement else {
                previous = snapshot
                return apiKey
                    ? ContinuityStatus(phase: .ready, message: "本机代理配置已就绪；请重启 Codex 后核对续聊与账号。")
                    : ContinuityStatus(phase: .waiting, message: "当前为 ChatGPT/OAuth 登录且无地址覆盖；保持官方入口，不修改凭据。")
            }
            guard previous == snapshot else {
                previous = snapshot
                return ContinuityStatus(phase: .waiting, message: apiKey
                    ? "检测到接入配置，等待下一次相同采样后保存。"
                    : "检测到 OAuth 回切，等待下一次相同采样后移除 Miruun 的本机地址覆盖。")
            }
            try save(replacement, expected: snapshot)
            previous = Snapshot(config: replacement, auth: snapshot.auth)
            return ContinuityStatus(phase: .updated, message: apiKey
                ? "已备份并更新连接配置；请停止其他配置写入并重启 Codex，再核对续聊与账号。"
                : "已备份并移除 Miruun 的本机地址覆盖，未改 provider 或凭据；请停止其他配置写入并重启 GUI，核对 OAuth 登录。", backupPath: backupPath)
        } catch {
            previous = nil
            return ContinuityStatus(phase: .blocked, message: (error as? Failure)?.message ?? Failure.unsafeFiles.message, backupPath: backupPath)
        }
    }

    private func readSnapshot() throws -> Snapshot {
        try ownedDirectory(home)
        return Snapshot(config: try ownedFile(home.appendingPathComponent("config.toml"), limit: 1_024 * 1_024),
                        auth: try ownedFile(home.appendingPathComponent("auth.json"), limit: 65_536))
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
        guard lstat(url.path, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
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

    private func apiKeyReady(_ data: Data) throws -> Bool {
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
            return false
        }
        guard let key, (1...8_192).contains(key.utf8.count), key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw Failure.invalidAuth
        }
        return true
    }

    private func replacementConfig(_ data: Data, apiKey: Bool) throws -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.invalidConfig }
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
        if !apiKey {
            guard provider == "openai" else { throw Failure.oauthRoute }
            guard let override = root.entries["openai_base_url"] else { return nil }
            guard case let .string(endpoint) = override else { throw Failure.oauthRoute }
            do { try requireLoopback(endpoint) } catch { throw Failure.oauthRoute }
            return try removeOwnedEndpoint(text)
        }
        if provider == "openai" {
            guard case let .string(endpoint)? = root.entries["openai_base_url"] else { throw Failure.unsafeEndpoint }
            try requireLoopback(endpoint)
            return nil
        }
        guard case let .table(definitions)? = root.entries["model_providers"],
              case let .table(definition)? = definitions.entries[provider],
              case let .string(endpoint)? = definition.entries["base_url"],
              case .bool(true)? = definition.entries["requires_openai_auth"] else { throw Failure.unsupportedProvider }
        let supported: Set<String> = ["name", "base_url", "wire_api", "requires_openai_auth"]
        guard Set(definition.entries.keys).isSubset(of: supported) else { throw Failure.unsupportedProvider }
        if let wire = definition.entries["wire_api"] {
            guard case .string("responses") = wire else { throw Failure.unsupportedProvider }
        }
        try requireLoopback(endpoint)
        return try rewrite(text, endpoint: endpoint)
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

    private func save(_ data: Data, expected: Snapshot) throws {
        do {
            try NativeFileSafety.noSymlinks(backupDirectory)
            guard !NativeFileSafety.within(backupDirectory, home) else { throw Failure.backup }
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try ownedDirectory(backupDirectory)
            guard chmod(backupDirectory.path, 0o700) == 0 else { throw Failure.backup }
            let directory = backupDirectory.appendingPathComponent("configuration-" + UUID().uuidString, isDirectory: true)
            guard mkdir(directory.path, 0o700) == 0 else { throw Failure.backup }
            let original = directory.appendingPathComponent("config.toml")
            try NativeFileSafety.writeExclusive(expected.config, to: original)
            backupPath = original.path
            try NativeFileSafety.syncDirectory(directory)
            try NativeFileSafety.syncDirectory(backupDirectory)
        } catch { throw Failure.backup }
        let temporary = home.appendingPathComponent(".miruun-config-" + UUID().uuidString + ".tmp")
        defer { _ = unlink(temporary.path) }
        do { try NativeFileSafety.writeExclusive(data, to: temporary) } catch { throw Failure.write }
        guard try readSnapshot() == expected else { throw Failure.conflict }
        guard rename(temporary.path, home.appendingPathComponent("config.toml").path) == 0 else { throw Failure.write }
        do { try NativeFileSafety.syncDirectory(home) } catch { throw Failure.write }
    }
}
