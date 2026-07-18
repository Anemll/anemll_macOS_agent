import Foundation

public enum AgentPlatform: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case droid
    case pi
    case claude
    case codex
    case grok

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .droid: "Droid"
        case .pi: "Pi"
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        }
    }

    public var installSummary: String {
        switch self {
        case .droid: "Skill + native MCP configuration"
        case .pi: "Skill + pi-mcp-adapter + MCP configuration"
        case .claude: "Skill + user MCP configuration"
        case .codex: "Shared skill + native MCP configuration"
        case .grok: "Skill + native MCP configuration"
        }
    }

    public var skillRelativePath: String {
        switch self {
        case .droid: ".factory/skills/anemll-macos-agent/SKILL.md"
        case .pi: ".pi/agent/skills/anemll-macos-agent/SKILL.md"
        case .claude: ".claude/skills/anemll-macos-agent/SKILL.md"
        case .codex: ".agents/skills/anemll-macos-agent/SKILL.md"
        case .grok: ".grok/skills/anemll-macos-agent/SKILL.md"
        }
    }

    public var configRelativePath: String {
        switch self {
        case .droid: ".factory/mcp.json"
        case .pi: ".pi/agent/mcp.json"
        case .claude: ".claude.json"
        case .codex: ".codex/config.toml"
        case .grok: ".grok/config.toml"
        }
    }
}

public enum AgentInstallStatus: String, Codable, Sendable {
    case installed
    case warning
    case failed
}

public struct AgentInstallResult: Codable, Identifiable, Sendable {
    public let platform: AgentPlatform
    public let status: AgentInstallStatus
    public let detail: String

    public var id: AgentPlatform { platform }

    public init(platform: AgentPlatform, status: AgentInstallStatus, detail: String) {
        self.platform = platform
        self.status = status
        self.detail = detail
    }
}

public enum AgentIntegrationInstaller {
    private static let serverName = "anemll-macos-agent"
    private static let serverURL = "http://127.0.0.1:8765/mcp"

    public static func install(
        platforms: Set<AgentPlatform>,
        skillData: Data,
        homeDirectory: URL,
        installPiAdapter: Bool = true
    ) -> [AgentInstallResult] {
        AgentPlatform.allCases.compactMap { platform in
            guard platforms.contains(platform) else { return nil }
            return install(
                platform: platform,
                skillData: skillData,
                homeDirectory: homeDirectory,
                installPiAdapter: installPiAdapter
            )
        }
    }

    public static func isDetected(_ platform: AgentPlatform, homeDirectory: URL) -> Bool {
        let fileManager = FileManager.default
        let nativeDirectory: String
        switch platform {
        case .droid: nativeDirectory = ".factory"
        case .pi: nativeDirectory = ".pi"
        case .claude: nativeDirectory = ".claude"
        case .codex: nativeDirectory = ".codex"
        case .grok: nativeDirectory = ".grok"
        }

        if fileManager.fileExists(atPath: homeDirectory.appendingPathComponent(nativeDirectory).path) {
            return true
        }
        return executableURL(for: platform, homeDirectory: homeDirectory) != nil
    }

    private static func install(
        platform: AgentPlatform,
        skillData: Data,
        homeDirectory: URL,
        installPiAdapter: Bool
    ) -> AgentInstallResult {
        do {
            let configURL = homeDirectory.appendingPathComponent(platform.configRelativePath)
            if platform == .droid || platform == .pi || platform == .claude {
                try validateJSONConfiguration(for: platform, at: configURL)
            }

            let skillURL = homeDirectory.appendingPathComponent(platform.skillRelativePath)
            try write(skillData, to: skillURL, permissions: 0o644)

            switch platform {
            case .droid, .pi, .claude:
                try mergeJSONConfiguration(for: platform, at: configURL)
            case .codex, .grok:
                try mergeTOMLConfiguration(for: platform, at: configURL)
            }

            if platform == .pi && installPiAdapter {
                guard let piURL = executableURL(for: .pi, homeDirectory: homeDirectory) else {
                    return AgentInstallResult(
                        platform: platform,
                        status: .warning,
                        detail: "Skill and MCP config installed; install Pi, then run ‘pi install npm:pi-mcp-adapter’."
                    )
                }
                do {
                    try runPiAdapterInstall(executableURL: piURL)
                } catch {
                    return AgentInstallResult(
                        platform: platform,
                        status: .warning,
                        detail: "Skill and MCP config installed; pi-mcp-adapter failed: \(error.localizedDescription)"
                    )
                }
            }

            return AgentInstallResult(
                platform: platform,
                status: .installed,
                detail: "Skill and MCP tools installed."
            )
        } catch {
            return AgentInstallResult(
                platform: platform,
                status: .failed,
                detail: error.localizedDescription
            )
        }
    }

    private static func validateJSONConfiguration(for platform: AgentPlatform, at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw configurationError("Existing \(platform.displayName) config is not a JSON object; no changes were made.")
        }
        if let servers = root["mcpServers"], !(servers is [String: Any]) {
            throw configurationError("Existing mcpServers value in \(platform.displayName) config is invalid; no changes were made.")
        }
    }

    private static func mergeJSONConfiguration(for platform: AgentPlatform, at url: URL) throws {
        let fileManager = FileManager.default
        var root: [String: Any] = [:]

        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw configurationError("Existing \(platform.displayName) config is not a JSON object; no changes were made.")
            }
            root = decoded
        }

        var servers: [String: Any]
        if let existing = root["mcpServers"] {
            guard let existingServers = existing as? [String: Any] else {
                throw configurationError("Existing mcpServers value in \(platform.displayName) config is invalid; no changes were made.")
            }
            servers = existingServers
        } else {
            servers = [:]
        }

        servers[serverName] = jsonServerConfiguration(for: platform)
        root["mcpServers"] = servers

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) + Data("\n".utf8)
        try write(data, to: url, permissions: 0o600)
    }

    private static func jsonServerConfiguration(for platform: AgentPlatform) -> [String: Any] {
        let tokenHeader = ["Authorization": "Bearer ${ANEMLL_TOKEN}"]
        switch platform {
        case .droid:
            return [
                "type": "http",
                "url": serverURL,
                "headers": tokenHeader,
                "oauth": false,
                "timeoutMs": 65_000,
                "disabled": false
            ]
        case .pi:
            return [
                "url": serverURL,
                "headers": tokenHeader,
                "auth": "bearer",
                "lifecycle": "lazy",
                "directTools": [
                    "anemll_windows",
                    "anemll_activate",
                    "anemll_accessibility_tree",
                    "anemll_accessibility_action",
                    "anemll_accessibility_wait",
                    "anemll_batch",
                    "anemll_paste",
                    "anemll_hotkey"
                ]
            ]
        case .claude:
            return [
                "type": "http",
                "url": serverURL,
                "headers": tokenHeader
            ]
        case .codex, .grok:
            return [:]
        }
    }

    private static func mergeTOMLConfiguration(for platform: AgentPlatform, at url: URL) throws {
        let fileManager = FileManager.default
        let existing: String
        if fileManager.fileExists(atPath: url.path) {
            existing = try String(contentsOf: url, encoding: .utf8)
        } else {
            existing = ""
        }

        let tableName = "mcp_servers.\(serverName)"
        var retainedLines: [String] = []
        var skippingTargetTable = false

        for line in existing.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let header = tomlTableName(from: trimmed) {
                skippingTargetTable = header == tableName || header.hasPrefix(tableName + ".")
            }
            if !skippingTargetTable {
                retainedLines.append(line)
            }
        }

        while retainedLines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            retainedLines.removeLast()
        }

        let block: String
        switch platform {
        case .codex:
            block = """
            [\(tableName)]
            url = "\(serverURL)"
            bearer_token_env_var = "ANEMLL_TOKEN"
            startup_timeout_sec = 10.0
            tool_timeout_sec = 65.0
            """
        case .grok:
            block = """
            [\(tableName)]
            url = "\(serverURL)"
            headers = { Authorization = "Bearer ${ANEMLL_TOKEN}" }
            startup_timeout_sec = 10
            tool_timeout_sec = 65
            """
        case .droid, .pi, .claude:
            throw configurationError("Unsupported TOML target: \(platform.displayName)")
        }

        let prefix = retainedLines.isEmpty ? "" : retainedLines.joined(separator: "\n") + "\n\n"
        try write(Data((prefix + block + "\n").utf8), to: url, permissions: 0o600)
    }

    private static func tomlTableName(from line: String) -> String? {
        guard line.hasPrefix("[") else { return nil }
        let openingCount = line.hasPrefix("[[") ? 2 : 1
        let closingToken = openingCount == 2 ? "]]" : "]"
        guard line.count > openingCount else { return nil }
        let start = line.index(line.startIndex, offsetBy: openingCount)
        guard let closingRange = line.range(of: closingToken, range: start..<line.endIndex) else { return nil }
        let suffix = line[closingRange.upperBound...].trimmingCharacters(in: .whitespaces)
        guard suffix.isEmpty || suffix.hasPrefix("#") else { return nil }

        return line[start..<closingRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"\(serverName)\"", with: serverName)
            .replacingOccurrences(of: "'\(serverName)'", with: serverName)
    }

    private static func write(_ data: Data, to url: URL, permissions: Int) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private static func executableURL(for platform: AgentPlatform, homeDirectory: URL) -> URL? {
        let executableName: String
        switch platform {
        case .droid: executableName = "droid"
        case .pi: executableName = "pi"
        case .claude: executableName = "claude"
        case .codex: executableName = "codex"
        case .grok: executableName = "grok"
        }

        let candidates = [
            homeDirectory.appendingPathComponent(".local/bin/\(executableName)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(executableName)"),
            URL(fileURLWithPath: "/usr/local/bin/\(executableName)")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func runPiAdapterInstall(executableURL: URL) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["install", "npm:pi-mcp-adapter"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            throw configurationError("Pi adapter installation timed out after 120 seconds.")
        }
        guard process.terminationStatus == 0 else {
            throw configurationError("Pi exited with status \(process.terminationStatus).")
        }
    }

    private static func configurationError(_ message: String) -> NSError {
        NSError(
            domain: "AnemllAgentHost.AgentIntegration",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
