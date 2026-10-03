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

    private func inlineProvider(token: String = "SYNTHETIC_INLINE_KEY") -> String {
        provider(extra: "wire_api = \"responses\"\nexperimental_bearer_token = \"\(token)\"\n")
            .replacingOccurrences(of: "requires_openai_auth = true", with: "requires_openai_auth = false")
    }

    private func managedCustom(endpoint: String? = nil) -> String {
        let definition = "[model_providers.custom] # miruun-managed-custom-provider\nname = \"OpenAI\"\nwire_api = \"responses\"\nrequires_openai_auth = true\n"
        return definition + (endpoint.map { "base_url = \"\($0)\"\n" } ?? "")
    }

    private func customDefinition(_ text: String) throws -> CatalogTable {
        let root = try CatalogTOML.parse(text)
        return try XCTUnwrap(root.entries["model_providers"].tableValue?.entries["custom"].tableValue)
    }

    private func receipt(_ status: ContinuityStatus) throws -> [String: Bool] {
        let directory = URL(fileURLWithPath: try XCTUnwrap(status.backupPath)).deletingLastPathComponent()
        let data = try Data(contentsOf: directory.appendingPathComponent("receipt.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Bool])
    }

    private func pendingFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("pending-") }
    }

    private func assertBlocked(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try writeConfig(text)
        let before = try Data(contentsOf: config)
        let backupsBefore = FileManager.default.fileExists(atPath: backups.path)
            ? try FileManager.default.contentsOfDirectory(atPath: backups.path) : []
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
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
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
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
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
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
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
        XCTAssertEqual(guarder.check().phase, .waiting)
        try writeConfig(provider(endpoint: "http://localhost:8318/v1"))
        XCTAssertEqual(guarder.check().phase, .waiting)
        try writeAuth(["OPENAI_API_KEY": "SYNTHETIC_CHANGED_KEY"])
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(guarder.check().phase, .updated)
        XCTAssertEqual(try CatalogTOML.parse(String(contentsOf: config, encoding: .utf8)).entries["openai_base_url"].stringValue, "http://localhost:8318/v1")
    }

    func testMissingAuthWaitsWithoutWritingAndRequiresStablePairAfterCreation() throws {
        let text = provider()
        try writeConfig(text)
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
        XCTAssertEqual(guarder.check().phase, .waiting)
        try FileManager.default.removeItem(at: auth)
        for _ in 0..<2 {
            let status = guarder.check()
            XCTAssertEqual(status.phase, .waiting)
            XCTAssertEqual(status.message, "未找到可用的文件认证或代理 Key；请在 CC Switch 选择已配置的本机代理接入。")
            XCTAssertNil(status.backupPath)
            XCTAssertEqual(try Data(contentsOf: config), Data(text.utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: auth.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        }
        try writeAuth(["OPENAI_API_KEY": key, "auth_mode": "apikey", "tokens": NSNull()])
        let authBefore = try Data(contentsOf: auth)
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(try Data(contentsOf: config), Data(text.utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        XCTAssertEqual(guarder.check().phase, .updated)
        XCTAssertEqual(try Data(contentsOf: auth), authBefore)
        XCTAssertEqual(guarder.check().phase, .ready)
    }

    func testOAuthRepairsMissingCustomAfterStableSamplesWithoutChangingCredentials() throws {
        let text = "model_provider = \"openai\"\nmodel = \"original-model\"\n"
        try writeConfig(text)
        try writeAuth(["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "tokens": ["access_token": "SYNTHETIC_OAUTH"]])
        let original = try Data(contentsOf: config), authBefore = try Data(contentsOf: auth)
        let authInode = try FileManager.default.attributesOfItem(atPath: auth.path)[.systemFileNumber] as? NSNumber
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(try Data(contentsOf: config), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        let updated = guarder.check()
        XCTAssertEqual(updated.phase, .updated)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), text + managedCustom())
        let definition = try customDefinition(String(contentsOf: config, encoding: .utf8))
        XCTAssertEqual(Set(definition.entries.keys), ["name", "wire_api", "requires_openai_auth"])
        XCTAssertEqual(definition.entries["name"].stringValue, "OpenAI")
        XCTAssertEqual(definition.entries["wire_api"].stringValue, "responses")
        XCTAssertEqual(definition.entries["requires_openai_auth"].boolValue, true)
        XCTAssertNil(definition.entries["base_url"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(updated.backupPath))), original)
        XCTAssertEqual(try Data(contentsOf: auth), authBefore)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: auth.path)[.systemFileNumber] as? NSNumber, authInode)
        XCTAssertEqual(try receipt(updated), ["auth_existed": true, "config_written": true, "auth_written": false, "complete": true])
        XCTAssertEqual(guarder.check().phase, .ready)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).count, 1)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: home.path)), ["config.toml", "auth.json"])
        XCTAssertTrue(try pendingFiles().isEmpty)
    }

    func testOAuthAliasInsertionPreservesOtherTablesAndLineEndings() throws {
        try writeAuth(["auth_mode": "chatgpt", "tokens": ["access_token": "SYNTHETIC_OAUTH"]])
        let authBefore = try Data(contentsOf: auth)
        for newline in ["\n", "\r\n"] {
            for trailingNewline in [false, true] {
                let text = "model = \"original-model\"\n[model_providers.other]\nname = \"Preserved\"\nbase_url = \"https://example.test/v1\""
                    .replacingOccurrences(of: "\n", with: newline) + (trailingNewline ? newline : "")
                try writeConfig(text)
                let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
                XCTAssertEqual(guarder.check().phase, .waiting)
                XCTAssertEqual(guarder.check().phase, .updated)
                let output = try String(contentsOf: config, encoding: .utf8)
                XCTAssertEqual(output, text + (trailingNewline ? "" : newline) + managedCustom().replacingOccurrences(of: "\n", with: newline))
                let parsed = try CatalogTOML.parse(output)
                XCTAssertNil(parsed.entries["model_provider"])
                XCTAssertEqual(parsed.entries["model"].stringValue, "original-model")
                XCTAssertNil(try customDefinition(output).entries["base_url"])
                XCTAssertEqual(try Data(contentsOf: auth), authBefore)
                XCTAssertEqual(guarder.check().phase, .ready)
            }
        }
    }

    func testOAuthReturnRemovesOnlyOwnedEndpointAfterTwoStableSamples() throws {
        try writeConfig(provider())
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
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
        XCTAssertNil(try customDefinition(String(contentsOf: config, encoding: .utf8)).entries["base_url"])
        XCTAssertEqual(try Data(contentsOf: auth), authBefore)
        XCTAssertEqual(guarder.check().phase, .ready)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).count, 2)
    }

    func testManagedCustomAliasTracksNativeProxyAndOAuthRoundTrip() throws {
        let endpoint = "http://localhost:8317/v1"
        let text = "model_provider = \"openai\"\nmodel = \"original-model\"\nopenai_base_url = \"\(endpoint)\" # miruun-managed-openai-base-url\n" + managedCustom()
        try writeConfig(text)
        let apiAuth = try Data(contentsOf: auth)
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), text)
        XCTAssertEqual(guarder.check().phase, .updated)
        let routed = try String(contentsOf: config, encoding: .utf8)
        XCTAssertEqual(try customDefinition(routed).entries["base_url"].stringValue, endpoint)
        XCTAssertEqual(try Data(contentsOf: auth), apiAuth)
        XCTAssertEqual(guarder.check().phase, .ready)

        let nextEndpoint = "http://127.0.0.1:8318/nested/v1"
        try writeConfig(routed.replacingOccurrences(of: "openai_base_url = \"\(endpoint)\"", with: "openai_base_url = \"\(nextEndpoint)\""))
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(guarder.check().phase, .updated)
        let rerouted = try Data(contentsOf: config)
        XCTAssertEqual(try customDefinition(String(decoding: rerouted, as: UTF8.self)).entries["base_url"].stringValue, nextEndpoint)

        try writeAuth(["auth_mode": "chatgpt", "tokens": ["access_token": "SYNTHETIC_OAUTH"]])
        let oauthAuth = try Data(contentsOf: auth)
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(try Data(contentsOf: config), rerouted)
        let restored = guarder.check()
        XCTAssertEqual(restored.phase, .updated)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(restored.backupPath))), rerouted)
        let restoredText = try String(contentsOf: config, encoding: .utf8)
        let root = try CatalogTOML.parse(restoredText)
        XCTAssertNil(root.entries["openai_base_url"])
        XCTAssertEqual(root.entries["model_provider"].stringValue, "openai")
        XCTAssertEqual(root.entries["model"].stringValue, "original-model")
        XCTAssertNil(try customDefinition(restoredText).entries["base_url"])
        XCTAssertEqual(try Data(contentsOf: auth), oauthAuth)
        XCTAssertEqual(guarder.check().phase, .ready)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).count, 3)
    }

    func testSelectedProxySynchronizesExistingManagedCustomAlias() throws {
        for inline in [false, true] {
            try writeAuth(["auth_mode": "apikey", "OPENAI_API_KEY": key])
            let original = (inline ? inlineProvider() : provider()) + managedCustom()
            try writeConfig(original)
            let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
            XCTAssertEqual(guarder.check().phase, .waiting)
            let updated = guarder.check()
            XCTAssertEqual(updated.phase, .updated)
            let output = try String(contentsOf: config, encoding: .utf8)
            let parsed = try CatalogTOML.parse(output)
            XCTAssertEqual(parsed.entries["model_provider"].stringValue, "openai")
            XCTAssertEqual(parsed.entries["model"].stringValue, "original-model")
            XCTAssertEqual(parsed.entries["openai_base_url"].stringValue, "http://127.0.0.1:8317/v1")
            XCTAssertEqual(try customDefinition(output).entries["base_url"].stringValue, "http://127.0.0.1:8317/v1")
            let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: auth)) as? [String: String])
            XCTAssertEqual(credentials["OPENAI_API_KEY"], inline ? "SYNTHETIC_INLINE_KEY" : key)
            XCTAssertEqual(try receipt(updated)["auth_written"], inline)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(updated.backupPath))), Data(original.utf8))
            XCTAssertEqual(guarder.check().phase, .ready)
        }
    }

    func testExistingUnmanagedCustomDefinitionsArePreserved() throws {
        let definitions = [
            "[model_providers.custom]\nname = \"Existing provider\"\nbase_url = \"https://example.test/v1\"\nenv_key = \"SYNTHETIC_ENV\"\n",
            "model_providers = { custom = { name = 'Existing provider', base_url = 'https://example.test/v1', env_key = 'SYNTHETIC_ENV' } }\n"
        ]
        for api in [false, true] {
            try writeAuth(api ? ["auth_mode": "apikey", "OPENAI_API_KEY": key] : ["auth_mode": "chatgpt", "tokens": ["access_token": "SYNTHETIC_OAUTH"]])
            let authBefore = try Data(contentsOf: auth)
            for definition in definitions {
                let text = "model_provider = \"openai\"\n" + (api ? "openai_base_url = \"http://localhost:8317/v1\"\n" : "") + definition
                try writeConfig(text)
                let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
                XCTAssertEqual(guarder.check().phase, .ready)
                XCTAssertEqual(guarder.check().phase, .ready)
                XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), text)
                XCTAssertEqual(try Data(contentsOf: auth), authBefore)
                XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
            }
        }
    }

    func testEditedManagedCustomDefinitionsBlockWithoutChangingEitherFile() throws {
        try writeAuth(["auth_mode": "chatgpt", "tokens": ["access_token": "SYNTHETIC_OAUTH"]])
        let authBefore = try Data(contentsOf: auth)
        let definition = managedCustom()
        let edited = [
            definition.replacingOccurrences(of: "# miruun-managed-custom-provider", with: "# miruun-managed-custom-provider changed"),
            definition.replacingOccurrences(of: "name = \"OpenAI\"", with: "name = \"Edited\""),
            definition.replacingOccurrences(of: "requires_openai_auth = true", with: "requires_openai_auth = false"),
            definition.replacingOccurrences(of: "requires_openai_auth = true", with: "requires_openai_auth = true # edited"),
            definition + "env_key = \"SYNTHETIC_ENV\"\n",
            definition + "experimental_bearer_token = \"SYNTHETIC_TOKEN\"\n",
            definition + "[model_providers.custom.http_headers]\nAuthorization = \"SYNTHETIC_TOKEN\"\n",
            managedCustom(endpoint: "https://example.test/v1"),
            definition + "base_url = 42\n",
            "# miruun-managed-custom-provider\n" + definition,
            "# miruun-managed-custom-provider\n"
        ]
        for text in edited {
            try assertBlocked("model_provider = \"openai\"\n" + text)
            XCTAssertEqual(try Data(contentsOf: auth), authBefore)
        }
    }

    func testCommentedManagedHeaderCannotOwnAnUnmarkedCustomProvider() throws {
        let spoof = "model_provider = \"openai\"\nopenai_base_url = \"http://localhost:8317/v1\"\n[other]\n# " + managedCustom()
            + managedCustom().replacingOccurrences(of: " # miruun-managed-custom-provider", with: "")
        let parsedCustom = try customDefinition(spoof)
        XCTAssertNil(parsedCustom.entries["base_url"])
        let authBefore = try Data(contentsOf: auth)
        try assertBlocked(spoof)
        XCTAssertEqual(try Data(contentsOf: auth), authBefore)
    }

    func testOAuthAliasRejectsSealedMalformedAndOversizedConfigurations() throws {
        try writeAuth(["auth_mode": "chatgpt", "tokens": ["access_token": "SYNTHETIC_OAUTH"]])
        let authBefore = try Data(contentsOf: auth)
        for value in ["{}", "{ other = { name = 'Existing' } }", "[]", "42", "'invalid'"] {
            try assertBlocked("model_provider = \"openai\"\nmodel_providers = \(value)\n")
        }
        for value in ["[]", "42", "'invalid'"] {
            try assertBlocked("model_provider = \"openai\"\nmodel_providers = { custom = \(value) }\n")
            try assertBlocked("model_provider = \"openai\"\n[model_providers]\ncustom = \(value)\n")
        }
        try assertBlocked("#" + String(repeating: " ", count: 1_024 * 1_024 - 2) + "\n")
        XCTAssertEqual(try Data(contentsOf: auth), authBefore)
    }

    func testOAuthAliasRepairWaitsForClientsAndRestartsStableSampling() throws {
        let text = "model_provider = \"openai\"\n"
        try writeConfig(text)
        try writeAuth(["auth_mode": "chatgpt", "tokens": ["access_token": "SYNTHETIC_OAUTH"]])
        let authBefore = try Data(contentsOf: auth)
        var running = false
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { running })
        XCTAssertEqual(guarder.check().phase, .waiting)
        running = true
        let waiting = guarder.check()
        XCTAssertEqual(waiting.phase, .waiting)
        XCTAssertTrue(waiting.message.contains("退出 Codex/ChatGPT"))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), text)
        XCTAssertEqual(try Data(contentsOf: auth), authBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        running = false
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(guarder.check().phase, .updated)
        XCTAssertEqual(guarder.check().phase, .ready)
    }

    func testOAuthAliasRepairDoesNotOverwriteConfigChangedBeforeCommit() throws {
        let text = "model_provider = \"openai\"\n"
        let external = text + "# external change\n"
        try writeConfig(text)
        try writeAuth(["auth_mode": "chatgpt", "tokens": ["access_token": "SYNTHETIC_OAUTH"]])
        let authBefore = try Data(contentsOf: auth)
        var calls = 0
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: {
            calls += 1
            if calls == 3 { try self.writeConfig(external) }
            return false
        })
        XCTAssertEqual(guarder.check().phase, .waiting)
        let status = guarder.check()
        XCTAssertEqual(status.phase, .blocked)
        XCTAssertTrue(status.message.contains("变化"))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), external)
        XCTAssertEqual(try Data(contentsOf: auth), authBefore)
        XCTAssertEqual(try receipt(status), ["auth_existed": true, "config_written": false, "auth_written": false, "complete": false])
        XCTAssertTrue(try pendingFiles().isEmpty)
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
            let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
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
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(guarder.check().phase, .updated)
        XCTAssertEqual(try Data(contentsOf: auth), originalAuth)
    }

    func testInlineBearerCreatesAuthAfterTwoStableSamplesAndPreservesProvider() throws {
        let token = "SYNTHETIC_INLINE_KEY"
        let text = "# Preserve model and provider\n" + inlineProvider(token: token) + "# Preserve this comment\n"
        try writeConfig(text)
        try FileManager.default.removeItem(at: auth)
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
        let first = guarder.check()
        XCTAssertEqual(first.phase, .waiting)
        XCTAssertFalse(first.message.contains(token))
        XCTAssertFalse(FileManager.default.fileExists(atPath: auth.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        let updated = guarder.check()
        XCTAssertEqual(updated.phase, .updated)
        XCTAssertFalse(updated.message.contains(token))
        let parsed = try CatalogTOML.parse(String(contentsOf: config, encoding: .utf8))
        XCTAssertEqual(parsed.entries["model_provider"].stringValue, "openai")
        XCTAssertEqual(parsed.entries["model"].stringValue, "original-model")
        XCTAssertEqual(parsed.entries["openai_base_url"].stringValue, "http://127.0.0.1:8317/v1")
        let rewritten = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(rewritten.contains(text.components(separatedBy: "[model_providers.proxy]")[1]))
        XCTAssertTrue(rewritten.hasPrefix("# Preserve model and provider\n"))
        let authData = try Data(contentsOf: auth)
        let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: authData) as? [String: String])
        XCTAssertEqual(credentials, ["auth_mode": "apikey", "OPENAI_API_KEY": token])
        let directory = URL(fileURLWithPath: try XCTUnwrap(updated.backupPath)).deletingLastPathComponent()
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("config.toml")), Data(text.utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("auth.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("auth-originally-absent").path))
        XCTAssertEqual(try receipt(updated), ["auth_existed": false, "config_written": true, "auth_written": true, "complete": true])
        XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent("receipt.json"), encoding: .utf8).contains(token))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: auth.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(try pendingFiles().isEmpty)
        XCTAssertEqual(guarder.check().phase, .ready)
        XCTAssertEqual(try Data(contentsOf: auth), authData)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).count, 1)
    }

    func testInlineBearerReplacesOAuthOnlyAfterBackingUpOriginalBytes() throws {
        try writeConfig(inlineProvider())
        try writeAuth(["auth_mode": "chatgpt", "tokens": ["access_token": "SYNTHETIC_OAUTH"], "OPENAI_API_KEY": NSNull()])
        let original = try Data(contentsOf: auth)
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(try Data(contentsOf: auth), original)
        let status = guarder.check()
        XCTAssertEqual(status.phase, .updated)
        let directory = URL(fileURLWithPath: try XCTUnwrap(status.backupPath)).deletingLastPathComponent()
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("auth.json")), original)
        XCTAssertEqual(try receipt(status), ["auth_existed": true, "config_written": true, "auth_written": true, "complete": true])
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: auth)) as? [String: String])
        XCTAssertEqual(value, ["auth_mode": "apikey", "OPENAI_API_KEY": "SYNTHETIC_INLINE_KEY"])
    }

    func testInlineBearerChangesRestartWindowAndSameKeyDoesNotRewriteAuth() throws {
        try writeConfig(inlineProvider(token: key))
        let original = try Data(contentsOf: auth)
        let originalInode = try FileManager.default.attributesOfItem(atPath: auth.path)[.systemFileNumber] as? NSNumber
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
        XCTAssertEqual(guarder.check().phase, .waiting)
        let sameKey = guarder.check()
        XCTAssertEqual(sameKey.phase, .updated)
        XCTAssertEqual(try Data(contentsOf: auth), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: auth.path)[.systemFileNumber] as? NSNumber, originalInode)
        XCTAssertEqual(try receipt(sameKey)["auth_written"], false)
        try writeConfig(inlineProvider(token: "SYNTHETIC_KEY_ONE"))
        XCTAssertEqual(guarder.check().phase, .waiting)
        try writeConfig(inlineProvider(token: "SYNTHETIC_KEY_TWO"))
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(try Data(contentsOf: auth), original)
        XCTAssertEqual(guarder.check().phase, .updated)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: auth)) as? [String: String])
        XCTAssertEqual(value["OPENAI_API_KEY"], "SYNTHETIC_KEY_TWO")
        XCTAssertEqual(guarder.check().phase, .ready)
    }

    func testRunningClientsPreventBackupAndResetStableSamples() throws {
        let text = inlineProvider()
        try writeConfig(text)
        let originalAuth = try Data(contentsOf: auth)
        var running = false
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { running })
        XCTAssertEqual(guarder.check().phase, .waiting)
        running = true
        for _ in 0..<2 {
            let status = guarder.check()
            XCTAssertEqual(status.phase, .waiting)
            XCTAssertTrue(status.message.contains("退出 Codex/ChatGPT"))
            XCTAssertNil(status.backupPath)
        }
        XCTAssertEqual(try Data(contentsOf: auth), originalAuth)
        XCTAssertEqual(try Data(contentsOf: config), Data(text.utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        running = false
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(guarder.check().phase, .updated)
    }

    func testUnknownClientStateBlocksBeforeAnyBackupOrWrite() throws {
        try writeConfig(inlineProvider())
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { throw NSError(domain: "SyntheticProcessFailure", code: 1) })
        XCTAssertEqual(guarder.check().phase, .blocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), inlineProvider())
    }

    func testExternalAuthChangeBeforeCommitDoesNotOverwriteEitherFile() throws {
        let text = inlineProvider()
        try writeConfig(text)
        var calls = 0
        let externalAuth = try JSONSerialization.data(withJSONObject: ["auth_mode": "apikey", "OPENAI_API_KEY": "SYNTHETIC_EXTERNAL_KEY"])
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: {
            calls += 1
            if calls == 3 { try externalAuth.write(to: self.auth) }
            return false
        })
        XCTAssertEqual(guarder.check().phase, .waiting)
        let status = guarder.check()
        XCTAssertEqual(status.phase, .blocked)
        XCTAssertTrue(status.message.contains("变化"))
        XCTAssertEqual(try Data(contentsOf: auth), externalAuth)
        XCTAssertEqual(try Data(contentsOf: config), Data(text.utf8))
        XCTAssertEqual(try receipt(status), ["auth_existed": true, "config_written": false, "auth_written": false, "complete": false])
        XCTAssertTrue(try pendingFiles().isEmpty)
    }

    func testAuthConflictAfterPendingDoesNotCommitConfigOrOverwriteAuth() throws {
        let text = inlineProvider()
        try writeConfig(text)
        try FileManager.default.removeItem(at: auth)
        var calls = 0
        let externalAuth = try JSONSerialization.data(withJSONObject: ["auth_mode": "apikey", "OPENAI_API_KEY": "SYNTHETIC_EXTERNAL_KEY"])
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: {
            calls += 1
            if calls == 4 { try externalAuth.write(to: self.auth) }
            return false
        })
        XCTAssertEqual(guarder.check().phase, .waiting)
        let status = guarder.check()
        XCTAssertEqual(status.phase, .blocked)
        XCTAssertTrue(status.message.contains("未获得完整确认"))
        XCTAssertFalse(status.message.contains("未覆盖"))
        XCTAssertEqual(try Data(contentsOf: config), Data(text.utf8))
        XCTAssertEqual(try Data(contentsOf: auth), externalAuth)
        XCTAssertEqual(try receipt(status), ["auth_existed": false, "config_written": false, "auth_written": false, "complete": false])
        XCTAssertEqual(try pendingFiles().count, 1)
        XCTAssertEqual(guarder.check(), status)
    }

    func testHalfCommitKeepsPendingAndBlocksRestartOnlyForAffectedHome() throws {
        let originalConfig = inlineProvider()
        try writeConfig(originalConfig)
        try FileManager.default.removeItem(at: auth)
        var calls = 0
        let externalAuth = try JSONSerialization.data(withJSONObject: ["auth_mode": "apikey", "OPENAI_API_KEY": "SYNTHETIC_EXTERNAL_KEY"])
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: {
            calls += 1
            if calls == 5 { try externalAuth.write(to: self.auth) }
            return false
        })
        XCTAssertEqual(guarder.check().phase, .waiting)
        let partial = guarder.check()
        XCTAssertEqual(partial.phase, .blocked)
        XCTAssertTrue(partial.message.contains("未获得完整确认"))
        XCTAssertFalse(partial.message.contains("未覆盖"))
        XCTAssertEqual(try Data(contentsOf: auth), externalAuth)
        XCTAssertEqual(try Data(contentsOf: config), Data(originalConfig.utf8))
        XCTAssertEqual(try receipt(partial), ["auth_existed": false, "config_written": false, "auth_written": true, "complete": false])
        let pending = try XCTUnwrap(pendingFiles().first)
        let pendingData = try Data(contentsOf: pending)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: pendingData) as? [String: String])
        XCTAssertEqual(value, ["home": home.path, "backup_path": try XCTUnwrap(partial.backupPath)])
        XCTAssertFalse(String(decoding: pendingData, as: UTF8.self).contains("SYNTHETIC"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: pending.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(guarder.check(), partial)
        let restarted = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false }).check()
        XCTAssertEqual(restarted.phase, .blocked)
        XCTAssertEqual(restarted.backupPath, partial.backupPath)
        XCTAssertEqual(try Data(contentsOf: pending), pendingData)

        let otherHome = root.appendingPathComponent("other-home", isDirectory: true)
        try FileManager.default.createDirectory(at: otherHome, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data(inlineProvider().utf8).write(to: otherHome.appendingPathComponent("config.toml"))
        let other = ContinuityGuard(home: otherHome, backupDirectory: backups, clientsAreRunning: { false })
        XCTAssertEqual(other.check().phase, .waiting)
        XCTAssertEqual(other.check().phase, .updated)
        XCTAssertEqual(try Data(contentsOf: pending), pendingData)
        XCTAssertEqual(try Data(contentsOf: auth), externalAuth)
    }

    func testClientsStartingBetweenAuthAndConfigLeaveOriginalRouteAndPersistentPending() throws {
        let originalConfig = inlineProvider()
        try writeConfig(originalConfig)
        try FileManager.default.removeItem(at: auth)
        var calls = 0
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: {
            calls += 1
            return calls >= 5
        })
        XCTAssertEqual(guarder.check().phase, .waiting)
        let partial = guarder.check()
        XCTAssertEqual(partial.phase, .blocked)
        XCTAssertTrue(partial.message.contains("未获得完整确认"))
        XCTAssertFalse(partial.message.contains("未覆盖"))
        let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: auth)) as? [String: String])
        XCTAssertEqual(credentials, ["auth_mode": "apikey", "OPENAI_API_KEY": "SYNTHETIC_INLINE_KEY"])
        XCTAssertEqual(try Data(contentsOf: config), Data(originalConfig.utf8))
        XCTAssertEqual(try receipt(partial), ["auth_existed": false, "config_written": false, "auth_written": true, "complete": false])
        XCTAssertEqual(try pendingFiles().count, 1)
        XCTAssertEqual(guarder.check(), partial)
        XCTAssertEqual(ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false }).check().phase, .blocked)
    }

    func testInlineProviderStillRejectsUnknownAuthAndUnsafeAuthPaths() throws {
        try writeConfig(inlineProvider())
        try writeAuth(["auth_mode": "external", "tokens": ["access_token": "SYNTHETIC_EXTERNAL_AUTH"]])
        let original = try Data(contentsOf: auth)
        try assertBlocked(inlineProvider())
        XCTAssertEqual(try Data(contentsOf: auth), original)
        let target = root.appendingPathComponent("auth-original.json")
        try FileManager.default.moveItem(at: auth, to: target)
        try FileManager.default.createSymbolicLink(at: auth, withDestinationURL: target)
        try assertBlocked(inlineProvider())
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testOpenAIWithoutAuthDoesNotGuessUnselectedInlineBearer() throws {
        let text = inlineProvider().replacingOccurrences(of: "model_provider = \"proxy\"", with: "model_provider = \"openai\"")
        try writeConfig(text)
        try FileManager.default.removeItem(at: auth)
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(try Data(contentsOf: config), Data(text.utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: auth.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }

    func testLoopbackAllowlistAndWireProtocol() throws {
        for endpoint in ["http://localhost:8317/v1", "https://127.0.0.1/v1", "http://[::1]:8317/v1"] {
            try writeConfig(provider(endpoint: endpoint))
            let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
            XCTAssertEqual(guarder.check().phase, .waiting)
            XCTAssertEqual(guarder.check().phase, .updated)
        }
        for endpoint in ["https://remote.example/v1", "http://127.0.0.2/v1", "http://localhost.evil/v1", "http://user@localhost/v1", "http://localhost/v1?token=SYNTHETIC", "http://localhost/v1#fragment", "http://localhost:0/v1", "http://localhost:65536/v1", "http://localhost:/v1", "http://localhost/%broken", "file:///localhost/v1"] {
            try writeConfig(provider(endpoint: endpoint))
            let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
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
        let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
        XCTAssertEqual(guarder.check().phase, .waiting)
        XCTAssertEqual(guarder.check().phase, .updated)
    }

    func testAlreadyOpenAILoopbackIsReadyWithoutBackupOrMutation() throws {
        for rootProvider in ["", "model_provider = \"openai\"\n"] {
            let text = rootProvider + "openai_base_url = \"http://localhost:8317/v1\"\nmodel = \"original-model\"\n"
            try writeConfig(text)
            let guarder = ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false })
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
        XCTAssertEqual(ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false }).check().phase, .blocked)
        try FileManager.default.removeItem(at: config)
        XCTAssertEqual(link(original.path, config.path), 0)
        XCTAssertEqual(ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false }).check().phase, .blocked)
        try FileManager.default.removeItem(at: config)
        try writeConfig(provider())
        try FileManager.default.removeItem(at: auth)
        XCTAssertEqual(mkfifo(auth.path, 0o600), 0)
        XCTAssertEqual(ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false }).check().phase, .blocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }

    func testOversizedFilesAndUnsafeBackupLocationAreBlocked() throws {
        try writeConfig(provider())
        try Data(repeating: 32, count: 65_537).write(to: auth)
        XCTAssertEqual(ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false }).check().phase, .blocked)
        try writeAuth(["OPENAI_API_KEY": key])
        try Data(repeating: 32, count: 1_024 * 1_024 + 1).write(to: config)
        XCTAssertEqual(ContinuityGuard(home: home, backupDirectory: backups, clientsAreRunning: { false }).check().phase, .blocked)
        try writeConfig(provider())
        let unsafe = ContinuityGuard(home: home, backupDirectory: home.appendingPathComponent("backups"), clientsAreRunning: { false })
        XCTAssertEqual(unsafe.check().phase, .waiting)
        XCTAssertEqual(unsafe.check().phase, .blocked)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), provider())
    }
}

private extension Optional where Wrapped == CatalogValue {
    var tableValue: CatalogTable? {
        guard case let .table(value)? = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value)? = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value)? = self else { return nil }
        return value
    }
}
