import Foundation
import Darwin
import BridgeEngine

// A closed UI pipe must become a caught error, not kill the helper mid-write.
signal(SIGPIPE, SIG_IGN)
var requestID: String?
var isSwitch = false

func output(_ body: [String: Any]) throws {
    var value = body; value["protocol_version"] = 1; value["request_id"] = EnginePolicy.null(requestID)
    let data = try JSONSerialization.data(withJSONObject: value) + Data([10])
    try FileHandle.standardOutput.write(contentsOf: data)
}
func readRequest() throws -> [String: Any] {
    var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
        if n < 0 { if errno == EINTR { continue }; throw NativeEngineError("invalid_request", "无法读取本地请求") }
        if n == 0 { break }
        guard result.count + n <= 65536 else { throw NativeEngineError("invalid_request", "本地请求过大") }
        result.append(contentsOf: buffer.prefix(n))
    }
    guard let value = try? JSONSerialization.jsonObject(with: result), let request = value as? [String: Any] else {
        throw NativeEngineError("invalid_request", "本地请求JSON无效")
    }
    if let id = request["request_id"] {
        guard let text = id as? String, text.count <= 128, text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0.value == 45 || $0.value == 95 }) else {
            throw NativeEngineError("invalid_request", "请求标识无效")
        }
        requestID = text
    }
    isSwitch = request["command"] as? String == "switch"
    return request
}

do {
    let request = try readRequest()
    let result = try NativeEngine().handle(request) { try output($0) }
    try output(["type": "result", "ok": true, "result": result])
} catch let error as NativeEngineError {
    var payload: [String: Any] = ["code": error.code, "message": error.message, "uncertain": error.uncertain, "stopped_before_mutation": !error.uncertain]
    if let receipt = error.receiptPath { payload["receipt_path"] = receipt }
    try? output(["type": "result", "ok": false, "error": payload])
    exit(1)
} catch {
    // No raw Foundation/provider/SQLite/config error is sent to the UI.
    try? output(["type": "result", "ok": false, "error": ["code": "request_failed", "message": "本地请求失败，原始错误已隐藏；保留已有记录", "uncertain": isSwitch, "stopped_before_mutation": false]])
    exit(1)
}
