import Foundation
import CoreFoundation

public struct NativeEngineError: Error {
    public let code: String
    public let message: String
    public let uncertain: Bool
    public let rpcCode: Int?
    public let receiptPath: String?
    public init(_ code: String, _ message: String, uncertain: Bool = false, rpcCode: Int? = nil, receiptPath: String? = nil) {
        self.code = code; self.message = message; self.uncertain = uncertain; self.rpcCode = rpcCode; self.receiptPath = receiptPath
    }
}

public enum EnginePolicy {
    public static let protocolVersion = 1
    public static let auditedVersions: Set<String> = ["codex-cli 0.159.0-alpha.7", "codex-cli 0.159.2"]
    public static let disabledFeatures: Set<String> = ["goals", "agent_message_board", "memories", "apps", "plugins", "hooks"]
    public static let consentKeys = ["confirmed", "closed_clients", "backup_consent", "experimental_consent", "endpoint_ack", "startup_transmission_ack"]
    public static func path(_ value: String) -> URL {
        URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }
    public static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
    public static func text(_ object: [String: Any], _ key: String, limit: Int = 4096) throws -> String {
        guard let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= limit, !value.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw NativeEngineError("invalid_request", "缺少或无效的字段：\(key)")
        }
        return value
    }
    public static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue
    }
    public static func null(_ value: Any?) -> Any { value ?? NSNull() }
}

public protocol EngineRPC: AnyObject {
    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any]
    func gracefulShutdown() throws -> Bool
    func close()
}
