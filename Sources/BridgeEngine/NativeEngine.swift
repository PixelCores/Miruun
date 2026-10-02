import Foundation

public struct EngineServices {
    public var probe: (URL) throws -> BackendCapabilities
    public var openRPC: (URL, URL) throws -> EngineRPC
    public var activeClients: (URL) throws -> [[String: Any]]
    public var catalog: (URL) throws -> ProviderCatalogResult
    public var backup: (URL, URL, URL, String, Bool) throws -> [String: Any]
    public init(probe: @escaping (URL) throws -> BackendCapabilities,
                openRPC: @escaping (URL, URL) throws -> EngineRPC,
                activeClients: @escaping (URL) throws -> [[String: Any]],
                catalog: @escaping (URL) throws -> ProviderCatalogResult,
                backup: @escaping (URL, URL, URL, String, Bool) throws -> [String: Any]) {
        self.probe = probe; self.openRPC = openRPC; self.activeClients = activeClients; self.catalog = catalog; self.backup = backup
    }
    public static var live: EngineServices {
        EngineServices(probe: { try NativeDiscovery.probe(backend: $0) }, openRPC: { try NativeRPC(backend: $0, home: $1) },
                       activeClients: { try NativeDiscovery.activeClients(backend: $0) }, catalog: { try NativeProviderCatalog.read(home: $0) },
                       backup: { try NativeBackup.create(home: $0, rollout: $1, destination: $2, threadID: $3, consentSharedState: $4) })
    }
}

public final class NativeEngine {
    private let services: EngineServices
    public init(services: EngineServices = .live) { self.services = services }
    private func same(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        guard let left = try? JSONSerialization.data(withJSONObject: a, options: .sortedKeys),
              let right = try? JSONSerialization.data(withJSONObject: b, options: .sortedKeys) else { return false }
        return left == right
    }
    private func state(_ request: [String: Any], home: URL) throws -> NativeStateStore {
        let root = (request["state_directory"] as? String).map(EnginePolicy.path) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Miruun")
        guard !NativeFileSafety.within(root, home) else { throw NativeEngineError("unsafe_state_directory", "应用记录目录必须位于 CODEX_HOME 外") }
        return try NativeStateStore(root: root)
    }
    private func requireClosed(_ backend: URL) throws {
        guard try services.activeClients(backend).isEmpty else { throw NativeEngineError("clients_active", "检测到 GUI/后端仍在运行；请正常关闭，工具不会强制结束它们") }
    }
    private func withRPC<T>(_ backend: URL, _ home: URL, _ body: (EngineRPC) throws -> T) throws -> T {
        let rpc = try services.openRPC(backend, home); defer { rpc.close() }; return try body(rpc)
    }
    public static func identity(_ record: [String: Any], expectedID: String) throws -> [String: Any] {
        guard record["id"] as? String == expectedID else { throw NativeEngineError("wrong_thread_id", "后端未返回选中的原线程 ID") }
        return ["thread_id": expectedID, "name": EnginePolicy.null(record["name"] as? String), "cwd": EnginePolicy.null(record["cwd"] as? String),
                "model": EnginePolicy.null(record["model"] as? String), "model_provider": EnginePolicy.null(record["modelProvider"] as? String)]
    }
    private func destination(_ catalog: ProviderCatalogResult, _ id: String) throws -> [String: Any] {
        guard let item = catalog.providers.first(where: { $0.id == id }), item.selectable, let origin = item.endpointOrigin else {
            throw NativeEngineError("destination_unknown", "目标供应商的配置地址未知或无效，不能猜测后切换")
        }
        return ["provider": id, "endpoint_origin": origin]
    }
    private func capabilities(_ backend: URL) throws -> BackendCapabilities {
        let value = try services.probe(backend)
        guard EnginePolicy.auditedVersions.contains(value.version), value.sourceAuditedCandidate else {
            throw NativeEngineError("unsupported_backend", "后端不在精确版本与协议候选中")
        }
        return value
    }
    public func handle(_ request: [String: Any], emit: @escaping ([String: Any]) throws -> Void = { _ in }) throws -> [String: Any] {
        guard request["protocol_version"] as? Int == EnginePolicy.protocolVersion else { throw NativeEngineError("unsupported_protocol", "不支持的本地协议版本") }
        let command = try EnginePolicy.text(request, "command", limit: 64)
        if command == "discover" { return NativeDiscovery.applications() }
        guard ["catalog", "verify", "preflight", "switch"].contains(command) else { throw NativeEngineError("unknown_command", "未知的本地操作") }
        let backend = EnginePolicy.path(try EnginePolicy.text(request, "backend"))
        let rawHome = try EnginePolicy.text(request, "home")
        guard rawHome.hasPrefix("/"), !rawHome.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else {
            throw NativeEngineError("unsafe_home", "请选择绝对、无点路径的 CODEX_HOME，不自动解析目录别名")
        }
        let home = URL(fileURLWithPath: rawHome)
        if command == "switch" { return try switchThread(request, backend: backend, home: home, emit: emit) }
        guard EnginePolicy.isTrue(request["confirm_native"]) else { throw NativeEngineError("native_consent_required", "需要明确允许启动选中后端作本地只读检查") }
        let store = try state(request, home: home)
        do {
            return try store.withLock {
                try requireClosed(backend)
                if command == "catalog" { return try catalog(request, backend: backend, home: home) }
                if command == "preflight" { return try preflight(request, backend: backend, home: home, store: store) }
                let id = try EnginePolicy.text(request, "thread_id", limit: 128)
                let record = try withRPC(backend, home) { try $0.call("thread/read", ["threadId": id, "includeTurns": false])["thread"] as? [String: Any] ?? [:] }
                return ["identity": try Self.identity(record, expectedID: id), "verification": "metadata_only", "gui_verified": false,
                        "effective_route_verified": false, "notice": "元数据不是有效路由证明；未恢复或再次切换"]
            }
        } catch NativeStorageError.operationBusy { throw NativeEngineError("operation_busy", "已有操作仍在运行，不能同时启动检查，也不清除未决状态", uncertain: true) }
    }
    private func catalog(_ request: [String: Any], backend: URL, home: URL) throws -> [String: Any] {
        let caps = try services.probe(backend), config = try services.catalog(home)
        guard caps.indexedCatalog else { throw NativeEngineError("unsupported_catalog", "后端不支持安全的跨供应商索引查询") }
        var params: [String: Any] = ["modelProviders": [String](), "useStateDbOnly": true, "limit": 100, "archived": EnginePolicy.isTrue(request["archived"])]
        if let search = request["search"] as? String, !search.isEmpty { params["searchTerm"] = try EnginePolicy.text(request, "search", limit: 512) }
        if request["cursor"] != nil { params["cursor"] = try EnginePolicy.text(request, "cursor") }
        let response = try withRPC(backend, home) { try $0.call("thread/list", params) }
        guard let records = response["data"] as? [[String: Any]], records.count <= 100 else { throw NativeEngineError("invalid_catalog", "线程目录结构未知或超出限制") }
        let threads: [[String: Any]] = try records.map { record in
            guard let id = record["id"] as? String else { throw NativeEngineError("invalid_catalog", "目录中的线程标识无效") }
            var result = try Self.identity(record, expectedID: id)
            for (source, target) in [("createdAt", "created_at_utc"), ("updatedAt", "updated_at_utc")] {
                if let value = record[source] as? NSNumber, abs(value.doubleValue) < 253_402_300_799 {
                    result[target] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: value.doubleValue))
                } else { result[target] = NSNull() }
            }
            return result
        }
        let providers: [[String: Any]] = config.providers.map { ["id": $0.id, "name": $0.name, "endpoint_origin": EnginePolicy.null($0.endpointOrigin), "selectable": $0.selectable, "blocker": EnginePolicy.null($0.blocker)] }
        return ["threads": threads, "providers": providers, "backend_version": caps.version, "source_audited_candidate": caps.sourceAuditedCandidate,
                "config_source": "CODEX_HOME/config.toml", "overrides_unknown": true, "next_cursor": EnginePolicy.null(response["nextCursor"])]
    }
    private func preflight(_ request: [String: Any], backend: URL, home: URL, store: NativeStateStore) throws -> [String: Any] {
        guard EnginePolicy.isTrue(request["closed_clients"]) else { throw NativeEngineError("clients_not_confirmed_closed", "请确认所有 GUI/其他后端已退出并全过程保持关闭") }
        let id = try EnginePolicy.text(request, "thread_id", limit: 128), provider = try EnginePolicy.text(request, "provider", limit: 256)
        let cwd = EnginePolicy.path(try EnginePolicy.text(request, "expected_cwd")).path
        let caps = try capabilities(backend), config = try services.catalog(home), target = try destination(config, provider)
        let selected: [String: Any] = try withRPC(backend, home) { rpc in
            try NativeTransaction.verifyDisabledFeatures(rpc); try NativeTransaction.requireEmptyQueue(rpc, threadID: id)
            let record = try rpc.call("thread/read", ["threadId": id, "includeTurns": false])["thread"] as? [String: Any] ?? [:]
            let identity = try Self.identity(record, expectedID: id)
            guard let actualCWD = identity["cwd"] as? String, actualCWD.hasPrefix("/"), EnginePolicy.path(actualCWD).path == cwd else { throw NativeEngineError("wrong_project", "所选线程项目与独立选择的目录不一致，未恢复或修改") }
            guard identity["model"] is String else { throw NativeEngineError("model_unknown", "原线程模型未知，不能使用默认模型代替") }
            if let expected = request["model"] as? String, expected != identity["model"] as? String { throw NativeEngineError("model_changed", "原模型与选择时不一致") }
            if let expectedName = request["expected_name"], !same(["name": expectedName], ["name": identity["name"] ?? NSNull()]) { throw NativeEngineError("identity_changed", "标题与选择时不一致") }
            let status = (record["status"] as? [String: Any])?["type"] as? String ?? record["status"] as? String
            guard status == "idle" || status == "notLoaded" else { throw NativeEngineError("thread_active", "所选线程不是已知空闲状态") }
            guard try rpc.gracefulShutdown() else { throw NativeEngineError("shutdown_failed", "只读检查进程未正常关闭") }
            return identity
        }
        let preflightID = UUID().uuidString.lowercased(), expires = Date().addingTimeInterval(600)
        let manifest: [String: Any] = ["protocol_version": 1, "preflight_id": preflightID, "created_at": EnginePolicy.now(), "expires_at_unix": expires.timeIntervalSince1970,
            "backend": backend.path, "backend_version": caps.version, "home": home.path, "identity": selected, "destination": target,
            "config_revision": config.configRevision, "expected_cwd": cwd, "consumed": false]
        let receipt = try store.write(name: "preflight-\(preflightID).json", value: manifest)
        return ["identity": selected, "destination": target, "model": selected["model"] ?? NSNull(), "expected_cwd": cwd, "preflight_id": preflightID,
                "expires_at": ISO8601DateFormatter().string(from: expires), "can_switch": true, "blockers": [String](), "receipt_path": receipt,
                "overrides_unknown": true, "notice": "地址来自配置预览，运行时覆盖未验证。恢复启动可能传输基础指令/工具元数据并产生认证或初始化网络活动"]
    }
    private func switchThread(_ request: [String: Any], backend: URL, home: URL, emit: @escaping ([String: Any]) throws -> Void) throws -> [String: Any] {
        guard EnginePolicy.consentKeys.allSatisfy({ EnginePolicy.isTrue(request[$0]) }) else { throw NativeEngineError("consent_required", "本次精确目标必须明确确认六项权限与风险") }
        let preflightID = try EnginePolicy.text(request, "preflight_id", limit: 64), id = try EnginePolicy.text(request, "thread_id", limit: 128)
        let provider = try EnginePolicy.text(request, "provider", limit: 256), model = try EnginePolicy.text(request, "model", limit: 256)
        let cwd = EnginePolicy.path(try EnginePolicy.text(request, "expected_cwd")).path, backup = EnginePolicy.path(try EnginePolicy.text(request, "backup_directory"))
        let store = try state(request, home: home)
        do {
            return try store.withLock {
                var manifest = try store.readPreflight(id: preflightID)
                if EnginePolicy.isTrue(manifest["consumed"]) { throw NativeEngineError("preflight_used", "预检已使用，先检查前一次记录，不能重放", uncertain: true) }
                guard let expires = manifest["expires_at_unix"] as? Double, expires.isFinite, Date().timeIntervalSince1970 < expires else { throw NativeEngineError("preflight_expired", "预检已过期，未启动本次变更") }
                guard let original = manifest["identity"] as? [String: Any], let target = manifest["destination"] as? [String: Any],
                      manifest["backend"] as? String == backend.path, manifest["home"] as? String == home.path,
                      original["thread_id"] as? String == id, original["model"] as? String == model,
                      target["provider"] as? String == provider, manifest["expected_cwd"] as? String == cwd else { throw NativeEngineError("preflight_mismatch", "目标与预检绑定不一致，未变更") }
                let baseline = try services.catalog(home)
                guard baseline.configRevision == manifest["config_revision"] as? String, same(try destination(baseline, provider), target) else { throw NativeEngineError("destination_changed", "目标配置已变化，需要重新预检与确认") }
                let operation = UUID().uuidString.lowercased(), receiptName = "operation-" + operation + ".json"
                var receipt: [String: Any] = ["protocol_version": 1, "operation_id": operation, "preflight_id": preflightID, "started_at": EnginePolicy.now(), "identity": original,
                    "destination": target, "backup_directory": backup.path, "stage": "confirmed", "status": "running", "uncertain": false]
                let receiptPath = try store.write(name: receiptName, value: receipt)
                manifest["consumed"] = true; manifest["operation_receipt"] = receiptPath
                _ = try store.write(name: "preflight-\(preflightID).json", value: manifest)
                var mutationMayHaveStarted = false
                func progress(_ stage: String, _ uncertain: Bool) throws {
                    mutationMayHaveStarted = mutationMayHaveStarted || uncertain
                    if stage == "resume_request" || stage == "verification_resume_request" {
                        let current = try services.catalog(home)
                        guard current.configRevision == baseline.configRevision, same(try destination(current, provider), target) else { throw NativeEngineError("destination_changed", "恢复请求前目标配置已变化，停止", uncertain: uncertain) }
                    }
                    receipt["stage"] = stage; receipt["uncertain"] = uncertain; receipt["updated_at"] = EnginePolicy.now()
                    _ = try store.write(name: receiptName, value: receipt)
                    try emit(["type": "progress", "stage": stage, "uncertain": uncertain, "receipt_path": receiptPath])
                }
                func openSafe() throws -> EngineRPC {
                    try requireClosed(backend)
                    let rpc = try services.openRPC(backend, home)
                    do { try NativeTransaction.verifyDisabledFeatures(rpc); return rpc } catch { rpc.close(); throw error }
                }
                do {
                    try progress("candidate_probe", false)
                    let currentCapabilities = try capabilities(backend)
                    guard currentCapabilities.version == manifest["backend_version"] as? String else {
                        throw NativeEngineError("backend_changed", "后端版本与预检不一致，需要重新预检和确认")
                    }
                    try progress("identity_inspection", false)
                    let rpc = try openSafe()
                    let rollout: URL
                    do {
                        defer { rpc.close() }
                        try NativeTransaction.requireEmptyQueue(rpc, threadID: id)
                        let record = try rpc.call("thread/read", ["threadId": id, "includeTurns": false])["thread"] as? [String: Any] ?? [:]
                        let latest = try Self.identity(record, expectedID: id)
                        guard same(latest, original), latest["cwd"] as? String == cwd else { throw NativeEngineError("identity_changed", "原线程标题、项目、模型或供应商已变化，未变更") }
                        let status = (record["status"] as? [String: Any])?["type"] as? String ?? record["status"] as? String
                        guard status == "idle" || status == "notLoaded", let path = record["path"] as? String, !path.isEmpty else { throw NativeEngineError("source_unknown", "原线程状态或本地存储路径未知") }
                        rollout = EnginePolicy.path(path)
                        guard try rpc.gracefulShutdown() else { throw NativeEngineError("shutdown_failed", "检查进程未正常关闭") }
                    }
                    try requireClosed(backend); try progress("backup_start", false)
                    let snapshot = try services.backup(home, rollout, backup, id, true)
                    guard EnginePolicy.isTrue(snapshot["complete"]) else { throw NativeEngineError("backup_incomplete", "备份不完整，禁止变更") }
                    try progress("backup_complete", false)
                    let transaction = NativeTransaction.perform(open: openSafe, threadID: id, provider: provider, model: model, progress: progress)
                    var result = transaction.json; result["backup_directory"] = backup.path; result["selected_identity"] = original; result["receipt_path"] = receiptPath
                    receipt["stage"] = transaction.stage; receipt["result"] = result
                    if transaction.stoppedBeforeMutation {
                        throw NativeEngineError(transaction.errorCategory, transaction.detail)
                    }
                    let success = transaction.state == "backend_verified_gui_unverified" && transaction.threadID == id && transaction.reopenedVerified
                    receipt["status"] = success ? "backend_verified_gui_unverified" : "uncertain"; receipt["uncertain"] = !success
                    receipt["finished_at"] = EnginePolicy.now()
                    _ = try store.write(name: receiptName, value: receipt)
                    return result
                } catch {
                    if let safe = error as? NativeEngineError { mutationMayHaveStarted = mutationMayHaveStarted || safe.uncertain }
                    receipt["status"] = mutationMayHaveStarted ? "uncertain" : "stopped_before_mutation"; receipt["uncertain"] = mutationMayHaveStarted; receipt["finished_at"] = EnginePolicy.now()
                    var uncertain = mutationMayHaveStarted
                    do { _ = try store.write(name: receiptName, value: receipt) } catch { uncertain = true }
                    throw NativeEngineError(uncertain ? "switch_uncertain" : "switch_stopped", "操作已停止，保留记录，不自动重试或恢复", uncertain: uncertain, receiptPath: receiptPath)
                }
            }
        } catch NativeStorageError.operationBusy { throw NativeEngineError("operation_busy", "另一个操作仍在运行，不会并行或重试", uncertain: true) }
    }
}
