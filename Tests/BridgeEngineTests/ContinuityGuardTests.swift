import XCTest
import Foundation
import Darwin
@testable import BridgeEngine

/// Disposable fixtures only; never inspect a real CODEX_HOME or launch Codex.
final class ContinuityGuardTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var backups: URL!
    private var config: URL { home.appendingPathComponent("config.toml") }
    private var auth: URL { home.appendingPathComponent("auth.json") }
    private let key = "SYNTHETIC_API_KEY"

    override func setUpWithError() throws {
        root = try NativeFileSafety.temporaryDirectory().appendingPathComponent("ContinuityGuardTests-" + UUID().uuidString, isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        backups = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writeAuth(["OPENAI_API_KEY": key, "auth_mode": "apikey", "tokens": NSNull()])
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func writeAuth(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: auth)
    }

    private func writeConfig(_ text: String) throws {
        try Data(text.utf8).write(to: config)
    }

    private func provider(endpoint: String = "http://127.0.0.1:8317/v1", extra: String = "") -> String {
        "model_provider = \"proxy\"\nmodel = \"original-model\"\n[model_providers.proxy]\nname = \"Local\"\nbase_url = \"\(endpoint)\"\nrequires_openai_auth = true\n" + extra
    }

    private func assertBlocked(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try writeConfig(text)
        let before = try Data(contentsOf: config)
        let backupsBefore = FileManager.default.fileExists(atPath: backups.path)
            ? try FileManager.default.contentsOfDirectory(atPath: backups.path) : []
        let guarder = ContinuityGuard(home: home, backupDirectory: backups)
        for _ in 0..<2 {
            let status = guarder.check()
            XCTAssertEqual(status.phase, .blocked, file: file, line: line)
            XCTAssertFalse(status.message.contains(key), file: file, line: line)
            XCTAssertNil(status.backupPath, file: file, line: line)
        }
        XCTAssertEqual(try Data(contentsOf: config), before, file: file, line: line)
        let backupsAfter = FileManager.default.fileExists(atPath: backups.path)
            ? try FileManager.default.contentsOfDirectory(atPath: backups.path) : []
        XCTAssertEqual(backupsAfter, backupsBefore, file: file, line: line)
    }

    func testStablePairUpdatesOnlyRootRoutingKeysAndMakesPrivateOriginalBackup() throws {
        let text = """
        # Keep the original history's model
          "model_provider" = 'proxy'  # preserve this comment
        model = "original-model"
        openai_base_url = "https://old.example/v1" # replace only this value
        [model_providers.proxy]
        name = "Local"
        base_url = "http://127.0.0.1:8317/v1"
        wire_api = "responses"
        requires_openai_auth = true
        # Keep provider definitions
        """ + "\n"
        try writeConfig(text)
        let authBefore = try Data(contentsOf: auth)
        let guarder = ContinuityGuard(home: home, backupDirectory: backups)
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), text)
        let result = guarder.check()
        XCTAssertEqual(result.phase, .updated)
        let expected = text.replacingOccurrences(of: "= 'proxy'", with: "= \"openai\"")
            .replacingOccurrences(of: "https://old.example/v1", with: "http://127.0.0.1:8317/v1")
            .replacingOccurrences(of: "# replace only this value", with: "# replace only this value # miruun-managed-openai-base-url")
        let rewritten = try String(contentsOf: config, encoding: .utf8)
        XCTAssertEqual(try CatalogTOML.parse(rewritten).entries["model"].stringValue, "original-model")
        XCTAssertEqual(rewritten, expected)
        let backup = try XCTUnwrap(result.backupPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: backup)), Data(text.utf8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: backup)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: backups.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: auth), authBefore)
        XCTAssertEqual(guarder.check().phase, .ready)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).count, 1)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: home.path)), ["config.toml", "auth.json"])
    }

    func testMissingRootEndpointIsInsertedBeforeFirstTableAndCRLFCommentsSurvive() throws {
        let text = provider().replacingOccurrences(of: "\n", with: "\r\n")
        try writeConfig(text)
        let guarder = ContinuityGuard(home: home, backupDirectory: backups)
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(guarder.check().phase, .updated)
        let updated = try String(contentsOf: config, encoding: .utf8)
        let parsed = try CatalogTOML.parse(updated)
        XCTAssertEqual(parsed.entries["openai_base_url"].stringValue, "http://127.0.0.1:8317/v1")
        XCTAssertTrue(updated.contains("\r\n[model_providers.proxy]\r\n"))
        XCTAssertTrue(updated.hasSuffix("requires_openai_auth = true\r\n"))
    }

    func testConfigAndAuthChangesRestartStabilityWindow() throws {
        try writeConfig(provider())
        let guarder = ContinuityGuard(home: home, backupDirectory: backups)
        XCTAssertEqual(guarder.check().phase, .waiting)
        try writeConfig(provider(endpoint: "http://localhost:8318/v1"))
        XCTAssertEqual(guarder.check().phase, .waiting)
        try writeAuth(["OPENAI_API_KEY": "SYNTHETIC_CHANGED_KEY"])
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(guarder.check().phase, .updated)
        XCTAssertEqual(try CatalogTOML.parse(String(contentsOf: config, encoding: .utf8)).entries["openai_base_url"].stringValue, "http://localhost:8318/v1")
    }

    func testOAuthWaitsWithoutChangingConfigurationOrCredentials() throws {
        try writeConfig("model_provider = \"openai\"\nmodel = \"original-model\"\n")
        try writeAuth(["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "tokens": ["access_token": "SYNTHETIC_OAUTH"]])
        let original = try Data(contentsOf: config), authBefore = try Data(contentsOf: auth)
        let guarder = ContinuityGuard(home: home, backupDirectory: backups)
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(try Data(contentsOf: config), original)
        XCTAssertEqual(try Data(contentsOf: auth), authBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }

    func testOAuthReturnRemovesOnlyOwnedEndpointAfterTwoStableSamples() throws {
        try writeConfig(provider())
        let guarder = ContinuityGuard(home: home, backupDirectory: backups)
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(guarder.check().phase, .updated)
        let routedConfig = try Data(contentsOf: config)
        try writeAuth(["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "tokens": ["access_token": "SYNTHETIC_OAUTH"]])
        let authBefore = try Data(contentsOf: auth)
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(try Data(contentsOf: config), routedConfig)
        let restored = guarder.check()
        XCTAssertEqual(restored.phase, .updated)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(restored.backupPath))), routedConfig)
        let parsed = try CatalogTOML.parse(String(contentsOf: config, encoding: .utf8))
        XCTAssertNil(parsed.entries["openai_base_url"])
        XCTAssertEqual(parsed.entries["model_provider"].stringValue, "openai")
        XCTAssertEqual(parsed.entries["model"].stringValue, "original-model")
        XCTAssertEqual(try Data(contentsOf: auth), authBefore)
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).count, 2)
    }

    func testOAuthDoesNotRemoveUnownedOrModifiedEndpoints() throws {
        try writeAuth(["auth_mode": "chatgpt", "tokens": ["access_token": "SYNTHETIC_OAUTH"]])
        for text in [
            "model_provider = \"openai\"\nopenai_base_url = \"http://localhost:8317/v1\"\n",
            "model_provider = \"openai\"\nopenai_base_url = \"https://remote.example/v1\" # miruun-managed-openai-base-url\n",
            "model_provider = \"openai\"\nopenai_base_url = \"http://localhost:8317/v1\" # miruun-managed-openai-base-url other-comment\n",
            provider()
        ] {
            try assertBlocked(text)
        }
    }

    func testUnsupportedOrMixedAuthNeverWrites() throws {
        try writeConfig(provider())
        let invalid: [[String: Any]] = [
            ["OPENAI_API_KEY": key, "auth_mode": "api_key"],
            ["OPENAI_API_KEY": key, "auth_mode": "apikey", "tokens": ["access_token": "SYNTHETIC_OAUTH"]],
            ["OPENAI_API_KEY": key, "pat": "SYNTHETIC_PAT"],
            ["OPENAI_API_KEY": ""], ["OPENAI_API_KEY": "key\nheader"], ["OPENAI_API_KEY": 42]
        ]
        for value in invalid {
            try writeAuth(value)
            let guarder = ContinuityGuard(home: home, backupDirectory: backups)
            XCTAssertEqual(guarder.check().phase, .blocked)
            XCTAssertEqual(guarder.check().phase, .blocked)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }

    func testExternalAuthModesAndMalformedTokensCannotTriggerOAuthCleanup() throws {
        let managed = "model_provider = \"openai\"\nopenai_base_url = \"http://localhost:8317/v1\" # miruun-managed-openai-base-url\nmodel = \"original-model\"\n"
        let validTokens = ["access_token": "SYNTHETIC_ACCESS_TOKEN", "id_token": "SYNTHETIC_ID_TOKEN", "refresh_token": "SYNTHETIC_REFRESH_TOKEN"]
        for mode in ["chatgptAuthTokens", "chatgpt_auth_tokens", "external", "unknown"] {
            try writeAuth(["auth_mode": mode, "tokens": validTokens, "OPENAI_API_KEY": NSNull()])
            let before = try Data(contentsOf: auth)
            try assertBlocked(managed)
            XCTAssertEqual(try Data(contentsOf: auth), before)
        }
        for tokenValue: Any in ["SYNTHETIC_TOKEN", ["SYNTHETIC_TOKEN"], true, 42] {
            for mode in [nil, "apikey", "chatgpt"] as [String?] {
                var value: [String: Any] = ["tokens": tokenValue, "OPENAI_API_KEY": mode == "chatgpt" ? NSNull() : key]
                if let mode { value["auth_mode"] = mode }
                try writeAuth(value)
                let before = try Data(contentsOf: auth)
                try assertBlocked(managed)
                XCTAssertEqual(try Data(contentsOf: auth), before)
            }
        }
    }

    func testNullAuthModeUsesTheAPIKeyLikeAnOmittedMode() throws {
        try writeConfig(provider())
        try writeAuth(["auth_mode": NSNull(), "OPENAI_API_KEY": key, "tokens": NSNull()])
        let originalAuth = try Data(contentsOf: auth)
        let guarder = ContinuityGuard(home: home, backupDirectory: backups)
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(guarder.check().phase, .updated)
        XCTAssertEqual(try Data(contentsOf: auth), originalAuth)
    }

    func testLoopbackAllowlistAndWireProtocol() throws {
        for endpoint in ["http://localhost:8317/v1", "https://127.0.0.1/v1", "http://[::1]:8317/v1"] {
            try writeConfig(provider(endpoint: endpoint))
            let guarder = ContinuityGuard(home: home, backupDirectory: backups)
            XCTAssertEqual(guarder.check().phase, .waiting)
            XCTAssertEqual(guarder.check().phase, .updated)
        }
        for endpoint in ["https://remote.example/v1", "http://127.0.0.2/v1", "http://localhost.evil/v1", "http://user@localhost/v1", "http://localhost/v1?token=SYNTHETIC", "http://localhost/v1#fragment", "http://localhost:0/v1", "http://localhost:65536/v1", "http://localhost:/v1", "http://localhost/%broken", "file:///localhost/v1"] {
            try writeConfig(provider(endpoint: endpoint))
            let guarder = ContinuityGuard(home: home, backupDirectory: backups)
            XCTAssertEqual(guarder.check().phase, .blocked, endpoint)
        }
        try assertBlocked(provider(extra: "wire_api = \"chat\"\n"))
    }

    func testProviderSettingsThatWouldBeLostAndMissingOpenAIAuthAreBlocked() throws {
        for extra in ["env_key = \"SYNTHETIC_ENV\"", "http_headers = { X = \"value\" }", "env_http_headers = { X = \"ENV\" }", "query_params = { key = \"value\" }", "experimental_bearer_token = \"SYNTHETIC_TOKEN\"", "auth = { command = \"helper\" }", "gateway_oauth = { url = \"https://gateway.example\" }", "aws = { region = \"test\" }", "supports_websockets = false", "request_max_retries = 1", "model_catalog_url = \"http://localhost/models\""] {
            try assertBlocked(provider(extra: extra + "\n"))
        }
        try assertBlocked(provider().replacingOccurrences(of: "requires_openai_auth = true\n", with: ""))
        try assertBlocked(provider().replacingOccurrences(of: "requires_openai_auth = true", with: "requires_openai_auth = false"))
    }

    func testProfilesKeyringAndForcedLoginOverridesAreBlocked() throws {
        for rootKey in ["profile = \"work\"", "profiles = { work = { model = \"another\" } }", "forced_login_method = \"chatgpt\"", "forced_chatgpt_workspace_id = \"workspace\"", "cli_auth_credentials_store = \"keyring\"", "cli_auth_credentials_store = \"auto\"", "cli_auth_credentials_store = \"ephemeral\""] {
            try assertBlocked(rootKey + "\n" + provider())
        }
        try writeConfig("cli_auth_credentials_store = \"file\"\n" + provider())
        let guarder = ContinuityGuard(home: home, backupDirectory: backups)
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(guarder.check().phase, .updated)
    }

    func testAlreadyOpenAILoopbackIsReadyWithoutBackupOrMutation() throws {
        for rootProvider in ["", "model_provider = \"openai\"\n"] {
            let text = rootProvider + "openai_base_url = \"http://localhost:8317/v1\"\nmodel = \"original-model\"\n"
            try writeConfig(text)
            let guarder = ContinuityGuard(home: home, backupDirectory: backups)
            XCTAssertEqual(guarder.check().phase, .ready)
            XCTAssertEqual(guarder.check().phase, .ready)
            XCTAssertEqual(try Data(contentsOf: config), Data(text.utf8))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }

    func testInvalidTOMLAndUnsafeFilesAreBlockedWithoutReadingOtherStorage() throws {
        try assertBlocked("model_provider = \"proxy\"\nmodel_provider = \"openai\"\n")
        try assertBlocked("model_provider = \"proxy\"\n[model_providers.proxy]\nbase_url = \"\"\"unsupported\"\"\"\n")
        try writeConfig(provider())
        let original = root.appendingPathComponent("original.toml")
        try FileManager.default.moveItem(at: config, to: original)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: original)
        XCTAssertEqual(ContinuityGuard(home: home, backupDirectory: backups).check().phase, .blocked)
        try FileManager.default.removeItem(at: config)
        XCTAssertEqual(link(original.path, config.path), 0)
        XCTAssertEqual(ContinuityGuard(home: home, backupDirectory: backups).check().phase, .blocked)
        try FileManager.default.removeItem(at: config)
        try writeConfig(provider())
        try FileManager.default.removeItem(at: auth)
        XCTAssertEqual(mkfifo(auth.path, 0o600), 0)
        XCTAssertEqual(ContinuityGuard(home: home, backupDirectory: backups).check().phase, .blocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }

    func testOversizedFilesAndUnsafeBackupLocationAreBlocked() throws {
        try writeConfig(provider())
        try Data(repeating: 32, count: 65_537).write(to: auth)
        XCTAssertEqual(ContinuityGuard(home: home, backupDirectory: backups).check().phase, .blocked)
        try writeAuth(["OPENAI_API_KEY": key])
        try Data(repeating: 32, count: 1_024 * 1_024 + 1).write(to: config)
        XCTAssertEqual(ContinuityGuard(home: home, backupDirectory: backups).check().phase, .blocked)
        try writeConfig(provider())
        let unsafe = ContinuityGuard(home: home, backupDirectory: home.appendingPathComponent("backups"))
        XCTAssertEqual(unsafe.check().phase, .waiting)
        XCTAssertEqual(unsafe.check().phase, .blocked)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), provider())
    }
}

private extension Optional where Wrapped == CatalogValue {
    var stringValue: String? {
        guard case let .string(value)? = self else { return nil }
        return value
    }
}
