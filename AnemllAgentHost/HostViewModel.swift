import Foundation
import ApplicationServices

@MainActor
final class HostViewModel: ObservableObject {
    @Published var serverRunning: Bool = false
    @Published var token: String = UUID().uuidString
    @Published var lastStatus: String = "Idle"

    @Published var screenCaptureAllowed: Bool = false
    @Published var accessibilityAllowed: Bool = false

    private var server: LocalHTTPServer?
    private let cursorOverlay = CursorOverlay()

    @Published var showCursorOverlay: Bool = false {
        didSet {
            if showCursorOverlay {
                cursorOverlay.start()
                lastStatus = "Cursor overlay enabled"
            } else {
                cursorOverlay.stop()
                lastStatus = "Cursor overlay disabled"
            }
        }
    }

    func rotateToken() {
        token = UUID().uuidString
        server?.setBearerToken(token)
        lastStatus = "Rotated token"
    }

    func startServer() {
        do {
            let s = LocalHTTPServer(bindHost: "127.0.0.1", port: 8765, bearerToken: token)
            s.onLog = { [weak self] msg in
                Task { @MainActor in self?.lastStatus = msg }
                print("[LocalHTTPServer] \(msg)")
            }
            try s.start()
            server = s
            serverRunning = true
            lastStatus = "Server started"
        } catch {
            lastStatus = "Server failed: \(error)"
            serverRunning = false
            server = nil
        }
    }

    func stopServer() {
        server?.stop()
        server = nil
        serverRunning = false
        lastStatus = "Server stopped"
    }

    func refreshPermissions() {
        // Screen capture
        screenCaptureAllowed = CGPreflightScreenCaptureAccess()

        // Accessibility
        accessibilityAllowed = AXIsProcessTrusted()
    }

    func requestScreenCapture() {
        // Will prompt the user (macOS may require app restart after granting).
        _ = CGRequestScreenCaptureAccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshPermissions()
            self?.lastStatus = "Requested Screen Recording permission"
        }
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshPermissions()
            self?.lastStatus = "Requested Accessibility permission"
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
}
