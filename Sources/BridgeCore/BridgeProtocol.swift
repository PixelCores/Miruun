import Foundation

/// Only sanitized metadata crosses this boundary. Never accept raw RPC output.
public enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
}

public struct BridgeEnvelope: Decodable {
    public let protocolVersion: Int
    public let type: String
    public let ok: Bool?
    public let result: JSONValue?
    public let error: JSONValue?
    public let stage: String?
    public let message: String?
    public let requestID: String?
    public let receiptPath: String?
    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case receiptPath = "receipt_path"
        case type, ok, result, error, stage, message
    }
}

public enum ProtocolFailure: Error, Equatable {
    case invalidEnvelope, incompatibleVersion, outputTooLarge, missingResult, duplicateResult
}

/// Enforces one result; a damaged stream is never reported as a completed write.
public struct EnvelopeCollector {
    public private(set) var result: BridgeEnvelope?
    private let expectedRequestID: String?
    public init(expectedRequestID: String? = nil) { self.expectedRequestID = expectedRequestID }
    public mutating func accept(_ data: Data) throws -> BridgeEnvelope {
        guard data.count <= 1_048_576 else { throw ProtocolFailure.outputTooLarge }
        let envelope: BridgeEnvelope
        do { envelope = try JSONDecoder().decode(BridgeEnvelope.self, from: data) }
        catch { throw ProtocolFailure.invalidEnvelope }
        guard envelope.protocolVersion == 1 else { throw ProtocolFailure.incompatibleVersion }
        if let expectedRequestID, envelope.requestID != expectedRequestID { throw ProtocolFailure.invalidEnvelope }
        guard envelope.type == "progress" || envelope.type == "result" else { throw ProtocolFailure.invalidEnvelope }
        if envelope.type == "result" {
            guard result == nil else { throw ProtocolFailure.duplicateResult }
            guard let ok = envelope.ok, ok ? envelope.result != nil : envelope.error != nil else {
                throw ProtocolFailure.invalidEnvelope
            }
            result = envelope
        } else if result != nil { throw ProtocolFailure.invalidEnvelope }
        return envelope
    }
    public func finish() throws -> BridgeEnvelope {
        guard let result else { throw ProtocolFailure.missingResult }
        return result
    }
}

public struct OperationGate {
    public enum Phase: Equatable { case idle, reading, confirming, switching, uncertain }
    public private(set) var phase: Phase
    public init(uncertain: Bool = false) { phase = uncertain ? .uncertain : .idle }
    public var busy: Bool { [.reading, .confirming, .switching].contains(phase) }
    public var mayMutate: Bool { phase == .idle }
    public mutating func beginRead() -> Bool {
        guard !busy else { return false }; phase = .reading; return true
    }
    public mutating func endRead(locked: Bool) { if phase == .reading { phase = locked ? .uncertain : .idle } }
    public mutating func beginConfirmation() -> Bool {
        guard phase == .idle else { return false }; phase = .confirming; return true
    }
    public mutating func cancelConfirmation() { if phase == .confirming { phase = .idle } }
    public mutating func beginSwitch(allConsents: Bool) -> Bool {
        guard phase == .confirming && allConsents else { return false }; phase = .switching; return true
    }
    public mutating func finishSwitch(certain: Bool) {
        guard phase == .switching else { return }; phase = certain ? .idle : .uncertain
    }
}

public struct ConfirmedSelection: Equatable {
    public let threadID: String
    public let title: String?
    public let cwd: String
    public let provider: String
    public let endpoint: String
    public let model: String
    public init(threadID: String, title: String?, cwd: String, provider: String, endpoint: String, model: String) {
        self.threadID = threadID; self.title = title; self.cwd = cwd
        self.provider = provider; self.endpoint = endpoint; self.model = model
    }
    public var complete: Bool {
        [threadID, cwd, provider, endpoint, model].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        && cwd.hasPrefix("/")
    }
    public var summary: String {
        "标题：\(title ?? "（后端未提供标题）")\n原 ID：\(threadID)\n项目：\(cwd)\n目标 provider：\(provider)\n目标 endpoint：\(endpoint)\n保留模型：\(model)"
    }
}
