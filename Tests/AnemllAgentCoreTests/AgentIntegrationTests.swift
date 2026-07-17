import Foundation
import XCTest
@testable import AnemllAgentCore

final class AgentIntegrationTests: XCTestCase {
    func testInstallsAllFiveNativeSkillAndMCPConfigurations() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let skill = Data("# Test skill\nCompatible with AnemllAgentHost v0.2.1\n".utf8)

        let results = AgentIntegrationInstaller.install(
            platforms: Set(AgentPlatform.allCases),
            skillData: skill,
            homeDirectory: home,
            installPiAdapter: false
        )

        XCTAssertEqual(results.count, AgentPlatform.allCases.count)
        XCTAssertTrue(results.allSatisfy { $0.status == .installed })

        for platform in AgentPlatform.allCases {
            let skillURL = home.appendingPathComponent(platform.skillRelativePath)
            let configURL = home.appendingPathComponent(platform.configRelativePath)
            XCTAssertEqual(try Data(contentsOf: skillURL), skill, platform.displayName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path), platform.displayName)
            let config = try String(contentsOf: configURL, encoding: .utf8)
            XCTAssertTrue(config.contains("anemll-macos-agent"), platform.displayName)
            XCTAssertTrue(config.contains("ANEMLL_TOKEN"), platform.displayName)
            XCTAssertFalse(config.contains("super-secret-test-token"), platform.displayName)
        }
    }

    func testJSONMergePreservesExistingSettingsAndServers() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let configURL = home.appendingPathComponent(AgentPlatform.droid.configRelativePath)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original: [String: Any] = [
            "persistentPermissions": ["allow": ["read"]],
            "mcpServers": [
                "keep-me": ["type": "stdio", "command": "example"]
            ]
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: configURL)

        let result = AgentIntegrationInstaller.install(
            platforms: [.droid],
            skillData: Data("skill".utf8),
            homeDirectory: home,
            installPiAdapter: false
        )

        XCTAssertEqual(result.first?.status, .installed)
        let mergedData = try Data(contentsOf: configURL)
        let merged = try XCTUnwrap(JSONSerialization.jsonObject(with: mergedData) as? [String: Any])
        XCTAssertNotNil(merged["persistentPermissions"])
        let servers = try XCTUnwrap(merged["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["keep-me"])
        let anemll = try XCTUnwrap(servers["anemll-macos-agent"] as? [String: Any])
        XCTAssertEqual(anemll["url"] as? String, "http://127.0.0.1:8765/mcp")
        let headers = try XCTUnwrap(anemll["headers"] as? [String: String])
        XCTAssertEqual(headers["Authorization"], "Bearer ${ANEMLL_TOKEN}")
    }

    func testTOMLMergePreservesOtherTablesAndReplacesOnlyAnemllEntry() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let configURL = home.appendingPathComponent(AgentPlatform.codex.configRelativePath)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = """
        model = "existing-model"

        [mcp_servers.keep-me]
        command = "example"

        [mcp_servers."anemll-macos-agent"] # old generated entry
        url = "http://old.invalid/mcp"
        tool_timeout_sec = 1.0

        [features]
        useful = true
        """
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        _ = AgentIntegrationInstaller.install(
            platforms: [.codex],
            skillData: Data("skill".utf8),
            homeDirectory: home,
            installPiAdapter: false
        )

        let merged = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(merged.contains("model = \"existing-model\""))
        XCTAssertTrue(merged.contains("[mcp_servers.keep-me]"))
        XCTAssertTrue(merged.contains("[features]"))
        XCTAssertFalse(merged.contains("old.invalid"))
        XCTAssertEqual(merged.components(separatedBy: "[mcp_servers.anemll-macos-agent]").count - 1, 1)
        XCTAssertTrue(merged.contains("bearer_token_env_var = \"ANEMLL_TOKEN\""))
    }

    func testInvalidExistingJSONIsNotOverwritten() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let configURL = home.appendingPathComponent(AgentPlatform.claude.configRelativePath)
        let invalid = Data("not valid json".utf8)
        try invalid.write(to: configURL)

        let result = AgentIntegrationInstaller.install(
            platforms: [.claude],
            skillData: Data("skill".utf8),
            homeDirectory: home,
            installPiAdapter: false
        )

        XCTAssertEqual(result.first?.status, .failed)
        XCTAssertEqual(try Data(contentsOf: configURL), invalid)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent(AgentPlatform.claude.skillRelativePath).path
            )
        )
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anemll-agent-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
