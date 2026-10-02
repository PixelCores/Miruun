import XCTest
@testable import BridgeCore

final class BridgeCoreTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }
    func testDefaultGateCannotSwitchWithoutConfirmation() {
        var gate = OperationGate()
        XCTAssertFalse(gate.beginSwitch(allConsents: true))
        XCTAssertTrue(gate.beginConfirmation())
        XCTAssertFalse(gate.beginSwitch(allConsents: false))
        XCTAssertTrue(gate.beginSwitch(allConsents: true))
        XCTAssertFalse(gate.beginSwitch(allConsents: true))
        XCTAssertFalse(gate.beginRead())
    }
    func testCancellationBeforeApplyDoesNotWrite() {
        var gate = OperationGate(); XCTAssertTrue(gate.beginConfirmation())
        gate.cancelConfirmation(); XCTAssertEqual(gate.phase, .idle)
        XCTAssertFalse(gate.beginSwitch(allConsents: true))
    }
    func testIncompleteResultRemainsReadonlyAcrossRecheck() {
        var gate = OperationGate(); _ = gate.beginConfirmation(); _ = gate.beginSwitch(allConsents: true)
        gate.finishSwitch(certain: false)
        XCTAssertEqual(gate.phase, .uncertain); XCTAssertFalse(gate.beginConfirmation())
        XCTAssertTrue(gate.beginRead()); gate.endRead(locked: true)
        XCTAssertEqual(gate.phase, .uncertain); XCTAssertFalse(gate.mayMutate)
    }
    func testRestoredPendingGateDoesNotPermitMutation() {
        var gate = OperationGate(uncertain: true)
        XCTAssertFalse(gate.beginConfirmation()); XCTAssertFalse(gate.beginSwitch(allConsents: true))
        XCTAssertTrue(gate.beginRead())
    }
    func testSuccessUnlocksOnlyWhenSwitching() {
        var gate = OperationGate(uncertain: true); gate.finishSwitch(certain: true)
        XCTAssertEqual(gate.phase, .uncertain)
        var active = OperationGate(); _ = active.beginConfirmation(); _ = active.beginSwitch(allConsents: true)
        active.finishSwitch(certain: true); XCTAssertTrue(active.mayMutate)
    }
    func testRepeatedReadAndConfirmationBlocked() {
        var gate = OperationGate(); XCTAssertTrue(gate.beginRead())
        XCTAssertFalse(gate.beginRead()); XCTAssertFalse(gate.beginConfirmation())
        gate.endRead(locked: false); XCTAssertTrue(gate.beginConfirmation())
        XCTAssertFalse(gate.beginConfirmation())
    }
    func testEnvelopeRoundTripAndRequestCorrelationFields() throws {
        var collector = EnvelopeCollector()
        let result = try collector.accept(data("{\"protocol_version\":1,\"request_id\":\"abc\",\"type\":\"result\",\"ok\":true,\"result\":{\"state\":\"not_started\"}}"))
        XCTAssertEqual(result.requestID, "abc"); XCTAssertEqual(result.result?["state"].string, "not_started")
        XCTAssertEqual(try collector.finish().ok, true)
    }
    func testRejectsUnknownVersionAndMissingResult() {
        var collector = EnvelopeCollector()
        XCTAssertThrowsError(try collector.accept(data("{\"protocol_version\":2,\"type\":\"result\",\"ok\":true,\"result\":{}}")))
        XCTAssertThrowsError(try collector.finish())
    }
    func testRejectsForeignOrMissingRequestID() {
        var collector = EnvelopeCollector(expectedRequestID: "current")
        XCTAssertThrowsError(try collector.accept(data("{\"protocol_version\":1,\"request_id\":\"old\",\"type\":\"result\",\"ok\":true,\"result\":{}}")))
        XCTAssertThrowsError(try collector.accept(data("{\"protocol_version\":1,\"type\":\"result\",\"ok\":true,\"result\":{}}")))
    }
    func testRejectsDuplicateAndLateProgress() throws {
        var collector = EnvelopeCollector()
        let result = data("{\"protocol_version\":1,\"type\":\"result\",\"ok\":false,\"error\":{\"uncertain\":true}}")
        _ = try collector.accept(result)
        XCTAssertThrowsError(try collector.accept(result))
        XCTAssertThrowsError(try collector.accept(data("{\"protocol_version\":1,\"type\":\"progress\"}")))
    }
    func testRejectsMalformedAndOversizedMessages() {
        var collector = EnvelopeCollector()
        XCTAssertThrowsError(try collector.accept(data("prose is not a result")))
        XCTAssertThrowsError(try collector.accept(data("{\"protocol_version\":1,\"type\":\"result\",\"ok\":true}")))
        XCTAssertThrowsError(try collector.accept(Data(repeating: 32, count: 1_048_577)))
    }
    func testSelectionRequiresFullIdentityAndExplicitHost() {
        let good = ConfirmedSelection(threadID: "original-id", title: nil, cwd: "/project", provider: "local", endpoint: "http://127.0.0.1:8317", model: "same-model")
        XCTAssertTrue(good.complete); XCTAssertTrue(good.summary.contains("original-id"))
        XCTAssertFalse(ConfirmedSelection(threadID: "original-id", title: "Title", cwd: "relative", provider: "local", endpoint: "", model: "same-model").complete)
    }
    func testJSONValuesRoundTripWithoutTypeCoercion() throws {
        let original = JSONValue.object(["a": .bool(true), "b": .number(3), "c": .null, "d": .array([.string("标题")])])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(original)), original)
    }
}
