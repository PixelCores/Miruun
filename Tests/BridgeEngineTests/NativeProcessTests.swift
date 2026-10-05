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

    private func configurationShell(_ setup: String = "") throws -> URL {
        try executable("""
        test "$1" = '-ilc'
        test "$CODEX_SHELL" = '1'
        test "$DISABLE_AUTO_UPDATE" = 'true'
        test "$ZSH_TMUX_AUTOSTARTED" = 'true'
        test "$ZSH_TMUX_AUTOSTART" = 'false'
        printf '%s\\n' 'SYNTHETIC_SHELL_BANNER'
        \(setup)
        exec /bin/sh -c "$2"
        """)
    }

    private func configurationDirectory(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testConfigurationDirectoriesUseExistingDefaultsWithoutReadingFiles() throws {
        let codex = try configurationDirectory(".codex"), claude = try configurationDirectory(".claude")
        let result = try NativeDiscovery.configurationDirectories(home: root, shell: configurationShell(), environment: [:])
        XCTAssertEqual(result.codex.directory?.path, codex.path)
        XCTAssertEqual(result.claude.directory?.path, claude.path)
        XCTAssertEqual(result.codex.source, "默认目录")
        XCTAssertEqual(result.claude.source, "默认目录")
        XCTAssertNil(result.codex.error)
        XCTAssertNil(result.claude.error)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: codex.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: claude.path).isEmpty)
    }

    func testConfigurationDirectoriesPreserveLiteralEnvironmentOverrides() throws {
        let codex = try configurationDirectory("data ' $(ignored) `ignored` 中文")
        let claude = try configurationDirectory("claude custom")
        let result = try NativeDiscovery.configurationDirectories(home: root, shell: configurationShell(), environment: [
            "CODEX_HOME": codex.path, "CLAUDE_CONFIG_DIR": claude.path
        ])
        XCTAssertEqual(result.codex.directory?.path, codex.path)
        XCTAssertEqual(result.claude.directory?.path, claude.path)
        XCTAssertEqual(result.codex.source, "CODEX_HOME")
        XCTAssertEqual(result.claude.source, "CLAUDE_CONFIG_DIR")
        XCTAssertNil(result.codex.error)
        XCTAssertNil(result.claude.error)
    }

    func testConfigurationDirectoriesNeverFallBackFromInvalidExplicitOverrides() throws {
        _ = try configurationDirectory(".codex")
        let claude = try configurationDirectory(".claude")
        let file = root.appendingPathComponent("regular-file")
        try Data("SYNTHETIC_FILE".utf8).write(to: file)
        let shell = try configurationShell()
        for path in ["", "relative/path", root.appendingPathComponent("missing").path, file.path,
                     root.path + "/.codex/../.codex", root.path + "/.codex/./", root.path + "/invalid\npath"] {
            let result = try NativeDiscovery.configurationDirectories(home: root, shell: shell, environment: ["CODEX_HOME": path])
            XCTAssertNil(result.codex.directory, path)
            XCTAssertNotNil(result.codex.error, path)
            XCTAssertEqual(result.codex.source, "CODEX_HOME")
            XCTAssertEqual(result.claude.directory?.path, claude.path)
        }
        let result = try NativeDiscovery.configurationDirectories(home: root, shell: shell, environment: ["CLAUDE_CONFIG_DIR": file.path])
        XCTAssertNil(result.claude.directory)
        XCTAssertNotNil(result.claude.error)
        XCTAssertEqual(result.claude.source, "CLAUDE_CONFIG_DIR")
    }

    func testConfigurationDirectoriesDoNotCreateMissingDefaults() throws {
        let result = try NativeDiscovery.configurationDirectories(home: root, shell: configurationShell(), environment: [:])
        XCTAssertNil(result.codex.directory)
        XCTAssertNil(result.claude.directory)
        XCTAssertNotNil(result.codex.error)
        XCTAssertNotNil(result.claude.error)
        XCTAssertEqual(result.codex.source, "默认目录")
        XCTAssertEqual(result.claude.source, "默认目录")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude").path))
    }

    func testConfigurationDirectoriesUseLoginShellOverridesBeforeInheritedValues() throws {
        let inherited = try configurationDirectory("inherited")
        let codex = try configurationDirectory("shell codex"), claude = try configurationDirectory("shell claude")
        let shell = try configurationShell("""
        export CODEX_HOME="$SYNTHETIC_CODEX"
        export CLAUDE_CONFIG_DIR="$SYNTHETIC_CLAUDE"
        """)
        let result = try NativeDiscovery.configurationDirectories(home: root, shell: shell, environment: [
            "CODEX_HOME": inherited.path, "CLAUDE_CONFIG_DIR": inherited.path,
            "SYNTHETIC_CODEX": codex.path, "SYNTHETIC_CLAUDE": claude.path
        ])
        XCTAssertEqual(result.codex.directory?.path, codex.path)
        XCTAssertEqual(result.claude.directory?.path, claude.path)
        XCTAssertEqual(result.codex.source, "CODEX_HOME（登录 shell）")
        XCTAssertEqual(result.claude.source, "CLAUDE_CONFIG_DIR（登录 shell）")
    }

    func testConfigurationDirectoriesMatchDesktopMergeForUnsetShellVariables() throws {
        let codex = try configurationDirectory("inherited codex"), claude = try configurationDirectory("inherited claude")
        let shell = try configurationShell("unset CODEX_HOME CLAUDE_CONFIG_DIR")
        let result = try NativeDiscovery.configurationDirectories(home: root, shell: shell, environment: [
            "CODEX_HOME": codex.path, "CLAUDE_CONFIG_DIR": claude.path
        ])
        XCTAssertEqual(result.codex.directory?.path, codex.path)
        XCTAssertEqual(result.claude.directory?.path, claude.path)
        XCTAssertEqual(result.codex.source, "CODEX_HOME")
        XCTAssertEqual(result.claude.source, "CLAUDE_CONFIG_DIR")
        let defaultCodex = try configurationDirectory(".codex"), defaultClaude = try configurationDirectory(".claude")
        let defaults = try NativeDiscovery.configurationDirectories(home: root, shell: shell, environment: [:])
        XCTAssertEqual(defaults.codex.directory?.path, defaultCodex.path)
        XCTAssertEqual(defaults.claude.directory?.path, defaultClaude.path)
    }

    func testConfigurationDirectoriesRejectEmptyLoginShellOverrides() throws {
        let directory = try configurationDirectory("inherited")
        let shell = try configurationShell("export CODEX_HOME='' CLAUDE_CONFIG_DIR=''")
        let result = try NativeDiscovery.configurationDirectories(home: root, shell: shell, environment: [
            "CODEX_HOME": directory.path, "CLAUDE_CONFIG_DIR": directory.path
        ])
        XCTAssertNil(result.codex.directory)
        XCTAssertNil(result.claude.directory)
        XCTAssertNotNil(result.codex.error)
        XCTAssertNotNil(result.claude.error)
        XCTAssertEqual(result.codex.source, "CODEX_HOME（登录 shell）")
        XCTAssertEqual(result.claude.source, "CLAUDE_CONFIG_DIR（登录 shell）")
    }

    func testConfigurationDirectoriesRejectSymbolicLinksWithoutResolvingAliases() throws {
        let directory = try configurationDirectory("actual")
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        let result = try NativeDiscovery.configurationDirectories(home: root, shell: configurationShell(), environment: [
            "CODEX_HOME": link.path, "CLAUDE_CONFIG_DIR": link.appendingPathComponent("nested").path
        ])
        XCTAssertNil(result.codex.directory)
        XCTAssertNil(result.claude.directory)
        XCTAssertTrue(result.codex.error?.contains("符号链接") ?? false)
        XCTAssertTrue(result.claude.error?.contains("符号链接") ?? false)
    }

    func testConfigurationDirectoriesPreferValidatedManualCodexOverride() throws {
        let manual = try configurationDirectory("manual codex"), discovered = try configurationDirectory("discovered")
        let shell = try configurationShell()
        let environment = ["CODEX_HOME": discovered.path, "CLAUDE_CONFIG_DIR": discovered.path]
        let result = try NativeDiscovery.configurationDirectories(home: root, codexOverride: manual.path, shell: shell, environment: environment)
        XCTAssertEqual(result.codex.directory?.path, manual.path)
        XCTAssertEqual(result.codex.source, "手动选择")
        XCTAssertNil(result.codex.error)
        XCTAssertEqual(result.claude.directory?.path, discovered.path)
        let invalid = try NativeDiscovery.configurationDirectories(home: root, codexOverride: "relative", shell: shell, environment: environment)
        XCTAssertNil(invalid.codex.directory)
        XCTAssertNotNil(invalid.codex.error)
        XCTAssertEqual(invalid.codex.source, "手动选择")
    }

    func testConfigurationDirectoriesRejectRecordSeparatorsInsteadOfAcceptingExistingPrefix() throws {
        let directory = try configurationDirectory("existing-prefix")
        let shell = try configurationShell()
        for key in ["CODEX_HOME", "CLAUDE_CONFIG_DIR"] {
            for separator in ["\u{1e}", "\u{1f}"] {
                var environment = ["CODEX_HOME": directory.path, "CLAUDE_CONFIG_DIR": directory.path]
                environment[key] = directory.path + separator + "SYNTHETIC_SUFFIX"
                XCTAssertThrowsError(try NativeDiscovery.configurationDirectories(home: root, shell: shell, environment: environment)) {
                    XCTAssertEqual(($0 as? NativeEngineError)?.code, "configuration_shell_failed")
                    XCTAssertFalse(($0 as? NativeEngineError)?.message.contains("SYNTHETIC") ?? true)
                }
            }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testConfigurationDirectoriesRequireWholeFramedRecords() throws {
        let directory = try configurationDirectory("existing-prefix")
        for key in ["CODEX_HOME", "CLAUDE_CONFIG_DIR"] {
            let shell = try executable("""
            printf '\\036MIRUUN_CONFIG_DIRECTORY\\037CODEX_HOME\\037x\\037%s\\036' "$SYNTHETIC_PATH"
            if [ "$SYNTHETIC_BROKEN_KEY" = 'CODEX_HOME' ]; then printf 'SYNTHETIC_SUFFIX\\036'; fi
            printf '\\036MIRUUN_CONFIG_DIRECTORY\\037CLAUDE_CONFIG_DIR\\037x\\037%s\\036' "$SYNTHETIC_PATH"
            if [ "$SYNTHETIC_BROKEN_KEY" = 'CLAUDE_CONFIG_DIR' ]; then printf 'SYNTHETIC_SUFFIX\\036'; fi
            """)
            XCTAssertThrowsError(try NativeDiscovery.configurationDirectories(home: root, shell: shell, environment: [
                "SYNTHETIC_PATH": directory.path, "SYNTHETIC_BROKEN_KEY": key
            ])) {
                XCTAssertEqual(($0 as? NativeEngineError)?.code, "configuration_shell_failed")
                XCTAssertFalse(($0 as? NativeEngineError)?.message.contains("SYNTHETIC") ?? true)
            }
        }
    }

    func testConfigurationDirectoriesRejectFailedOrIncompleteShellWithoutSurfacingOutput() throws {
        for script in ["printf '%s' 'SYNTHETIC_PRIVATE_OUTPUT'; exit 1", "printf '%s' 'SYNTHETIC_PRIVATE_OUTPUT'", "exit 0"] {
            let shell = try executable(script)
            XCTAssertThrowsError(try NativeDiscovery.configurationDirectories(home: root, shell: shell, environment: [:])) {
                XCTAssertEqual(($0 as? NativeEngineError)?.code, "configuration_shell_failed")
                XCTAssertFalse(($0 as? NativeEngineError)?.message.contains("SYNTHETIC") ?? true)
            }
        }
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

    func testLaunchHomeProbePreservesLiteralPathAndIgnoresShellBanner() throws {
        let shell = try executable("""
        test "$1" = '-ilc'
        test "$CODEX_SHELL" = '1'
        test "$DISABLE_AUTO_UPDATE" = 'true'
        test "$ZSH_TMUX_AUTOSTARTED" = 'true'
        test "$ZSH_TMUX_AUTOSTART" = 'false'
        printf '%s\\n' 'SYNTHETIC_SHELL_BANNER'
        exec /bin/sh -c "$2"
        """)
        let home = root.appendingPathComponent("data ' $(ignored) `ignored` 中文")
        XCTAssertNoThrow(try NativeDiscovery.verifyLaunchHome(home, shell: shell, environment: ["HOME": root.path]))
    }

    func testLaunchHomeProbeRejectsShellOverrideAndUnsetWithoutSurfacingOutput() throws {
        for setup in ["export CODEX_HOME='/SYNTHETIC_OTHER_HOME'", "unset CODEX_HOME"] {
            let shell = try executable("""
            printf '%s\\n' 'SYNTHETIC_PRIVATE_OUTPUT'
            \(setup)
            exec /bin/sh -c "$2"
            """)
            XCTAssertThrowsError(try NativeDiscovery.verifyLaunchHome(root, shell: shell, environment: [:])) {
                XCTAssertEqual(($0 as? NativeEngineError)?.code, "launch_home_overridden")
                XCTAssertFalse(($0 as? NativeEngineError)?.message.contains("SYNTHETIC") ?? true)
            }
        }
    }

    func testLaunchHomeProbeRejectsFailedShellWithoutSurfacingOutput() throws {
        let shell = try executable("printf '%s' 'SYNTHETIC_PRIVATE_OUTPUT'; exit 1")
        XCTAssertThrowsError(try NativeDiscovery.verifyLaunchHome(root, shell: shell, environment: [:])) {
            XCTAssertEqual(($0 as? NativeEngineError)?.code, "launch_shell_failed")
            XCTAssertFalse(($0 as? NativeEngineError)?.message.contains("SYNTHETIC") ?? true)
        }
    }

    func testLaunchHomeProbeDetectsRealLoginShellProfileOverrideInDisposableHome() throws {
        let environment = ["HOME": root.path, "ZDOTDIR": root.path, "PATH": "/usr/bin:/bin"]
        let shell = URL(fileURLWithPath: "/bin/zsh")
        XCTAssertNoThrow(try NativeDiscovery.verifyLaunchHome(root, shell: shell, environment: environment))
        try Data("export CODEX_HOME='/SYNTHETIC_OTHER_HOME'\n".utf8).write(to: root.appendingPathComponent(".zprofile"))
        XCTAssertThrowsError(try NativeDiscovery.verifyLaunchHome(root, shell: shell, environment: environment)) {
            XCTAssertEqual(($0 as? NativeEngineError)?.code, "launch_home_overridden")
        }
    }
}
