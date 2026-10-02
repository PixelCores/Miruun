import Foundation
import CoreFoundation

public struct NativeTransactionResult {
    public var state = "not_started"
    public let threadID: String
    public var resumeVerified = false
    public var reopenedVerified = false
    public var stage = "not_started"
    public var errorCategory = ""
    public var rpcCode: Int?
    public var detail = ""
    public var stoppedBeforeMutation = false
    public var json: [String: Any] {
        ["state": state, "thread_id": threadID, "resume_response_verified": resumeVerified,
         "fresh_backend_effective_settings_verified": reopenedVerified, "gui_verified": false,
         "diagnostic_stage": stage, "error_category": errorCategory, "rpc_error_code": EnginePolicy.null(rpcCode), "detail": detail,
         "stopped_before_mutation": stoppedBeforeMutation]
    }
}

public enum NativeTransaction {
    public static func requireEmptyQueue(_ rpc: EngineRPC, threadID: String) throws {
        let result = try rpc.call("thread/queue/list", ["threadId": threadID, "limit": 1])
        guard let data = result["data"] as? [Any], data.isEmpty, result["nextCursor"] is NSNull else {
            throw NativeEngineError("queue_not_empty_or_unknown", "队列非空或未知，未请求恢复；请在原客户端处理")
        }
    }
    public static func verifyDisabledFeatures(_ rpc: EngineRPC) throws {
        var observed: [String: Bool] = [:], seen: Set<String> = []; var cursor: String?; var pages = 0
        while true {
            pages += 1
            guard pages <= 100 else { throw NativeEngineError("features_unknown", "功能分页超出限制") }
            var params: [String: Any] = ["limit": 100]; if let cursor { params["cursor"] = cursor }
            let response = try rpc.call("experimentalFeature/list", params)
            guard let data = response["data"] as? [[String: Any]] else { throw NativeEngineError("features_unknown", "无法读取实际功能状态") }
            for value in data {
                guard let name = value["name"] as? String, EnginePolicy.disabledFeatures.contains(name) else { continue }
                guard observed[name] == nil, let number = value["enabled"] as? NSNumber,
                      CFGetTypeID(number) == CFBooleanGetTypeID() else { throw NativeEngineError("features_unknown", "功能状态重复或未知") }
                observed[name] = number.boolValue
            }
            if response["nextCursor"] is NSNull { break }
            guard let next = response["nextCursor"] as? String, !next.isEmpty, !seen.contains(next) else { throw NativeEngineError("features_unknown", "功能状态分页无效") }
            seen.insert(next); cursor = next
        }
        guard EnginePolicy.disabledFeatures.allSatisfy({ observed[$0] == false }) else {
            throw NativeEngineError("features_not_disabled", "无法确认六项自动执行相关功能全部关闭，禁止恢复")
        }
    }
    public static func perform(open: () throws -> EngineRPC, threadID: String, provider: String, model: String,
                               progress: ((String, Bool) throws -> Void)? = nil) -> NativeTransactionResult {
        var outcome = NativeTransactionResult(threadID: threadID)
        func stage(_ value: String) throws { outcome.stage = value; try progress?(value, outcome.state != "not_started") }
        func phase(_ body: (EngineRPC) throws -> Void) throws {
            let rpc = try open(); defer { rpc.close() }; try body(rpc)
        }
        do {
            try stage("mutation_backend_start")
            try phase { rpc in
                try stage("mutation_queue_check"); try requireEmptyQueue(rpc, threadID: threadID)
                outcome.state = "possibly_modified"; try stage("resume_request")
                let resumed = try rpc.call("thread/resume", ["threadId": threadID, "modelProvider": provider, "model": model, "excludeTurns": true])
                try stage("resume_response_validation")
                guard (resumed["thread"] as? [String: Any])?["id"] as? String == threadID,
                      resumed["modelProvider"] as? String == provider, resumed["model"] as? String == model else {
                    throw NativeEngineError("resume_mismatch", "恢复响应未确认同一ID、供应商和原模型", uncertain: true)
                }
                // Exact source-audited versions checkpoint in cold resume. The
                // identical settings update notification is deduplicated: never await it.
                outcome.resumeVerified = true; outcome.state = "resume_verified_persistence_unverified"
                try stage("mutation_backend_shutdown")
                guard try rpc.gracefulShutdown() else { throw NativeEngineError("shutdown_failed", "后端未正常关闭", uncertain: true) }
            }
            try stage("verification_backend_start")
            try phase { rpc in
                try stage("verification_queue_check"); try requireEmptyQueue(rpc, threadID: threadID)
                try stage("verification_resume_request")
                let reopened = try rpc.call("thread/resume", ["threadId": threadID, "excludeTurns": true])
                try stage("verification_response_validation")
                guard (reopened["thread"] as? [String: Any])?["id"] as? String == threadID,
                      reopened["modelProvider"] as? String == provider, reopened["model"] as? String == model else {
                    throw NativeEngineError("reopen_mismatch", "新进程未确认持久化设置", uncertain: true)
                }
                try stage("verification_backend_shutdown")
                guard try rpc.gracefulShutdown() else { throw NativeEngineError("shutdown_failed", "验证进程未正常关闭", uncertain: true) }
                outcome.reopenedVerified = true; outcome.state = "backend_verified_gui_unverified"; try stage("complete")
            }
        } catch {
            if outcome.state == "backend_verified_gui_unverified" { outcome.state = "backend_verified_receipt_unconfirmed" }
            if let safe = error as? NativeEngineError {
                outcome.errorCategory = safe.code; outcome.rpcCode = safe.rpcCode
                if safe.code == "unexpected_turn" { outcome.state = "unexpected_turn_detected" }
                outcome.stoppedBeforeMutation = outcome.state == "not_started" && !safe.uncertain
            } else { outcome.errorCategory = "local_or_protocol_error" }
            outcome.detail = outcome.stoppedBeforeMutation ? "前置检查失败，未请求恢复" : "结果不确定；保留备份与记录，不自动重试或回滚"
        }
        return outcome
    }
}
