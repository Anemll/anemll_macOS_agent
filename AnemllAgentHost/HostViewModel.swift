import Foundation
import ApplicationServices
import Cocoa
import Network

@MainActor
final class HostViewModel: ObservableObject {
    private static let bindHost = "127.0.0.1"
    private static let serverPort: UInt16 = 8765

    @Published var serverRunning: Bool = false
    @Published var token: String = UUID().uuidString
    @Published var lastStatus: String = "Idle"

    @Published var screenCaptureAllowed: Bool = false
    @Published var accessibilityAllowed: Bool = false

    // Onboarding state
    @Published var showOnboarding: Bool = false
    @Published var onboardingStep: Int = 0

    // Skill sync
    @Published var skillNeedsSync: Bool = false
    @Published var bundledSkillVersion: String = ""
    @Published var installedSkillVersion: String = ""
    @Published var installedCodexSkillVersion: String = ""

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
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url?.absoluteString ?? "http://\(Self.bindHost):\(Self.serverPort)/debug?token=\(token)"
    }

    @Published var showCursorOverlay: Bool = true {
        didSet {
            updateCursorOverlayStatus()
        }
    }

    init() {
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

        // Get installed skill versions (Claude + Codex)
        let claudePath = NSHomeDirectory() + "/.claude/skills/anemll-macos-agent/SKILL.md"
        if FileManager.default.fileExists(atPath: claudePath) {
            installedSkillVersion = getSkillVersion(at: claudePath)
        } else {
            installedSkillVersion = "Not installed"
        }

        let codexCustomPath = NSHomeDirectory() + "/.codex/skills/custom/anemll-macos-agent/SKILL.md"
        let codexPath = NSHomeDirectory() + "/.codex/skills/anemll-macos-agent/SKILL.md"
        if FileManager.default.fileExists(atPath: codexCustomPath) {
            installedCodexSkillVersion = getSkillVersion(at: codexCustomPath)
        } else if FileManager.default.fileExists(atPath: codexPath) {
            installedCodexSkillVersion = getSkillVersion(at: codexPath)
        } else {
            installedCodexSkillVersion = "Not installed"
        }

        // Check if sync needed (versions differ or not installed)
        let needsClaudeSync = installedSkillVersion != bundledSkillVersion
        let needsCodexSync = installedCodexSkillVersion != bundledSkillVersion
        skillNeedsSync = (needsClaudeSync || needsCodexSync) && !bundledSkillVersion.isEmpty
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
        token = UUID().uuidString
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

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshPermissions()
            self?.lastStatus = "Accessibility: respond to the macOS permission dialog"
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

            await MainActor.run {
                self.refreshPermissions()
                if failures.isEmpty {
                    self.lastStatus = "Reset permissions; quit and relaunch to re-grant"
                } else {
                    self.lastStatus = "Reset failed for: \(failures.joined(separator: ", "))"
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
        // Look for version in the skill file (e.g., "v0.1.8")
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

    func syncSkill() {
        // Copy bundled skill to user's Claude and Codex skills directories
        let claudeDir = NSHomeDirectory() + "/.claude/skills/anemll-macos-agent"
        let claudePath = claudeDir + "/SKILL.md"
        let codexDir = NSHomeDirectory() + "/.codex/skills/custom/anemll-macos-agent"
        let codexPath = codexDir + "/SKILL.md"

        // Find bundled skill
        var sourcePath: String?
        if let path = Bundle.main.path(forResource: "SKILL", ofType: "md", inDirectory: "skills") {
            sourcePath = path
        } else {
            let altPath = Bundle.main.bundlePath + "/Contents/Resources/skills/SKILL.md"
            if FileManager.default.fileExists(atPath: altPath) {
                sourcePath = altPath
            }
        }

        guard let source = sourcePath else {
            lastStatus = "Bundled skill not found"
            return
        }

        do {
            // Create directories if needed
            try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: codexDir, withIntermediateDirectories: true)

            // Remove existing files
            if FileManager.default.fileExists(atPath: claudePath) {
                try FileManager.default.removeItem(atPath: claudePath)
            }
            if FileManager.default.fileExists(atPath: codexPath) {
                try FileManager.default.removeItem(atPath: codexPath)
            }

            // Copy new file
            try FileManager.default.copyItem(atPath: source, toPath: claudePath)
            try FileManager.default.copyItem(atPath: source, toPath: codexPath)

            lastStatus = "Skill synced to Claude + Codex"
            checkSkillSync()  // Refresh status
        } catch {
            lastStatus = "Skill sync failed: \(error.localizedDescription)"
        }
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

    // MARK: - Install Skills (to Claude & Codex directories only)

    func install() {
        var results: [String] = []

        // Install skill to both Claude and Codex skill directories
        // NOTE: Does NOT modify CLAUDE.md to keep user settings safe
        let claudeDir = NSHomeDirectory() + "/.claude/skills/anemll-macos-agent"
        let claudePath = claudeDir + "/SKILL.md"
        let codexDir = NSHomeDirectory() + "/.codex/skills/custom/anemll-macos-agent"
        let codexPath = codexDir + "/SKILL.md"

        // Find bundled skill
        var sourcePath: String?
        if let path = Bundle.main.path(forResource: "SKILL", ofType: "md", inDirectory: "skills") {
            sourcePath = path
        } else {
            let altPath = Bundle.main.bundlePath + "/Contents/Resources/skills/SKILL.md"
            if FileManager.default.fileExists(atPath: altPath) {
                sourcePath = altPath
            }
        }

        if let source = sourcePath {
            do {
                // Create directories if needed
                try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(atPath: codexDir, withIntermediateDirectories: true)

                // Remove existing files and copy new
                if FileManager.default.fileExists(atPath: claudePath) {
                    try FileManager.default.removeItem(atPath: claudePath)
                }
                try FileManager.default.copyItem(atPath: source, toPath: claudePath)
                results.append("Claude")

                if FileManager.default.fileExists(atPath: codexPath) {
                    try FileManager.default.removeItem(atPath: codexPath)
                }
                try FileManager.default.copyItem(atPath: source, toPath: codexPath)
                results.append("Codex")
            } catch {
                lastStatus = "Skill install failed: \(error.localizedDescription)"
            }
        }

        if results.isEmpty {
            lastStatus = "Install failed"
        } else {
            lastStatus = "Skills installed: \(results.joined(separator: " + "))"
            checkSkillSync()  // Refresh status
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
