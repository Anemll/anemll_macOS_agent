import Foundation
import ApplicationServices
import Cocoa
import Network

@MainActor
final class HostViewModel: ObservableObject {
    private static let bindHost = "127.0.0.1"
    private static let serverPort: UInt16 = 8765

    @Published var serverRunning: Bool = false
    @Published var token: String = BearerToken.generate()
    @Published var lastStatus: String = "Idle"

    @Published var screenCaptureAllowed: Bool = false
    @Published var accessibilityAllowed: Bool = false

    // Onboarding state
    @Published var showOnboarding: Bool = false
    @Published var onboardingStep: Int = 0

    // Skill sync
    @Published var skillNeedsSync: Bool = false
    @Published var bundledSkillVersion: String = ""
    @Published var installedAgentSkillVersions: [AgentPlatform: String] = [:]
    @Published var isInstallingSkills: Bool = false
    @Published var agentInstallResults: [AgentInstallResult] = []

    private var server: LocalHTTPServer?
    private let cursorOverlay = CursorOverlay()

    var serverAddress: String {
        "\(Self.bindHost):\(Self.serverPort)"
    }

    var debugURL: String {
        var components = URLComponents()
        components.scheme = "http"
        components.host = Self.bindHost
        components.port = Int(Self.serverPort)
        components.path = "/debug"
        components.fragment = "token=\(token)"
        return components.url?.absoluteString ?? "http://\(Self.bindHost):\(Self.serverPort)/debug#token=\(token)"
    }

    @Published var showCursorOverlay: Bool = false {
        didSet {
            updateCursorOverlayStatus()
        }
    }

    init() {
#if DEBUG
        // Deterministic credentials are available only to explicit local test launches.
        let argumentToken = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--test-token=") })?
            .dropFirst("--test-token=".count)
        if let testToken = ProcessInfo.processInfo.environment["ANEMLL_TEST_TOKEN"]
            ?? argumentToken.map(String.init), testToken.count >= 16 {
            token = testToken
        }
#endif
        // Check permissions on startup (inline to avoid MainActor isolation issue in init)
        screenCaptureAllowed = CGPreflightScreenCaptureAccess()
        accessibilityAllowed = AXIsProcessTrusted()
        // Check if onboarding needed
        if !screenCaptureAllowed || !accessibilityAllowed {
            showOnboarding = true
            onboardingStep = screenCaptureAllowed ? 1 : 0
        }
        // Check skill sync
        checkSkillSyncInternal()
    }

    /// Internal sync check for init (avoids MainActor re-entrancy)
    private func checkSkillSyncInternal() {
        // Get bundled skill version from app resources
        if let bundledPath = Bundle.main.path(forResource: "SKILL", ofType: "md", inDirectory: "skills") {
            bundledSkillVersion = getSkillVersion(at: bundledPath)
        } else {
            // Try alternate location
            let altPath = Bundle.main.bundlePath + "/Contents/Resources/skills/SKILL.md"
            if FileManager.default.fileExists(atPath: altPath) {
                bundledSkillVersion = getSkillVersion(at: altPath)
            }
        }

        let homeDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        var versions: [AgentPlatform: String] = [:]
        var needsSync = false
        for platform in AgentPlatform.allCases {
            let skillURL = homeDirectory.appendingPathComponent(platform.skillRelativePath)
            let isInstalled = FileManager.default.fileExists(atPath: skillURL.path)
            let version = isInstalled ? getSkillVersion(at: skillURL.path) : "Not installed"
            versions[platform] = version

            let shouldTrack = isInstalled || AgentIntegrationInstaller.isDetected(platform, homeDirectory: homeDirectory)
            if shouldTrack && version != bundledSkillVersion {
                needsSync = true
            }
        }
        installedAgentSkillVersions = versions
        skillNeedsSync = needsSync && !bundledSkillVersion.isEmpty
    }

    private func checkOnboardingNeeded() {
        // Show onboarding if any permission is missing
        if !screenCaptureAllowed || !accessibilityAllowed {
            showOnboarding = true
            onboardingStep = screenCaptureAllowed ? 1 : 0  // Start at first missing permission
        }
    }

    func advanceOnboarding() {
        refreshPermissions()
        if onboardingStep == 0 && screenCaptureAllowed {
            onboardingStep = 1
        } else if onboardingStep == 1 && accessibilityAllowed {
            onboardingStep = 2  // Complete
            showOnboarding = false
            // Auto-start server when permissions are granted
            if !serverRunning {
                startServer()
            }
        }
    }

    func skipOnboarding() {
        showOnboarding = false
    }

    func rotateToken() {
        token = BearerToken.generate()
        server?.setBearerToken(token)
        lastStatus = "Rotated token"
    }

    func startServer() {
        do {
            let s = LocalHTTPServer(bindHost: Self.bindHost, port: Self.serverPort, bearerToken: token)
            s.onLog = { msg in
                print("[LocalHTTPServer] \(msg)")
            }
            s.onState = { [weak self] state in
                Task { @MainActor in
                    self?.handleServerState(state)
                }
            }
            try s.start()
            server = s
            serverRunning = true
            updateCursorOverlayStatus()
            lastStatus = "Starting server..."
        } catch {
            serverRunning = false
            server = nil
            if isPortInUseError(error) {
                lastStatus = portInUseStatus()
                presentPortInUseAlert()
            } else {
                lastStatus = "Server failed: \(error)"
            }
        }
    }

    func stopServer() {
        server?.stop()
        server = nil
        serverRunning = false
        updateCursorOverlayStatus()
        lastStatus = "Server stopped"
    }

    private func updateCursorOverlayStatus() {
        if serverRunning && showCursorOverlay {
            cursorOverlay.start()
            lastStatus = "Cursor overlay enabled"
        } else {
            cursorOverlay.stop()
            if showCursorOverlay && !serverRunning {
                lastStatus = "Cursor overlay paused (server stopped)"
            } else {
                lastStatus = "Cursor overlay disabled"
            }
        }
    }

    func refreshPermissions() {
        // Screen capture
        screenCaptureAllowed = CGPreflightScreenCaptureAccess()

        // Accessibility
        accessibilityAllowed = AXIsProcessTrusted()
    }

    func requestScreenCapture() {
        // Ensure the system permission dialog isn't hidden behind another app's window.
        NSApp.activate(ignoringOtherApps: true)

        // Will prompt the user (macOS may require app restart after granting).
        _ = CGRequestScreenCaptureAccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshPermissions()
            self?.lastStatus = "Screen Recording: respond to the macOS permission dialog"
        }
    }

    func requestAccessibility() {
        // Ensure the system permission dialog isn't hidden behind another app's window.
        NSApp.activate(ignoringOtherApps: true)

        // The exported C symbol is mutable and therefore rejected by Swift 6 concurrency checks;
        // the documented CFDictionary key has this stable raw value.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)

        // If the system prompt didn't appear (sandbox or tccutil reset), open Settings directly
        if !trusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.refreshPermissions()
                if !self.accessibilityAllowed {
                    self.openSystemSettingsAccessibility()
                    self.lastStatus = "Accessibility: enable AnemllAgentHost in System Settings"
                }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.refreshPermissions()
            }
        }
    }

    func resetPermissions() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.anemll.AnemllAgentHost"
        lastStatus = "Resetting permissions..."

        Task.detached { [bundleID] in
            let services = ["ScreenCapture", "Accessibility"]
            var failures: [String] = []
            for service in services {
                do {
                    try Self.runTCCReset(service: service, bundleID: bundleID)
                } catch {
                    failures.append(service)
                }
            }
            let failedServices = failures

            await MainActor.run {
                self.refreshPermissions()
                if failedServices.isEmpty {
                    self.lastStatus = "Reset permissions; quit and relaunch to re-grant"
                } else {
                    self.lastStatus = "Reset failed for: \(failedServices.joined(separator: ", "))"
                }
            }
        }
    }

    private nonisolated static func runTCCReset(service: String, bundleID: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleID]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "tccutil failed"
            throw NSError(domain: "TCCReset", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    // MARK: - App Restart

    func restartApp() {
        lastStatus = "Restarting..."

        // Get the path to the running app
        guard let appPath = Bundle.main.bundlePath as String? else {
            lastStatus = "Cannot find app path"
            return
        }

        // Use /usr/bin/open to relaunch after a short delay
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5 && open \"\(appPath)\""]

        do {
            try task.run()
            // Terminate current instance
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        } catch {
            lastStatus = "Restart failed: \(error.localizedDescription)"
        }
    }

    func resetAndRestart() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.anemll.AnemllAgentHost"
        lastStatus = "Resetting permissions and restarting..."

        Task.detached { [bundleID] in
            let services = ["ScreenCapture", "Accessibility"]
            for service in services {
                try? Self.runTCCReset(service: service, bundleID: bundleID)
            }

            await MainActor.run {
                self.restartApp()
            }
        }
    }

    // MARK: - Skill Sync

    func checkSkillSync() {
        checkSkillSyncInternal()
    }

    private func getSkillVersion(at path: String) -> String {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "unknown"
        }
        // Look for the compatibility marker in the skill body (e.g., "AnemllAgentHost v0.2.1").
        if let range = content.range(of: #"AnemllAgentHost v[\d.]+"#, options: .regularExpression) {
            let match = String(content[range])
            return match.replacingOccurrences(of: "AnemllAgentHost ", with: "")
        }
        // Fallback: use file modification date
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let modDate = attrs[.modificationDate] as? Date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: modDate)
        }
        return "unknown"
    }

    func isAgentDetected(_ platform: AgentPlatform) -> Bool {
        AgentIntegrationInstaller.isDetected(
            platform,
            homeDirectory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        )
    }

    func installSkills(targets: Set<AgentPlatform>) {
        guard !targets.isEmpty, !isInstallingSkills else { return }
        guard let skillData = bundledSkillData() else {
            lastStatus = "Bundled skill not found"
            return
        }

        isInstallingSkills = true
        agentInstallResults = []
        lastStatus = "Installing skills and MCP tools..."
        let homeDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

        Task {
            let results = await Task.detached(priority: .userInitiated) {
                AgentIntegrationInstaller.install(
                    platforms: targets,
                    skillData: skillData,
                    homeDirectory: homeDirectory
                )
            }.value

            agentInstallResults = results
            isInstallingSkills = false
            checkSkillSync()

            let failed = results.filter { $0.status == .failed }.count
            let warnings = results.filter { $0.status == .warning }.count
            if failed > 0 {
                lastStatus = "Installed \(results.count - failed)/\(results.count) targets; \(failed) failed"
            } else if warnings > 0 {
                lastStatus = "Installed \(results.count) targets with \(warnings) warning(s)"
            } else {
                lastStatus = "Skills and MCP tools installed for \(results.count) target(s)"
            }
        }
    }

    private func bundledSkillData() -> Data? {
        if let path = Bundle.main.path(forResource: "SKILL", ofType: "md", inDirectory: "skills") {
            return FileManager.default.contents(atPath: path)
        }
        let alternatePath = Bundle.main.bundlePath + "/Contents/Resources/skills/SKILL.md"
        return FileManager.default.contents(atPath: alternatePath)
    }

    func openSystemSettingsPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    func openSystemSettingsScreenRecording() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openSystemSettingsAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Update CLAUDE.md Token

    func updateClaudeToken() -> Bool {
        let claudeMdPath = NSHomeDirectory() + "/.claude/CLAUDE.md"

        guard FileManager.default.fileExists(atPath: claudeMdPath) else {
            lastStatus = "CLAUDE.md not found"
            return false
        }

        do {
            var content = try String(contentsOfFile: claudeMdPath, encoding: .utf8)

            // Replace the token line using regex
            // Matches: ANEMLL_TOKEN=<any-uuid-format>
            let pattern = #"ANEMLL_TOKEN=[A-F0-9\-]+"#
            let replacement = "ANEMLL_TOKEN=\(token)"

            if let range = content.range(of: pattern, options: .regularExpression) {
                content.replaceSubrange(range, with: replacement)
                try content.write(toFile: claudeMdPath, atomically: true, encoding: .utf8)
                return true
            } else {
                lastStatus = "Token pattern not found in CLAUDE.md"
                return false
            }
        } catch {
            lastStatus = "Failed to update CLAUDE.md: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Port Diagnostics

    private func isPortInUseError(_ error: Error) -> Bool {
        if let nwError = error as? NWError {
            if case .posix(let posix) = nwError {
                return posix == .EADDRINUSE
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EADDRINUSE) {
            return true
        }

        return nsError.localizedDescription.lowercased().contains("address already in use")
    }

    private func presentPortInUseAlert() {
        let alert = NSAlert()
        alert.messageText = "Port \(Self.serverPort) is already in use"
        alert.informativeText = portInUseStatus()
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func portInUseStatus() -> String {
        """
Another app is listening on \(serverAddress).

To find the process:
lsof -nP -iTCP:\(Self.serverPort) -sTCP:LISTEN

If nothing shows, macOS may require sudo:
sudo lsof -nP -iTCP:\(Self.serverPort) -sTCP:LISTEN

Quit that app (or the extra AnemllAgentHost instance) and try again.
"""
    }

    private func handleServerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            serverRunning = true
            lastStatus = "Server started"
        case .failed(let error):
            serverRunning = false
            server = nil
            if isPortInUseError(error) {
                lastStatus = portInUseStatus()
                presentPortInUseAlert()
            } else {
                lastStatus = "Server failed: \(error)"
            }
        case .cancelled:
            serverRunning = false
            server = nil
            lastStatus = "Server stopped"
        default:
            break
        }
    }
}
