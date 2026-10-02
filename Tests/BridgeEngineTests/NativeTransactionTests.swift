import XCTest
@testable import BridgeEngine

final class TransactionRPC: EngineRPC {
    var replies: [[String: Any]]
    var calls: [(String, [String: Any])] = []
    var shutdown = true
    var closed = false
    var failure: NativeEngineError?
    var failingMethod: String?
    var onCall: ((String, [String: Any]) -> Void)?
    init(_ replies: [[String: Any]]) { self.replies = replies }
    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        XCTAssertNotEqual(method, "thread/settings/update")
        XCTAssertNotEqual(method, "turn/start")
        XCTAssertNotEqual(method, "thread/fork")
        calls.append((method, params))
        onCall?(method, params)
        if let failure, method == failingMethod { throw failure }
        guard !replies.isEmpty else { throw NativeEngineError("missing_fixture", "fixture missing") }
        return replies.removeFirst()
    }
    func gracefulShutdown() throws -> Bool { shutdown }
    func close() { closed = true }
}

final class NativeTransactionTests: XCTestCase {
    private var empty: [String: Any] { ["data": [Any](), "nextCursor": NSNull()] }
    private func effective(_ id: String = "original", provider: String = "custom", model: String = "same") -> [String: Any] {
        ["thread": ["id": id], "modelProvider": provider, "model": model]
    }
    func testSameIDColdReopenDoesNotNeedDeduplicatedSettingsNotification() {
        let first = TransactionRPC([empty, effective()]), second = TransactionRPC([empty, effective()])
        var phases: [EngineRPC] = [first, second]
        let result = NativeTransaction.perform(open: { phases.removeFirst() }, threadID: "original", provider: "custom", model: "same")
        XCTAssertEqual(result.state, "backend_verified_gui_unverified"); XCTAssertTrue(result.resumeVerified); XCTAssertTrue(result.reopenedVerified)
        XCTAssertEqual(first.calls.map { $0.0 }, ["thread/queue/list", "thread/resume"])
        XCTAssertEqual(second.calls.map { $0.0 }, ["thread/queue/list", "thread/resume"])
        XCTAssertNil(second.calls.last?.1["modelProvider"]); XCTAssertNil(second.calls.last?.1["model"])
        XCTAssertTrue(first.closed && second.closed)
    }
    func testFreshMismatchCannotBecomeSuccess() {
        for response in [effective("other"), effective(provider: "openai"), effective(model: "different")] {
            let first = TransactionRPC([empty, effective()]), second = TransactionRPC([empty, response])
            var phases: [EngineRPC] = [first, second]
            let result = NativeTransaction.perform(open: { phases.removeFirst() }, threadID: "original", provider: "custom", model: "same")
            XCTAssertNotEqual(result.state, "backend_verified_gui_unverified"); XCTAssertFalse(result.reopenedVerified); XCTAssertTrue(result.resumeVerified)
        }
    }
    func testBothGracefulShutdownsAreRequired() {
        for failing in [0, 1] {
            let first = TransactionRPC([empty, effective()]), second = TransactionRPC([empty, effective()])
            if failing == 0 { first.shutdown = false } else { second.shutdown = false }
            var phases: [EngineRPC] = [first, second]
            let result = NativeTransaction.perform(open: { phases.removeFirst() }, threadID: "original", provider: "custom", model: "same")
            XCTAssertFalse(result.reopenedVerified); XCTAssertNotEqual(result.state, "backend_verified_gui_unverified")
        }
    }
    func testUnknownOrNonemptyQueueNeverResumes() {
        let cases: [[String: Any]] = [[:], ["data": [Any]()], ["data": [["private": "SECRET"]], "nextCursor": NSNull()]]
        for response in cases {
            let rpc = TransactionRPC([response])
            let result = NativeTransaction.perform(open: { rpc }, threadID: "original", provider: "custom", model: "same")
            XCTAssertEqual(result.state, "not_started"); XCTAssertEqual(rpc.calls.map { $0.0 }, ["thread/queue/list"]); XCTAssertFalse(result.detail.contains("SECRET"))
            XCTAssertTrue(result.stoppedBeforeMutation)
        }
    }
    func testQueueTimeoutOrUnexpectedTurnDoesNotProveSafeStop() {
        for category in ["timeout", "unexpected_turn"] {
            let rpc = TransactionRPC([])
            rpc.failingMethod = "thread/queue/list"
            rpc.failure = NativeEngineError(category, "Synthetic uncertain failure", uncertain: true)
            let result = NativeTransaction.perform(open: { rpc }, threadID: "original", provider: "custom", model: "same")
            XCTAssertFalse(result.stoppedBeforeMutation)
            XCTAssertFalse(result.detail.contains("未请求恢复"))
            XCTAssertEqual(rpc.calls.map { $0.0 }, ["thread/queue/list"])
        }
    }
    func testMetadataOnlyResponseIsNotResumeProof() {
        let rpc = TransactionRPC([empty, ["thread": ["id": "original", "modelProvider": "custom", "model": "same"]]])
        let result = NativeTransaction.perform(open: { rpc }, threadID: "original", provider: "custom", model: "same")
        XCTAssertFalse(result.resumeVerified); XCTAssertEqual(result.state, "possibly_modified")
    }
    func testProgressReceiptFailureCannotReturnSuccess() {
        let first = TransactionRPC([empty, effective()]), second = TransactionRPC([empty, effective()])
        var phases: [EngineRPC] = [first, second]
        let result = NativeTransaction.perform(open: { phases.removeFirst() }, threadID: "original", provider: "custom", model: "same") { stage, _ in
            if stage == "complete" { throw NativeEngineError("disk_error", "SECRET must not leak") }
        }
        XCTAssertEqual(result.state, "backend_verified_receipt_unconfirmed"); XCTAssertFalse(result.detail.contains("SECRET"))
    }
    func testActualFeatureStatesMustIncludeAllSixExplicitFalse() throws {
        let all = EnginePolicy.disabledFeatures.map { ["name": $0, "enabled": false] as [String: Any] }
        try NativeTransaction.verifyDisabledFeatures(TransactionRPC([["data": all, "nextCursor": NSNull()]]))
        let missing = all.filter { $0["name"] as? String != "hooks" }
        XCTAssertThrowsError(try NativeTransaction.verifyDisabledFeatures(TransactionRPC([["data": missing, "nextCursor": NSNull()]])))
        XCTAssertThrowsError(try NativeTransaction.verifyDisabledFeatures(TransactionRPC([["data": all]])))
    }
    func testExactVersionAllowlistNotPrefixMatching() {
        XCTAssertTrue(EnginePolicy.auditedVersions.contains("codex-cli 0.159.2"))
        XCTAssertFalse(EnginePolicy.auditedVersions.contains("codex-cli 0.159.20"))
        XCTAssertFalse(NativeRPC.allowed.contains("thread/settings/update"))
        XCTAssertFalse(NativeRPC.allowed.contains("turn/start"))
    }
}
