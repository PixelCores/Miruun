import Foundation
import Darwin
import BridgeCore

/// One bundled native Swift helper per request. No Python, shell or web server.
final class BridgeRunner {
    struct Failure: Error { let message: String; let processWasStarted: Bool }
    let entry: URL
    init(entry: URL) { self.entry = entry }

    private static func readChunk(_ handle: FileHandle) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if count >= 0 { return Data(buffer.prefix(count)) }
            if errno != EINTR { throw CocoaError(.fileReadUnknown) }
        }
    }

    func run(request: [String: JSONValue],
             progress: @escaping (BridgeEnvelope) -> Void,
             completion: @escaping (Result<BridgeEnvelope, Failure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let input = Pipe(), output = Pipe()
            process.executableURL = self.entry
            process.arguments = []
            process.standardInput = input
            process.standardOutput = output
            // Engine errors are sanitized in the JSON protocol. Never show
            // raw stderr, which can include environment values or credentials.
            process.standardError = FileHandle.nullDevice
            // A helper that exits before receiving JSON must produce a caught
            // write error rather than a SIGPIPE terminating the menu app.
            process.currentDirectoryURL = self.entry.deletingLastPathComponent()
            process.environment = ProcessInfo.processInfo.environment
            var started = false
            var collector = EnvelopeCollector(expectedRequestID: request["request_id"]?.string)
            var parseFailure: Error?
            do {
                guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let payload = try JSONEncoder().encode(JSONValue.object(request))
                guard payload.count <= 65_536 else { throw ProtocolFailure.outputTooLarge }
                try process.run(); started = true
                do {
                    try input.fileHandleForWriting.write(contentsOf: payload + Data([10]))
                    try input.fileHandleForWriting.close()
                } catch {
                    try? input.fileHandleForWriting.close()
                    throw error
                }
                var pending = Data()
                var total = 0
                while true {
                    // One POSIX read returns available bytes. read(upToCount:)
                    // may wait to fill its entire count and delay JSONL progress.
                    let chunk = try Self.readChunk(output.fileHandleForReading)
                    if chunk.isEmpty { break }
                    total += chunk.count
                    if total > 4_194_304 { parseFailure = ProtocolFailure.outputTooLarge }
                    // Keep draining even on a protocol error: never interrupt an
                    // in-flight mutation or deadlock its pipe to force a retry.
                    guard parseFailure == nil else { continue }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                        if line.isEmpty { continue }
                        do {
                            let event = try collector.accept(line)
                            guard event.requestID == request["request_id"]?.string else { throw ProtocolFailure.invalidEnvelope }
                            if event.type == "progress" { DispatchQueue.main.async { progress(event) } }
                        } catch { parseFailure = error; pending.removeAll(); break }
                    }
                    if pending.count > 1_048_576 { parseFailure = ProtocolFailure.outputTooLarge; pending.removeAll() }
                }
                process.waitUntilExit()
                if !pending.isEmpty && parseFailure == nil {
                    do {
                        let event = try collector.accept(pending)
                        guard event.requestID == request["request_id"]?.string else { throw ProtocolFailure.invalidEnvelope }
                    } catch { parseFailure = error }
                }
                if let parseFailure { throw parseFailure }
                let envelope = try collector.finish()
                // An explicit sanitized failure may accompany a nonzero exit.
                if process.terminationStatus != 0 && envelope.ok == true { throw ProtocolFailure.invalidEnvelope }
                DispatchQueue.main.async { completion(.success(envelope)) }
            } catch {
                // No kill, automatic rerun, rollback or raw exception display.
                try? input.fileHandleForWriting.close()
                if started && process.isRunning {
                    // Close stdin before waiting, and drain stdout even when
                    // writing the request failed, so neither pipe deadlocks.
                    while let chunk = try? Self.readChunk(output.fileHandleForReading), !chunk.isEmpty {}
                    process.waitUntilExit()
                }
                let failure = Failure(message: started
                    ? "本地桥接进程没有返回完整、可信的结果。若正在切换，可能已修改；保留备份，仅做只读复核。"
                    : "无法启动内置 Swift 引擎。请用完整源码重新构建应用，并保留应用包内两个可执行文件。",
                    processWasStarted: started)
                DispatchQueue.main.async { completion(.failure(failure)) }
            }
        }
    }
}
