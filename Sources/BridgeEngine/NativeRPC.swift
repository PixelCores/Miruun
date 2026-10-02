import Foundation
import Darwin

/// Only official app-server methods needed by the bridge are callable.
/// No turn/start, settings/update, fork, auth operation, shell, or queue write.
public final class NativeRPC: EngineRPC {
    public static let allowed: Set<String> = ["initialize", "experimentalFeature/list", "thread/list", "thread/read", "thread/goal/get", "thread/queue/list", "thread/resume"]
    private enum Item { case message([String: Any]); case failure(NativeEngineError) }
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let condition = NSCondition()
    private var items: [Item] = []
    private var readerDone = false
    private var unexpectedTurn = false
    private var inputClosed = false
    private var serial = 0
    private let timeout: TimeInterval

    public init(backend: URL, home: URL, timeout: TimeInterval = 20) throws {
        self.timeout = timeout
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: home.path, isDirectory: &directory), directory.boolValue else {
            throw NativeEngineError("invalid_home", "请选择已存在的 CODEX_HOME 目录")
        }
        process.executableURL = backend
        process.arguments = ["app-server", "--listen", "stdio://"] + EnginePolicy.disabledFeatures.sorted().flatMap { ["--disable", $0] }
        var environment = ProcessInfo.processInfo.environment; environment["CODEX_HOME"] = home.path
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        // Configure bounded nonblocking writes before launching the backend.
        let descriptor = input.fileHandleForWriting.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw NativeEngineError("transport_setup_failed", "无法建立受保护的本地协议管道")
        }
        do { try process.run() } catch { throw NativeEngineError("backend_start_failed", "无法启动选中的后端，未显示原始系统错误") }
        DispatchQueue.global(qos: .userInitiated).async { [self] in readLoop() }
        do {
            _ = try call("initialize", ["clientInfo": ["name": "miruun_native", "version": "0.3.1"], "capabilities": ["experimentalApi": true]])
            try send(["method": "initialized"])
        } catch { close(); throw error }
    }

    private func enqueue(_ item: Item) {
        condition.lock(); items.append(item); condition.broadcast(); condition.unlock()
    }
    private func readLoop() {
        defer { condition.lock(); readerDone = true; condition.broadcast(); condition.unlock() }
        var totalBytes = 0
        var pending = Data(); var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; enqueue(.failure(NativeEngineError("transport_error", "后端读取失败"))); return }
            if count == 0 { break }
            totalBytes += count
            if totalBytes > 128 * 1024 * 1024 { enqueue(.failure(NativeEngineError("output_too_large", "后端累计响应过大"))); return }
            pending.append(contentsOf: buffer.prefix(count))
            if pending.count > 64 * 1024 * 1024 { enqueue(.failure(NativeEngineError("output_too_large", "后端响应过大"))); return }
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                if line.isEmpty { continue }
                guard let object = try? JSONSerialization.jsonObject(with: line), let message = object as? [String: Any] else {
                    enqueue(.failure(NativeEngineError("invalid_backend_json", "后端协议响应无效"))); return
                }
                condition.lock()
                if message["method"] as? String == "turn/started" { unexpectedTurn = true }
                if items.count >= 1000 {
                    items.removeAll(); items.append(.failure(NativeEngineError("notification_overflow", "后端通知过多")))
                    condition.broadcast(); condition.unlock(); return
                }
                items.append(.message(message)); condition.broadcast(); condition.unlock()
            }
        }
        if !pending.isEmpty { enqueue(.failure(NativeEngineError("incomplete_backend_json", "后端返回不完整的协议消息"))) }
    }
    private func send(_ value: [String: Any], until: TimeInterval? = nil) throws {
        let deadline = until ?? (ProcessInfo.processInfo.systemUptime + timeout)
        guard let payload = try? JSONSerialization.data(withJSONObject: value), payload.count <= 1_048_576 else {
            throw NativeEngineError("invalid_outgoing_request", "本地协议请求无效或过大")
        }
        let data = payload + Data([10]); let descriptor = input.fileHandleForWriting.fileDescriptor
        var offset = 0
        while offset < data.count {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NativeEngineError("timeout", "本地协议写入超时", uncertain: true) }
            let written = data.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written > 0 { offset += written; continue }
            if written < 0 && errno == EINTR { continue }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                var descriptorState = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let milliseconds = Int32(max(1, min(100, (deadline - ProcessInfo.processInfo.systemUptime) * 1000)))
                let ready = Darwin.poll(&descriptorState, 1, milliseconds)
                if ready < 0 && errno != EINTR { throw NativeEngineError("transport_write_failed", "本地协议管道失败") }
                if descriptorState.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw NativeEngineError("transport_write_failed", "本地协议管道已关闭") }
                continue
            }
            throw NativeEngineError("transport_write_failed", "发送本地协议请求失败")
        }
    }
    private func next(until deadline: TimeInterval) throws -> [String: Any] {
        if ProcessInfo.processInfo.systemUptime >= deadline { throw NativeEngineError("timeout", "后端请求超时；结果可能不确定", uncertain: true) }
        condition.lock(); defer { condition.unlock() }
        while items.isEmpty && !readerDone && !unexpectedTurn {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { break }
            _ = condition.wait(until: Date().addingTimeInterval(min(remaining, 0.5)))
        }
        if unexpectedTurn { throw NativeEngineError("unexpected_turn", "检测到意外回合启动；可能已有调用或副作用", uncertain: true) }
        if !items.isEmpty {
            switch items.removeFirst() { case .message(let value): return value; case .failure(let error): throw error }
        }
        if readerDone { throw NativeEngineError("backend_closed", "后端在完整结果前关闭") }
        throw NativeEngineError("timeout", "后端请求超时；若已请求恢复，可能已持久化，不能自动重试", uncertain: true)
    }
    public func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        guard Self.allowed.contains(method) else { throw NativeEngineError("method_not_allowed", "不允许的后端方法") }
        serial += 1; let request = serial
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try send(["id": request, "method": method, "params": params], until: deadline)
        while true {
            let message = try next(until: deadline)
            if message["method"] != nil {
                if let id = message["id"], !(id is NSNull) {
                    try send(["id": id, "error": ["code": -32601, "message": "Bridge does not approve server requests"]], until: deadline)
                }
                continue
            }
            guard let id = message["id"] as? Int, id == request else { continue }
            if let error = message["error"] as? [String: Any] {
                throw NativeEngineError("rpc_rejected", "后端拒绝请求，原始错误已隐藏", rpcCode: error["code"] as? Int)
            }
            guard let result = message["result"] as? [String: Any] else { throw NativeEngineError("invalid_backend_result", "后端结果结构未知") }
            return result
        }
    }
    private func checkUnexpectedTurn() throws {
        condition.lock(); let value = unexpectedTurn; condition.unlock()
        if value { throw NativeEngineError("unexpected_turn", "检测到意外回合启动；不能声称零调用", uncertain: true) }
    }
    public func gracefulShutdown() throws -> Bool {
        if !inputClosed { try? input.fileHandleForWriting.close(); inputClosed = true }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { try checkUnexpectedTurn(); usleep(10000) }
        guard !process.isRunning else { return false }
        process.waitUntilExit()
        condition.lock()
        let readerDeadline = ProcessInfo.processInfo.systemUptime + 2
        while !readerDone && ProcessInfo.processInfo.systemUptime < readerDeadline { _ = condition.wait(until: Date().addingTimeInterval(0.1)) }
        let done = readerDone
        let failures = items.contains { if case .failure = $0 { return true }; return false }
        condition.unlock()
        try checkUnexpectedTurn()
        return done && !failures && process.terminationStatus == 0
    }
    public func close() {
        if !inputClosed { try? input.fileHandleForWriting.close(); inputClosed = true }
        if process.isRunning {
            process.terminate(); let deadline = ProcessInfo.processInfo.systemUptime + 3
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10000) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }
}
