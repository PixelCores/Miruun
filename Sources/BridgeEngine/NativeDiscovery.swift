import Foundation
import Darwin

public struct BackendCapabilities {
    public let version: String
    public let sourceAuditedCandidate: Bool
    public let indexedCatalog: Bool
}

public enum NativeDiscovery {
    /// Finds only global configuration directory paths and file metadata. The
    /// desktop host merges login-shell variables into its inherited environment;
    /// an unset shell variable therefore leaves an inherited override intact.
    /// Invalid explicit overrides never fall back to another directory.
    public static func configurationDirectories(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        codexOverride: String? = nil,
        shell: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> (
        codex: (directory: URL?, source: String, error: String?),
        claude: (directory: URL?, source: String, error: String?)
    ) {
        let executable: URL
        if let shell { executable = shell }
        else {
            guard let value = getpwuid(getuid())?.pointee.pw_shell,
                  !String(cString: value).isEmpty else {
                throw NativeEngineError("configuration_shell_unknown", "无法确认登录 shell；未检测配置目录。")
            }
            executable = URL(fileURLWithPath: String(cString: value))
        }
        let inherited = environment ?? ProcessInfo.processInfo.environment
        var variables = inherited
        variables["CODEX_SHELL"] = "1"
        variables["DISABLE_AUTO_UPDATE"] = "true"
        variables["ZSH_TMUX_AUTOSTARTED"] = "true"
        variables["ZSH_TMUX_AUTOSTART"] = "false"
        // Reject framing delimiters before they can be mistaken for path endings.
        let command = #"""
        case "${CODEX_HOME-}${CLAUDE_CONFIG_DIR-}" in
            *"$(printf '\036')"*|*"$(printf '\037')"*) exit 1;;
        esac
        printf '\036MIRUUN_CONFIG_DIRECTORY\037CODEX_HOME\037%s\037%s\036' "${CODEX_HOME+x}" "${CODEX_HOME-}"
        printf '\036MIRUUN_CONFIG_DIRECTORY\037CLAUDE_CONFIG_DIR\037%s\037%s\036' "${CLAUDE_CONFIG_DIR+x}" "${CLAUDE_CONFIG_DIR-}"
        """#
        let output: String
        do {
            output = try runTool(executable, ["-ilc", command], environment: variables, timeout: 10)
        } catch {
            throw NativeEngineError("configuration_shell_failed", "无法读取登录 shell 的配置目录；请检查 shell 后重新检测。")
        }
        let codexMarker = "\u{1e}MIRUUN_CONFIG_DIRECTORY\u{1f}CODEX_HOME\u{1f}"
        let claudeMarker = "\u{1e}MIRUUN_CONFIG_DIRECTORY\u{1f}CLAUDE_CONFIG_DIR\u{1f}"
        guard let codexRange = output.range(of: codexMarker, options: .backwards),
              let claudeRange = output.range(of: claudeMarker, options: .backwards),
              codexRange.upperBound <= claudeRange.lowerBound else {
            throw NativeEngineError("configuration_shell_failed", "登录 shell 未完整返回配置目录；请检查 shell 后重新检测。")
        }
        let records = [output[codexRange.upperBound..<claudeRange.lowerBound], output[claudeRange.upperBound...]]
        var results: [(directory: URL?, source: String, error: String?)] = []
        for (index, key) in ["CODEX_HOME", "CLAUDE_CONFIG_DIR"].enumerated() {
            let record = records[index]
            guard record.last == "\u{1e}", !record.dropLast().contains("\u{1e}") else {
                throw NativeEngineError("configuration_shell_failed", "登录 shell 返回的配置目录边界未知；未使用默认目录。")
            }
            let fields = record.dropLast().split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0] == "x" || fields[0].isEmpty,
                  fields[0] == "x" || fields[1].isEmpty else {
                throw NativeEngineError("configuration_shell_failed", "登录 shell 返回的配置目录格式未知；未使用默认目录。")
            }
            let manual = key == "CODEX_HOME" ? codexOverride : nil
            let override = manual ?? (fields[0] == "x" ? String(fields[1]) : inherited[key])
            let source = manual != nil ? "手动选择" : override == nil ? "默认目录" : fields[0] == "x" && override != inherited[key] ? key + "（登录 shell）" : key
            let defaultName = index == 0 ? ".codex" : ".claude"
            let path = override ?? home.appendingPathComponent(defaultName, isDirectory: true).path
            results.append(configurationDirectory(path, source: source, name: key))
        }
        return (codex: results[0], claude: results[1])
    }

    private static func configurationDirectory(_ path: String, source: String, name: String) -> (directory: URL?, source: String, error: String?) {
        let components = path.split(separator: "/")
        guard path.hasPrefix("/"), !components.contains("."), !components.contains(".."),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return (nil, source, name + " 必须指向绝对、无点路径的配置目录。")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        do { try NativeFileSafety.noSymlinks(directory) }
        catch { return (nil, source, name + " 配置目录包含符号链接或无法安全访问。") }
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            return (nil, source, name + (errno == ENOENT ? " 配置目录不存在。" : " 配置目录无法访问。"))
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            return (nil, source, name + " 指向普通文件，而不是配置目录。")
        }
        return (directory, source, nil)
    }

    /// The desktop app merges its interactive login shell environment before
    /// spawning the local backend. Reject a conflicting CODEX_HOME without
    /// capturing or displaying the complete environment.
    public static func verifyLaunchHome(_ home: URL, shell: URL? = nil, environment: [String: String]? = nil) throws {
        let executable: URL
        if let shell { executable = shell }
        else {
            guard let value = getpwuid(getuid())?.pointee.pw_shell,
                  !String(cString: value).isEmpty else {
                throw NativeEngineError("launch_shell_unknown", "无法确认登录 shell；未启动 Codex。")
            }
            executable = URL(fileURLWithPath: String(cString: value))
        }
        var variables = environment ?? ProcessInfo.processInfo.environment
        variables["CODEX_HOME"] = home.path
        variables["CODEX_SHELL"] = "1"
        variables["DISABLE_AUTO_UPDATE"] = "true"
        variables["ZSH_TMUX_AUTOSTARTED"] = "true"
        variables["ZSH_TMUX_AUTOSTART"] = "false"
        let output: String
        do {
            output = try runTool(executable, ["-ilc", #"printf '\036MIRUUN_CODEX_HOME\037%s\036' "$CODEX_HOME""#], environment: variables, timeout: 10)
        } catch {
            throw NativeEngineError("launch_shell_failed", "无法核对登录 shell 使用的数据目录；未启动 Codex。")
        }
        let marker = "\u{1e}MIRUUN_CODEX_HOME\u{1f}"
        guard let range = output.range(of: marker, options: .backwards),
              output[range.upperBound...] == home.path + "\u{1e}" else {
            throw NativeEngineError("launch_home_overridden", "登录 shell 覆盖了 Codex 数据目录；请移除该覆盖或选择相同目录后重试。")
        }
    }

    /// Captures only bounded tool stdout; caller never surfaces arbitrary tool errors.
    public static func runTool(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil, cwd: URL? = nil, timeout: TimeInterval = 30) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.environment = environment; process.currentDirectoryURL = cwd
        do { try process.run() } catch { throw NativeEngineError("tool_start_failed", "无法启动选中的本地工具") }
        let lock = NSLock(), finished = DispatchSemaphore(value: 0)
        var data = Data(); var oversized = false; var readFailed = false
        DispatchQueue.global().async {
            defer { finished.signal() }
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count) }
                if n < 0 { if errno == EINTR { continue }; lock.lock(); readFailed = true; lock.unlock(); break }; if n == 0 { break }
                lock.lock()
                if data.count + n <= 1_048_576 { data.append(contentsOf: buffer.prefix(n)) } else { oversized = true }
                lock.unlock()
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(10000) }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate(); let stop = Date().addingTimeInterval(2)
            while process.isRunning && Date() < stop { usleep(10000) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        guard finished.wait(timeout: .now() + 3) == .success else { try? output.fileHandleForReading.close(); throw NativeEngineError("tool_drain_failed", "本地工具输出未完整结束") }
        try? output.fileHandleForReading.close()
        lock.lock(); let captured = data, tooLarge = oversized, failedRead = readFailed; lock.unlock()
        guard !timedOut, !tooLarge, !failedRead, process.terminationStatus == 0, let text = String(data: captured, encoding: .utf8) else {
            throw NativeEngineError("tool_failed", "本地工具未完成兼容性检查，原始输出未显示")
        }
        return text
    }

    public static func probe(backend: URL) throws -> BackendCapabilities {
        let manager = FileManager.default
        let root = try NativeFileSafety.temporaryDirectory().appendingPathComponent("miruun-probe-" + UUID().uuidString, isDirectory: true)
        do { try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw NativeEngineError("probe_directory_failed", "无法创建私有临时探测目录") }
        defer { try? manager.removeItem(at: root) }
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["PATH", "LANG", "LC_ALL", "LC_CTYPE"] { environment[key] = inherited[key] }
        environment["HOME"] = root.path; environment["CODEX_HOME"] = root.path
        environment["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        environment["XDG_CACHE_HOME"] = root.appendingPathComponent("cache").path
        let version = try runTool(backend, ["--version"], environment: environment, cwd: root, timeout: 15).trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.count < 100, version.range(of: #"^codex-cli [0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.\-]+)?$"#, options: .regularExpression) != nil else {
            throw NativeEngineError("unknown_backend", "后端版本格式未知，未显示原始输出")
        }
        let output = root.appendingPathComponent("schema", isDirectory: true)
        _ = try runTool(backend, ["app-server", "generate-json-schema", "--experimental", "--out", output.path], environment: environment, cwd: root)
        let requirements: [String: Set<String>] = [
            "ThreadResumeParams": ["threadId", "modelProvider", "model", "excludeTurns"],
            "ThreadQueueListParams": ["threadId", "limit"],
            "ExperimentalFeatureListParams": ["limit"],
            "ThreadReadParams": ["threadId", "includeTurns"]
        ]
        var properties: [String: Set<String>] = [:]
        let names = Set(requirements.keys).union(["ThreadListParams"])
        guard let files = manager.enumerator(at: output, includingPropertiesForKeys: nil) else { throw NativeEngineError("schema_missing", "没有获得后端schema") }
        for case let file as URL in files where file.pathExtension == "json" && names.contains(file.deletingPathExtension().lastPathComponent) {
            let name = file.deletingPathExtension().lastPathComponent
            guard properties[name] == nil, let object = try? JSONSerialization.jsonObject(with: NativeFileSafety.readRegular(file, limit: 16 * 1024 * 1024)), let schema = object as? [String: Any], let fields = schema["properties"] as? [String: Any] else {
                throw NativeEngineError("schema_invalid", "后端schema缺失、重复或结构未知")
            }
            properties[name] = Set(fields.keys)
        }
        let complete = requirements.allSatisfy { name, fields in fields.isSubset(of: properties[name] ?? []) }
        let indexed = Set(["modelProviders", "useStateDbOnly"]).isSubset(of: properties["ThreadListParams"] ?? [])
        return BackendCapabilities(version: version, sourceAuditedCandidate: complete && EnginePolicy.auditedVersions.contains(version), indexedCatalog: indexed)
    }

    public static func activeClients(backend: URL, processText: String? = nil) throws -> [[String: Any]] {
        let text = try processText ?? runTool(URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,comm="], timeout: 5)
        let names: Set<String> = ["codex", "codex-cli", "codex-app-server", "chatgpt", "codex.app", backend.lastPathComponent.lowercased()]
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let pid = Int(parts[0]) else { return nil }
            let path = String(parts[1]), name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            let bundle = path.split(separator: "/").reversed().first(where: { $0.lowercased().hasSuffix(".app") }).map { String($0.dropLast(4)).lowercased() } ?? ""
            let knownBundle = ["chatgpt", "codex", "codexcli"].contains(bundle) || bundle.hasPrefix("chatgpt helper") || bundle.hasPrefix("codex helper")
            guard names.contains(name) || name.hasPrefix("codex-") || knownBundle else { return nil }
            return ["pid": pid, "executable": URL(fileURLWithPath: path).lastPathComponent]
        }
    }

    public static func applications(roots: [URL]? = nil) -> [String: Any] {
        let manager = FileManager.default
        let roots = roots ?? [URL(fileURLWithPath: "/Applications"), manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var apps: [[String: Any]] = []
        for root in roots {
            guard let top = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            var candidates = top.filter { $0.pathExtension == "app" }
            for folder in top where folder.pathExtension != "app" {
                if let children = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) { candidates += children.filter { $0.pathExtension == "app" } }
            }
            for app in candidates {
                let plist = app.appendingPathComponent("Contents/Info.plist")
                guard let data = try? NativeFileSafety.readRegular(plist, limit: 2 * 1024 * 1024), let value = try? PropertyListSerialization.propertyList(from: data, format: nil), let info = value as? [String: Any] else { continue }
                let identifier = info["CFBundleIdentifier"] as? String ?? ""
                let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent
                guard ["openai", "chatgpt", "codex"].contains(where: { (identifier + " " + name).lowercased().contains($0) }) else { continue }
                var backends: [String] = []
                for folder in ["Contents/MacOS", "Contents/Resources"] {
                    if let files = manager.enumerator(at: app.appendingPathComponent(folder), includingPropertiesForKeys: [.isRegularFileKey]) {
                        for case let file as URL in files where ["codex", "codex-cli", "codex-aarch64-apple-darwin", "codex-x86_64-apple-darwin"].contains(file.lastPathComponent) {
                            if manager.isExecutableFile(atPath: file.path) { backends.append(file.resolvingSymlinksInPath().path) }
                        }
                    }
                }
                apps.append(["bundle": app.path, "name": name, "bundle_id": identifier,
                             "version": info["CFBundleShortVersionString"] as? String ?? "unknown", "build": info["CFBundleVersion"] as? String ?? "unknown",
                             "executable": info["CFBundleExecutable"] as? String ?? "", "backend_candidates": Array(Set(backends)).sorted()])
            }
        }
        return ["platform": "Darwin", "apps": apps, "note": "仅发现应用元数据和候选后端；未执行候选或验证签名"]
    }
}
