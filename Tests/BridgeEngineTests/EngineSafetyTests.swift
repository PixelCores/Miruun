import XCTest
import Foundation
@testable import BridgeEngine

/// Synthetic fixtures only. No installed backend or user storage is involved.
final class EngineSafetyTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var store: NativeStateStore!
    private var starts = 0
    override func setUpWithError() throws {
        root = try NativeFileSafety.temporaryDirectory().appendingPathComponent("bridge-safety-" + UUID().uuidString)
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store = try NativeStateStore(root: root.appendingPathComponent("state"))
        starts = 0
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func engine() -> NativeEngine {
        return NativeEngine(services: EngineServices(
            probe: { _ in self.starts += 1; throw NativeEngineError("unexpected_start", "Synthetic forbidden start") }, openRPC: { _, _ in self.starts += 1; throw NativeEngineError("unexpected_start", "Synthetic forbidden start") },
            activeClients: { _ in self.starts += 1; throw NativeEngineError("unexpected_start", "Synthetic forbidden start") }, catalog: { _ in self.starts += 1; throw NativeEngineError("unexpected_start", "Synthetic forbidden start") },
            backup: { _, _, _, _, _ in self.starts += 1; throw NativeEngineError("unexpected_start", "Synthetic forbidden start") }))
    }
    private func request(_ command: String) -> [String: Any] {
        ["protocol_version": 1, "command": command, "backend": "/synthetic/codex", "home": home.path,
         "state_directory": store.root.path, "confirm_native": true, "thread_id": "original",
         "provider": "custom", "model": "preserved-model", "expected_cwd": "/synthetic/project",
         "backup_directory": root.appendingPathComponent("backup").path]
    }
    private func consented(_ token: String) -> [String: Any] {
        var value = request("switch"); value["preflight_id"] = token
        for key in EnginePolicy.consentKeys { value[key] = true }
        return value
    }
    private func manifest(_ token: String, consumed: Bool = false, expired: Bool = false) throws {
        _ = try store.write(name: "preflight-\(token).json", value: [
            "consumed": consumed, "expires_at_unix": Date().timeIntervalSince1970 + (expired ? -1 : 600),
            "backend": "/synthetic/codex", "home": home.path,
            "identity": ["thread_id": "original", "model": "preserved-model"],
            "destination": ["provider": "custom"], "expected_cwd": "/synthetic/project"])
    }
    func testEachConsentMustBeBooleanTrueBeforeAnyService() throws {
        let token = UUID().uuidString.lowercased()
        let invalidValues: [Any] = [false, 1, "true"]
        for key in EnginePolicy.consentKeys {
            for invalid in invalidValues {
                var value = consented(token); value[key] = invalid
                XCTAssertThrowsError(try engine().handle(value)) { error in
                    XCTAssertEqual((error as? NativeEngineError)?.code, "consent_required")
                }
            }
        }
        XCTAssertEqual(starts, 0)
    }
    func testMetadataCommandsShareOperationLock() throws {
        try store.withLock {
            for command in ["catalog", "preflight", "verify"] {
                XCTAssertThrowsError(try engine().handle(request(command))) { error in
                    XCTAssertEqual((error as? NativeEngineError)?.code, "operation_busy")
                    XCTAssertEqual((error as? NativeEngineError)?.uncertain, true)
                }
            }
        }
        XCTAssertEqual(starts, 0)
    }
    func testConsumedTokenCannotReplayAndStaysUncertain() throws {
        let token = UUID().uuidString.lowercased(); try manifest(token, consumed: true)
        XCTAssertThrowsError(try engine().handle(consented(token))) { error in
            XCTAssertEqual((error as? NativeEngineError)?.code, "preflight_used")
            XCTAssertEqual((error as? NativeEngineError)?.uncertain, true)
        }
        XCTAssertEqual(starts, 0)
    }
    func testExpiredTokenStartsNoService() throws {
        let token = UUID().uuidString.lowercased(); try manifest(token, expired: true)
        XCTAssertThrowsError(try engine().handle(consented(token))) { error in
            XCTAssertEqual((error as? NativeEngineError)?.code, "preflight_expired")
        }
        XCTAssertEqual(starts, 0)
    }
    func testAllBoundTargetFieldsRejectMismatchBeforeCatalogOrBackend() throws {
        let token = UUID().uuidString.lowercased(); try manifest(token)
        for key in ["backend", "home", "thread_id", "provider", "model", "expected_cwd"] {
            var value = consented(token); value[key] = key == "home" || key == "backend" || key == "expected_cwd" ? "/different" : "different"
            XCTAssertThrowsError(try engine().handle(value)) { error in
                XCTAssertEqual((error as? NativeEngineError)?.code, "preflight_mismatch")
            }
        }
        XCTAssertEqual(starts, 0)
    }
    func testIdentityNeverFallsBackToPreviewOrAnotherID() throws {
        let result = try NativeEngine.identity(["id": "original", "preview": "PRIVATE_BODY", "turns": [["text": "PRIVATE_BODY"]]], expectedID: "original")
        XCTAssertTrue(result["name"] is NSNull)
        XCTAssertNil(result["preview"]); XCTAssertNil(result["turns"])
        XCTAssertThrowsError(try NativeEngine.identity(["id": "other"], expectedID: "original"))
    }
}
