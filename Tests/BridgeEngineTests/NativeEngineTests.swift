import XCTest
import Foundation
@testable import BridgeEngine

/// Exercises the complete engine boundary with synthetic RPC and storage only.
final class NativeEngineTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var store: NativeStateStore!
    private var sessions: [TransactionRPC] = []
    private var events: [String] = []
    private var catalogCalls = 0
    private var changedCatalogAt: Int?
    private var backupComplete = true
    private var backendVersion = "codex-cli 0.159.2"

    override func setUpWithError() throws {
        root = try NativeFileSafety.temporaryDirectory()
            .appendingPathComponent("miruun-engine-test-" + UUID().uuidString)
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store = try NativeStateStore(root: root.appendingPathComponent("state"))
        sessions = []; events = []; catalogCalls = 0; changedCatalogAt = nil; backupComplete = true
        backendVersion = "codex-cli 0.159.2"
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private var emptyQueue: [String: Any] { ["data": [Any](), "nextCursor": NSNull()] }
    private var features: [String: Any] {
        ["data": EnginePolicy.disabledFeatures.sorted().map { ["name": $0, "enabled": false] as [String: Any] },
         "nextCursor": NSNull()]
    }
    private var thread: [String: Any] {
        ["id": "original", "name": "Synthetic title", "cwd": "/synthetic/project", "model": "same",
         "modelProvider": "previous", "status": ["type": "notLoaded"],
         "path": home.appendingPathComponent("selected.jsonl").path]
    }
    private var effective: [String: Any] {
        ["thread": ["id": "original"], "modelProvider": "custom", "model": "same"]
    }

    private func rpc(_ name: String, _ replies: [[String: Any]]) -> TransactionRPC {
        let rpc = TransactionRPC(replies)
        rpc.onCall = { [weak self] method, _ in self?.events.append(name + ":" + method) }
        sessions.append(rpc)
        return rpc
    }

    private func engine() -> NativeEngine {
        NativeEngine(services: EngineServices(
            probe: { _ in BackendCapabilities(version: self.backendVersion, sourceAuditedCandidate: true, indexedCatalog: true) },
            openRPC: { _, _ in
                guard !self.sessions.isEmpty else { throw NativeEngineError("missing_fixture", "No synthetic RPC available") }
                return self.sessions.removeFirst()
            },
            activeClients: { _ in [] },
            catalog: { _ in
                self.catalogCalls += 1
                return ProviderCatalogResult(
                    providers: [NativeProvider(id: "custom", name: "Synthetic provider", endpointOrigin: "https://example.test", selectable: true, blocker: nil)],
                    configRevision: self.catalogCalls == self.changedCatalogAt ? "changed" : "original",
                    configSource: "synthetic/config.toml", overridesUnknown: true)
            },
            backup: { selectedHome, rollout, _, id, consent in
                XCTAssertEqual(selectedHome.path, self.home.path)
                XCTAssertEqual(rollout.path, self.home.appendingPathComponent("selected.jsonl").path)
                XCTAssertEqual(id, "original"); XCTAssertTrue(consent)
                self.events.append("backup")
                return ["complete": self.backupComplete]
            }))
    }

    private func request(_ command: String) -> [String: Any] {
        ["protocol_version": 1, "command": command, "backend": "/synthetic/codex", "home": home.path,
         "state_directory": store.root.path, "confirm_native": true, "closed_clients": true,
         "thread_id": "original", "provider": "custom", "model": "same", "expected_cwd": "/synthetic/project",
         "expected_name": "Synthetic title", "backup_directory": root.appendingPathComponent("backup").path]
    }

    private func preflight(_ engine: NativeEngine) throws -> String {
        let inspection = rpc("preflight", [features, emptyQueue, ["thread": thread]])
        let result = try engine.handle(request("preflight"))
        XCTAssertTrue(inspection.closed)
        XCTAssertEqual(result["can_switch"] as? Bool, true)
        return try XCTUnwrap(result["preflight_id"] as? String)
    }

    private func switchRequest(_ token: String) -> [String: Any] {
        var value = request("switch")
        value["preflight_id"] = token
        for key in EnginePolicy.consentKeys { value[key] = true }
        return value
    }

    private func receipt(_ path: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
    }

    func testBackupPrecedesSameIDMutationAndFreshResumeHasNoOverrides() throws {
        let engine = engine(), token = try preflight(engine)
        let inspection = rpc("inspection", [features, emptyQueue, ["thread": thread]])
        let mutation = rpc("mutation", [features, emptyQueue, effective])
        let verification = rpc("verification", [features, emptyQueue, effective])
        let result = try engine.handle(switchRequest(token))

        XCTAssertEqual(result["state"] as? String, "backend_verified_gui_unverified")
        XCTAssertEqual(result["thread_id"] as? String, "original")
        XCTAssertEqual(result["fresh_backend_effective_settings_verified"] as? Bool, true)
        let backupIndex = try XCTUnwrap(events.firstIndex(of: "backup"))
        let resumeIndex = try XCTUnwrap(events.firstIndex(of: "mutation:thread/resume"))
        XCTAssertLessThan(backupIndex, resumeIndex)
        XCTAssertEqual(mutation.calls.last?.1["modelProvider"] as? String, "custom")
        XCTAssertEqual(mutation.calls.last?.1["model"] as? String, "same")
        XCTAssertNil(verification.calls.last?.1["modelProvider"])
        XCTAssertNil(verification.calls.last?.1["model"])
        XCTAssertTrue(inspection.closed && mutation.closed && verification.closed)
        XCTAssertEqual(try store.readPreflight(id: token)["consumed"] as? Bool, true)
        let saved = try receipt(XCTUnwrap(result["receipt_path"] as? String))
        XCTAssertEqual(saved["status"] as? String, "backend_verified_gui_unverified")
        XCTAssertEqual(saved["uncertain"] as? Bool, false)
    }

    func testQueueAddedAfterInspectionProducesDefiniteStopWithReceipt() throws {
        let engine = engine(), token = try preflight(engine)
        _ = rpc("inspection", [features, emptyQueue, ["thread": thread]])
        let mutation = rpc("mutation", [features, ["data": [["private": "SYNTHETIC_SECRET"]], "nextCursor": NSNull()]])
        XCTAssertThrowsError(try engine.handle(switchRequest(token))) { error in
            let safe = error as? NativeEngineError
            XCTAssertEqual(safe?.code, "switch_stopped")
            XCTAssertEqual(safe?.uncertain, false)
            XCTAssertFalse(safe?.message.contains("SYNTHETIC_SECRET") ?? true)
            do {
                let saved = try self.receipt(XCTUnwrap(safe?.receiptPath))
                XCTAssertEqual(saved["status"] as? String, "stopped_before_mutation")
                XCTAssertEqual(saved["uncertain"] as? Bool, false)
                XCTAssertEqual((saved["result"] as? [String: Any])?["stopped_before_mutation"] as? Bool, true)
            } catch { XCTFail("Missing stop receipt: \(error)") }
        }
        XCTAssertTrue(events.contains("backup"))
        XCTAssertFalse(mutation.calls.contains { $0.0 == "thread/resume" })
        XCTAssertEqual(try store.readPreflight(id: token)["consumed"] as? Bool, true)
    }

    func testQueueTimeoutAndUnexpectedTurnRetainUncertainReceipt() throws {
        for category in ["timeout", "unexpected_turn"] {
            let engine = engine(), token = try preflight(engine)
            _ = rpc("inspection", [features, emptyQueue, ["thread": thread]])
            let mutation = rpc("mutation", [features])
            mutation.failingMethod = "thread/queue/list"
            mutation.failure = NativeEngineError(category, "SYNTHETIC_SECRET", uncertain: true)
            let result = try engine.handle(switchRequest(token))
            XCTAssertNotEqual(result["state"] as? String, "backend_verified_gui_unverified")
            XCTAssertEqual(result["stopped_before_mutation"] as? Bool, false)
            XCTAssertFalse((result["detail"] as? String)?.contains("SYNTHETIC_SECRET") ?? true)
            let saved = try receipt(XCTUnwrap(result["receipt_path"] as? String))
            XCTAssertEqual(saved["status"] as? String, "uncertain")
            XCTAssertEqual(saved["uncertain"] as? Bool, true)
            XCTAssertFalse(mutation.calls.contains { $0.0 == "thread/resume" })
        }
    }

    func testChangedConfigurationRejectsBeforeBackupOrMutation() throws {
        let engine = engine(), token = try preflight(engine)
        changedCatalogAt = catalogCalls + 1
        XCTAssertThrowsError(try engine.handle(switchRequest(token))) { error in
            XCTAssertEqual((error as? NativeEngineError)?.code, "destination_changed")
            XCTAssertEqual((error as? NativeEngineError)?.uncertain, false)
        }
        XCTAssertFalse(events.contains("backup"))
        XCTAssertEqual(try store.readPreflight(id: token)["consumed"] as? Bool, false)
    }

    func testDifferentAllowedBackendVersionRequiresNewPreflight() throws {
        let engine = engine(), token = try preflight(engine)
        backendVersion = "codex-cli 0.159.0-alpha.7"
        XCTAssertThrowsError(try engine.handle(switchRequest(token))) { error in
            XCTAssertEqual((error as? NativeEngineError)?.code, "switch_stopped")
            XCTAssertEqual((error as? NativeEngineError)?.uncertain, false)
        }
        XCTAssertFalse(events.contains("backup"))
        XCTAssertFalse(events.contains { $0.contains("thread/resume") })
    }

    func testChangedIdentityRejectsBeforeBackupOrMutation() throws {
        let engine = engine(), token = try preflight(engine)
        var changed = thread; changed["name"] = "Changed synthetic title"
        let inspection = rpc("inspection", [features, emptyQueue, ["thread": changed]])
        XCTAssertThrowsError(try engine.handle(switchRequest(token))) { error in
            XCTAssertEqual((error as? NativeEngineError)?.code, "switch_stopped")
            XCTAssertEqual((error as? NativeEngineError)?.uncertain, false)
        }
        XCTAssertFalse(events.contains("backup"))
        XCTAssertFalse(inspection.calls.contains { $0.0 == "thread/resume" })
    }

    func testIncompleteBackupNeverOpensMutationBackend() throws {
        let engine = engine(), token = try preflight(engine)
        _ = rpc("inspection", [features, emptyQueue, ["thread": thread]])
        let mutation = rpc("mutation", [features, emptyQueue, effective])
        backupComplete = false
        XCTAssertThrowsError(try engine.handle(switchRequest(token))) { error in
            XCTAssertEqual((error as? NativeEngineError)?.code, "switch_stopped")
            XCTAssertEqual((error as? NativeEngineError)?.uncertain, false)
        }
        XCTAssertTrue(mutation.calls.isEmpty)
    }

    func testMissingOriginalModelBlocksPreflightWithoutResume() throws {
        let engine = engine()
        var metadata = thread; metadata.removeValue(forKey: "model")
        let inspection = rpc("preflight", [features, emptyQueue, ["thread": metadata]])
        XCTAssertThrowsError(try engine.handle(request("preflight"))) { error in
            XCTAssertEqual((error as? NativeEngineError)?.code, "model_unknown")
        }
        XCTAssertFalse(inspection.calls.contains { $0.0 == "thread/resume" })
        XCTAssertFalse(events.contains("backup"))
    }
}
