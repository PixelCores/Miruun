import XCTest
import Foundation
@testable import BridgeEngine

/// Exercises real pipes and child processes against disposable shell fixtures.
/// No installed Codex executable or user storage is involved.
final class NativeProcessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try NativeFileSafety.temporaryDirectory().appendingPathComponent("miruun-process-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func executable(_ script: String) throws -> URL {
        let file = root.appendingPathComponent(UUID().uuidString + ".sh")
        try Data(("#!/bin/sh\nset -eu\numask 077\n" + script).utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    private func rpc(response: String, tail: String = "", timeout: TimeInterval = 1) throws -> NativeRPC {
        let script = """
        IFS= read -r request
        printf '%s\\n' "$request" >> "$CODEX_HOME/requests.jsonl"
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        if IFS= read -r request; then
            printf '%s\\n' "$request" >> "$CODEX_HOME/requests.jsonl"
            printf '%s\\n' '\(response)'
            \(tail)
        fi
        cat >/dev/null
        """
        return try NativeRPC(backend: executable(script), home: root, timeout: timeout)
    }

    func testHandshakeAndMetadataReadUseRealPipes() throws {
        let client = try rpc(response: #"{"id":2,"result":{"thread":{"id":"original"}}}"#)
        defer { client.close() }
        let response = try client.call("thread/read", ["threadId": "original", "includeTurns": false])
        XCTAssertEqual((response["thread"] as? [String: Any])?["id"] as? String, "original")
        XCTAssertTrue(try client.gracefulShutdown())
        let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        XCTAssertTrue(requests.contains("miruun_native"))
        XCTAssertFalse(requests.contains("turn/start"))
    }

    func testTruncatedOrInvalidTrailingOutputPreventsCleanShutdown() throws {
        for tail in ["printf '%s' 'truncated'", "printf '%s\\n' 'invalid-json'"] {
            let client = try rpc(response: #"{"id":2,"result":{}}"#, tail: tail)
            defer { client.close() }
            _ = try client.call("thread/read", ["threadId": "original"])
            XCTAssertFalse(try client.gracefulShutdown())
        }
    }

    func testUnexpectedTurnCannotBeReportedAsMetadataSuccess() throws {
        let client = try rpc(response: #"{"method":"turn/started","params":{}}"#)
        defer { client.close() }
        XCTAssertThrowsError(try client.call("thread/read", ["threadId": "original"])) {
            XCTAssertEqual(($0 as? NativeEngineError)?.code, "unexpected_turn")
            XCTAssertEqual(($0 as? NativeEngineError)?.uncertain, true)
        }
    }

    func testForeignResponseTimesOutWithoutAcceptingIt() throws {
        let client = try rpc(response: #"{"id":999,"result":{}}"#, timeout: 2)
        defer { client.close() }
        XCTAssertThrowsError(try client.call("thread/read", ["threadId": "original"])) {
            XCTAssertEqual(($0 as? NativeEngineError)?.code, "timeout")
            XCTAssertEqual(($0 as? NativeEngineError)?.uncertain, true)
        }
    }

    func testTurnStartIsRejectedBeforeWritingToChild() throws {
        let client = try rpc(response: #"{"id":2,"result":{}}"#)
        defer { client.close() }
        XCTAssertThrowsError(try client.call("turn/start", ["threadId": "original"])) {
            XCTAssertEqual(($0 as? NativeEngineError)?.code, "method_not_allowed")
        }
        XCTAssertTrue(try client.gracefulShutdown())
        let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        XCTAssertFalse(requests.contains("turn/start"))
    }

    func testSchemaProbeWorksInPhysicalMacTemporaryDirectory() throws {
        let backend = try executable("""
        if [ "$1" = '--version' ]; then printf '%s\\n' 'codex-cli 0.159.2'; exit 0; fi
        for argument in "$@"; do destination="$argument"; done
        mkdir -p "$destination"
        printf '%s' '{"properties":{"threadId":{},"modelProvider":{},"model":{},"excludeTurns":{}}}' > "$destination/ThreadResumeParams.json"
        printf '%s' '{"properties":{"threadId":{},"limit":{}}}' > "$destination/ThreadQueueListParams.json"
        printf '%s' '{"properties":{"limit":{}}}' > "$destination/ExperimentalFeatureListParams.json"
        printf '%s' '{"properties":{"threadId":{},"includeTurns":{}}}' > "$destination/ThreadReadParams.json"
        printf '%s' '{"properties":{"modelProviders":{},"useStateDbOnly":{}}}' > "$destination/ThreadListParams.json"
        """)
        let capabilities = try NativeDiscovery.probe(backend: backend)
        XCTAssertTrue(capabilities.sourceAuditedCandidate)
        XCTAssertTrue(capabilities.indexedCatalog)
    }
}
