import XCTest
import Foundation
import Darwin
@testable import BridgeEngine

/// Every read is confined to a fresh synthetic directory, never a user's home.
final class ProviderCatalogTests: XCTestCase {
    private var home: URL!
    private var config: URL { home.appendingPathComponent("config.toml") }

    override func setUpWithError() throws {
        let temporary = try NativeFileSafety.temporaryDirectory()
        home = temporary.appendingPathComponent("ProviderCatalogTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let home { try FileManager.default.removeItem(at: home) }
    }

    private func catalog(_ content: String) throws -> ProviderCatalogResult {
        try Data(content.utf8).write(to: config)
        return try NativeProviderCatalog.read(home: home)
    }

    private func literal(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func provider(_ endpoint: String) throws -> NativeProvider {
        try catalog("[model_providers.demo]\nname = \"Demo\"\nbase_url = " + literal(endpoint) + "\n").providers[0]
    }

    private func assertError(_ code: String, content: String? = nil, selectedHome: URL? = nil,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        if let content { try Data(content.utf8).write(to: config) }
        XCTAssertThrowsError(try NativeProviderCatalog.read(home: selectedHome ?? home), file: file, line: line) { error in
            guard let safe = error as? ProviderCatalogError else {
                return XCTFail("Unexpected error type", file: file, line: line)
            }
            XCTAssertEqual(safe.code, code, file: file, line: line)
            XCTAssertFalse(safe.message.contains("SYNTHETIC_"), file: file, line: line)
            XCTAssertFalse(safe.message.contains(self.home.path), file: file, line: line)
            XCTAssertEqual(safe.localizedDescription, safe.message, file: file, line: line)
        }
    }

    func testOnlyAllowlistedMetadataEscapes() throws {
        let content = """
        model_provider = "demo"
        model = "SYNTHETIC_PRIVATE_MODEL"
        api_key = "SYNTHETIC_ROOT_KEY"
        [model_providers.demo]
        name = "Example Provider"
        base_url = "https://SYNTHETIC_USER:SYNTHETIC_PASSWORD@Example.COM:8443/SYNTHETIC_PATH?key=SYNTHETIC_QUERY#SYNTHETIC_FRAGMENT"
        env_key = "SYNTHETIC_ENV_KEY"
        experimental_bearer_token = "SYNTHETIC_TOKEN"
        http_headers = { Authorization = "SYNTHETIC_AUTH_HEADER" }
        query_params = { token = "SYNTHETIC_PARAMETER" }
        """
        let result = try catalog(content)
        XCTAssertEqual(result.providers.count, 1)
        let selected = try XCTUnwrap(result.providers.first)
        XCTAssertEqual(selected.id, "demo")
        XCTAssertEqual(selected.name, "Example Provider")
        XCTAssertEqual(selected.endpointOrigin, "https://example.com:8443")
        XCTAssertTrue(selected.selectable)
        XCTAssertNil(selected.blocker)
        XCTAssertEqual(result.configSource, "CODEX_HOME/config.toml")
        XCTAssertEqual(result.configRevision.count, 64)
        XCTAssertTrue(result.overridesUnknown)
        let encoded = try JSONEncoder().encode(result)
        let output = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(output.contains("SYNTHETIC_"))
        XCTAssertFalse(output.contains(home.path))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["providers", "config_source", "config_revision", "overrides_unknown"])
        let providers = try XCTUnwrap(object["providers"] as? [[String: Any]])
        XCTAssertEqual(Set(providers[0].keys), ["id", "name", "endpoint_origin", "selectable", "blocker"])
        XCTAssertTrue(providers[0]["blocker"] is NSNull)
    }

    func testBuiltinHasNoGuessedEndpointOrDefault() throws {
        XCTAssertTrue(try catalog("").providers.isEmpty)
        let result = try catalog("model_provider = \"openai\"\n")
        let selected = try XCTUnwrap(result.providers.first)
        XCTAssertEqual(selected.id, "openai")
        XCTAssertEqual(selected.name, "openai")
        XCTAssertNil(selected.endpointOrigin)
        XCTAssertFalse(selected.selectable)
        XCTAssertEqual(selected.blocker, "host_unknown")
        let data = try JSONEncoder().encode(result)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("api.openai.com"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try XCTUnwrap(object["providers"] as? [[String: Any]])
        XCTAssertTrue(providers[0]["endpoint_origin"] is NSNull)
    }

    func testActiveEntryIsNotDuplicatedAndProvidersAreSorted() throws {
        let result = try catalog("model_provider = \"middle\"\n[model_providers.zebra]\n[model_providers.middle]\n[model_providers.alpha]\n")
        XCTAssertEqual(result.providers.map(\.id), ["alpha", "middle", "zebra"])
    }

    func testMissingOrEmptyEndpointIsHostUnknown() throws {
        XCTAssertEqual(try catalog("[model_providers.demo]\nname = \"Demo\"\n").providers[0].blocker, "host_unknown")
        XCTAssertEqual(try provider("").blocker, "host_unknown")
    }

    func testValidOriginsStripEveryNonOriginPart() throws {
        let cases = [
            "HTTPS://EXAMPLE.COM/path?a=b#c": "https://example.com",
            "http://localhost:1234/v1": "http://localhost:1234",
            "https://127.0.0.1:443/v1": "https://127.0.0.1:443",
            "https://[2001:0db8::0001]:8443/v1": "https://[2001:db8::1]:8443",
            "http://[::1]/v1": "http://[::1]",
            "http://[::]/v1": "http://[::]",
            "http://[::ffff:192.0.2.1]/v1": "http://[::ffff:c000:201]",
            "https://user%40name:password@host.test:0443/private": "https://host.test:443",
            "https://bücher.example/v1": "https://xn--bcher-kva.example",
            "https://EXAMPLE.COM./v1": "https://example.com."
        ]
        for (endpoint, expected) in cases {
            let result = try provider(endpoint)
            XCTAssertEqual(result.endpointOrigin, expected, endpoint)
            XCTAssertTrue(result.selectable, endpoint)
            XCTAssertNil(result.blocker, endpoint)
        }
    }

    func testInvalidEndpointsAreNonselectable() throws {
        let invalid = [
            "ftp://example.com", "file:///private/config", "javascript:alert(1)",
            "example.com/v1", "//example.com/v1", "https:///v1", "https://",
            "https://:443/v1", "https://example.com:", "https://example.com:abc",
            "https://example.com:65536", "https://example.com:0", "https://example.com:-1",
            "https://example.com:１２３", "https://host.test /v1", " https://example.com",
            "https://example.com\n/v1", "https://example.com\t/v1", "https://example.com\0/v1",
            "https://good.test\\@evil.test", "https://first@second@host.test",
            "https://host..test", "https://-host.test", "https://host_.test", "https://%65xample.com",
            "https://example.com/%broken", "https://user%zz@host.test/v1",
            "https://[::1", "https://[::1]unexpected", "https://[fe80::1%25secret]",
            "https://999.999.999.999", "https://127.001.0.1", "https://[v1.private]",
            "https://-é.example", "https://é-.example", "https://\u{0301}a.example", "https://-\u{0301}é.example",
            "https://0x7f000001", "https://0x7f.0.0.1",
            "https://" + String(repeating: "a", count: 64) + ".test",
            "https://example.com/" + String(repeating: "x", count: 8_192)
        ]
        for endpoint in invalid {
            let result = try provider(endpoint)
            XCTAssertNil(result.endpointOrigin, endpoint)
            XCTAssertFalse(result.selectable, endpoint)
            XCTAssertEqual(result.blocker, "invalid_endpoint", endpoint)
        }
    }

    func testNonstringEndpointsAreBlocked() throws {
        for expression in ["7", "true", "[]", "{ token = \"SYNTHETIC_SECRET\" }"] {
            let result = try catalog("[model_providers.demo]\nbase_url = " + expression + "\n")
            XCTAssertFalse(result.providers[0].selectable)
            XCTAssertEqual(result.providers[0].blocker, "invalid_endpoint")
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("SYNTHETIC_SECRET"))
        }
    }

    func testProfilesCannotSupplyAnEndpoint() throws {
        let result = try catalog("""
        model_provider = "demo"
        profile = "private"
        [model_providers.demo]
        name = "Demo"
        env_key = "SYNTHETIC_ENV"
        [profiles.private.model_providers.demo]
        base_url = "https://profile-only.example/v1"
        """)
        XCTAssertEqual(result.providers[0].blocker, "host_unknown")
        XCTAssertTrue(result.overridesUnknown)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("profile-only"))
    }

    func testInvalidNamesAreDiscardedRatherThanTruncated() throws {
        for name in ["", " ", "Secret\nLabel", "\u{202E}Hidden", String(repeating: "X", count: 81), " padded ", "\u{E000}"] {
            let result = try catalog("[model_providers.demo]\nname = " + literal(name) + "\n")
            XCTAssertEqual(result.providers[0].name, "demo")
        }
        XCTAssertEqual(try catalog("[model_providers.demo]\nname = 7\n").providers[0].name, "demo")
        XCTAssertEqual(try catalog("[model_providers.demo]\nname = \"书店 📚\"\n").providers[0].name, "书店 📚")
    }

    func testInvalidIdentifiersAreSafeErrors() throws {
        for id in ["", "bad\nsecret", "secret/private", String(repeating: "X", count: 65), " padded ", "\u{202E}Hidden"] {
            try assertError("invalid_config", content: "[model_providers." + literal(id) + "]\n")
        }
        for content in ["model_provider = 7\n", "model_provider = \"secret/private\"\n", "model_providers = []\n",
                        "[model_providers]\ndemo = \"SYNTHETIC_SECRET\"\n", "[model_provider]\n"] {
            try assertError("invalid_config", content: content)
        }
    }

    func testQuotedKeysEscapesLiteralStringsAndCRLFAreSupported() throws {
        let result = try catalog("\"model_provider\" = 'demo.one'\r\n[\"model_providers\" . 'demo.one'] # comment\r\n\"name\" = \"D\\u0065mo # [model_providers.fake]\"\r\nbase_url = 'https://EXAMPLE.COM:443/v1'\r\n")
        XCTAssertEqual(result.providers.map(\.id), ["demo.one"])
        XCTAssertEqual(result.providers[0].name, "Demo # [model_providers.fake]")
        XCTAssertEqual(result.providers[0].endpointOrigin, "https://example.com:443")
    }

    func testUnknownOneLineValuesAreLexicallyValidated() throws {
        let result = try catalog("""
        model_provider = "demo"
        unknown = [1, -2, 0xDEAD, 0o755, 0b10, 1_000, 1.5e-2, true, false, +inf, nan, { note = "[model_providers.fake] # text" }, ["a", "b"],]
        [model_providers.demo]
        ignored = { "private.key" = "SYNTHETIC_SECRET", second = { a = 1 } }
        name = "Demo"
        [model_providers.demo.http_headers]
        Authorization = "SYNTHETIC_HEADER"
        """)
        XCTAssertEqual(result.providers.map(\.id), ["demo"])
        XCTAssertEqual(result.providers[0].blocker, "host_unknown")
    }

    func testInlineProviderTablesAreSupported() throws {
        let result = try catalog("model_provider = 'demo'\nmodel_providers = { demo = { name = 'Demo', base_url = 'https://example.com/v1' } }\n")
        XCTAssertEqual(result.providers.count, 1)
        XCTAssertEqual(result.providers[0].endpointOrigin, "https://example.com")
    }

    func testUnsupportedOrAmbiguousTOMLFailsClosed() throws {
        let invalid = [
            "ignored = \"\"\"\n[model_providers.fake]\n\"\"\"\n",
            "ignored = '''\n[model_providers.fake]\n'''\n",
            "ignored = [\n\"a\"\n]\n",
            "[[model_providers.fake]]\n",
            "model_providers.demo.base_url = 'https://example.com'\n",
            "timestamp = 2026-10-02T07:00:00Z\n",
            "[model_providers.demo]\n[model_providers.demo]\n",
            "name = 'first'\nname = 'second'\n",
            "ignored = { duplicate = 1, duplicate = 2 }\n",
            "ignored = { trailing = 1, }\n",
            "ignored = { dotted.key = 'value' }\n",
            "ignored = 'closed' trailing\n",
            "ignored = \"bad\\qescape\"\n",
            "ignored = \"bad\\uD800\"\n",
            "ignored = \"bad\\U00110000\"\n",
            "ignored = 01\n", "ignored = 1__0\n", "ignored = no\n",
            "ignored = 1\u{0085}\n", "ignored = 1\u{2028}\n", "ignored = 1\u{2029}\n",
            "ignored = true\r", "# comment\0\n",
            "model_providers = { demo = {} }\n[model_providers.demo]\n",
            "[model_providers]\ndemo = 1\n[model_providers.demo]\n",
            "[SYNTHETIC_PRIVATE_KEY\n", "SYNTHETIC_PRIVATE_KEY = \"unterminated"
        ]
        for content in invalid { try assertError("invalid_config", content: content) }
    }

    func testNestedTablesCannotRedefineScalarsOrInlineTables() throws {
        let invalid = [
            "[root]\nkey = 1\n[root.key.child]\n",
            "[root]\nkey = { child = {} }\n[root.key.child]\n",
            "[root.child]\n[root]\nchild = {}\n"
        ]
        for content in invalid { try assertError("invalid_config", content: content) }
        XCTAssertTrue(try catalog("[unrelated.child]\nname = 'first'\n[unrelated]\nother = 'valid implicit parent'\n").providers.isEmpty)
    }

    func testParserNestingIsBounded() throws {
        try assertError("invalid_config", content: "ignored = " + String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40))
        try assertError("invalid_config", content: "[" + Array(repeating: "nested", count: 40).joined(separator: ".") + "]")
    }

    func testInvalidUTF8NeverExposesContents() throws {
        try Data([0xff] + Array("SYNTHETIC_SECRET".utf8)).write(to: config)
        try assertError("invalid_config")
    }

    func testMissingConfigNeverFallsBackToAuth() throws {
        try Data("SYNTHETIC_PRIVATE_AUTH".utf8).write(to: home.appendingPathComponent("auth.json"))
        try assertError("config_unavailable")
    }

    func testRevisionBindsFullFileWithoutWrites() throws {
        let empty = try catalog("")
        XCTAssertEqual(empty.configRevision, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let first = try catalog("# synthetic one\n[model_providers.demo]\n")
        let bytes = try Data(contentsOf: config)
        let modification = try FileManager.default.attributesOfItem(atPath: config.path)[.modificationDate] as? Date
        XCTAssertEqual(try NativeProviderCatalog.read(home: home), first)
        XCTAssertEqual(try Data(contentsOf: config), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: config.path)[.modificationDate] as? Date, modification)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), ["config.toml"])
        let second = try catalog("# synthetic two\n[model_providers.demo]\n")
        XCTAssertEqual(first.providers, second.providers)
        XCTAssertNotEqual(first.configRevision, second.configRevision)
    }

    func testSizeLimitIsInclusive() throws {
        XCTAssertTrue(try catalog("#" + String(repeating: "x", count: 1_024 * 1_024 - 2) + "\n").providers.isEmpty)
        try assertError("config_too_large", content: "#" + String(repeating: "x", count: 1_024 * 1_024))
    }

    func testConfigSymlinkAndHardlinkAreRefused() throws {
        let target = home.appendingPathComponent("synthetic-source.toml")
        try Data("[model_providers.demo]\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
        try assertError("config_unavailable")
        try FileManager.default.removeItem(at: config)
        try FileManager.default.linkItem(at: target, to: config)
        try assertError("unsafe_config")
    }

    func testSymlinkHomeAndAncestorAreRefused() throws {
        let actual = home.appendingPathComponent("actual", isDirectory: true)
        let child = actual.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data().write(to: actual.appendingPathComponent("config.toml"))
        try Data().write(to: child.appendingPathComponent("config.toml"))
        let linked = home.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual)
        try assertError("config_unavailable", selectedHome: linked)
        try assertError("config_unavailable", selectedHome: linked.appendingPathComponent("child"))
    }

    func testCombiningMarksCannotHidePathSeparatorsFromNoFollow() throws {
        let actual = home.appendingPathComponent("actual", isDirectory: true)
        let child = actual.appendingPathComponent("\u{0301}child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data().write(to: child.appendingPathComponent("config.toml"))
        let linked = home.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual)
        try assertError("config_unavailable", selectedHome: linked.appendingPathComponent("\u{0301}child"))
        // The same Unicode name is valid when every ancestor is a real directory.
        XCTAssertTrue(try NativeProviderCatalog.read(home: child).providers.isEmpty)
    }

    func testNonregularFileAndFIFOAreRefusedWithoutBlocking() throws {
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
        try assertError("unsafe_config")
        try FileManager.default.removeItem(at: config)
        XCTAssertEqual(config.path.withCString { Darwin.mkfifo($0, 0o600) }, 0)
        try assertError("unsafe_config")
    }

    func testNonFileURLAndAmbiguousPathsAreRefused() throws {
        try assertError("unsafe_home", selectedHome: XCTUnwrap(URL(string: "https://example.com/private")))
        try assertError("unsafe_home", selectedHome: XCTUnwrap(URL(string: "file://example.com/private")))
        let ambiguous = try XCTUnwrap(URL(string: home.absoluteString + "/../other"))
        try assertError("unsafe_home", selectedHome: ambiguous)
    }
}
