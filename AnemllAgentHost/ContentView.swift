import SwiftUI
import CoreGraphics
import ApplicationServices

struct ContentView: View {
    @EnvironmentObject var vm: HostViewModel
    @State private var showingSkillInstaller = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Show onboarding if needed
            if vm.showOnboarding {
                OnboardingView()
            } else {
                mainContentView
            }
        }
        .padding(12)
        .onAppear { vm.refreshPermissions() }
        .sheet(isPresented: $showingSkillInstaller) {
            SkillInstallerView()
                .environmentObject(vm)
        }
    }

    private var mainContentView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Text("Anemll Agent Host")
                    .font(.headline)
                Text("v\(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(vm.serverRunning ? .green : .red)
                    .frame(width: 10, height: 10)
                Text(vm.serverRunning ? "Running" : "Stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Permissions section
            permissionsSection

            Divider()

            // Server section
            serverSection

            // Skill sync warning
            if vm.skillNeedsSync {
                skillSyncSection
            }

            Spacer()

            // Footer
            footerSection
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: vm.screenCaptureAllowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(vm.screenCaptureAllowed ? .green : .red)
                Text("Screen Recording")
                Spacer()
                if !vm.screenCaptureAllowed {
                    Button("Enable") {
                        vm.openSystemSettingsScreenRecording()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            HStack {
                Image(systemName: vm.accessibilityAllowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(vm.accessibilityAllowed ? .green : .red)
                Text("Accessibility")
                Spacer()
                if !vm.accessibilityAllowed {
                    Button("Enable") {
                        vm.openSystemSettingsAccessibility()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            HStack(spacing: 8) {
                Button("Refresh") {
                    vm.refreshPermissions()
                }
                .font(.caption)

                Toggle("Cursor Overlay", isOn: $vm.showCursorOverlay)
                    .toggleStyle(.switch)
                    .font(.caption)

                Spacer()

                Menu {
                    Button("Reset Permissions") {
                        vm.resetPermissions()
                    }
                    Button("Reset & Restart") {
                        vm.resetAndRestart()
                    }
                    Divider()
                    Button("Restart App") {
                        vm.restartApp()
                    }
                    Button("Open Privacy Settings") {
                        vm.openSystemSettingsPrivacy()
                    }
                } label: {
                    Image(systemName: "gear")
                }
                .menuStyle(.borderlessButton)
            }
        }
        .font(.subheadline)
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Server")
                    .font(.subheadline)
                    .bold()
                Spacer()
                Text(vm.serverAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(vm.serverRunning ? "Stop" : "Start") {
                    vm.serverRunning ? vm.stopServer() : vm.startServer()
                }
                Button("Rotate Token") {
                    vm.rotateToken()
                }
                Button("Install Skills") {
                    showingSkillInstaller = true
                }
                .help("Choose agents and install their skill and MCP tools")
                Spacer()
            }

            HStack {
                Text("Token:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(vm.token, forType: .string)
                    vm.lastStatus = "Token copied"
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy token")
            }

            Text(vm.token)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                .cornerRadius(6)

            HStack {
                Spacer()
                Button("Copy Debug URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(vm.debugURL, forType: .string)
                    vm.lastStatus = "Debug URL copied"
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .help("Copy /debug URL with token")
            }
        }
    }

    private var skillSyncSection: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Skill update available")
                .font(.caption)
            Spacer()
            Button("Sync") {
                showingSkillInstaller = true
            }
            .font(.caption)
        }
        .padding(6)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(6)
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                Button("Restart") { vm.restartApp() }
                Spacer()
            }
            Text(vm.lastStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Multi-agent skill installer

struct SkillInstallerView: View {
    @EnvironmentObject private var vm: HostViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPlatforms: Set<AgentPlatform> = []
    @State private var initializedSelection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Install Agent Skills")
                        .font(.title2.bold())
                    Text("Choose each client that should receive the ANEMLL skill and MCP tools.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack {
                Button("Select All") {
                    selectedPlatforms = Set(AgentPlatform.allCases)
                }
                .buttonStyle(.link)
                Button("Clear") {
                    selectedPlatforms.removeAll()
                }
                .buttonStyle(.link)
                Spacer()
                Text("\(selectedPlatforms.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(AgentPlatform.allCases) { platform in
                    Toggle(isOn: selectionBinding(for: platform)) {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(platform.displayName)
                                    .font(.body.weight(.medium))
                                Text(platform.installSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(vm.isAgentDetected(platform) ? "Detected" : "Files will be prepared")
                                .font(.caption2)
                                .foregroundStyle(vm.isAgentDetected(platform) ? .green : .secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .disabled(vm.isInstallingSkills)

                    if platform != AgentPlatform.allCases.last {
                        Divider()
                            .padding(.leading, 34)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2))
            }

            if vm.isInstallingSkills {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing skills and MCP tools…")
                        .font(.callout)
                }
            } else if !vm.agentInstallResults.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(vm.agentInstallResults) { result in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: resultIcon(result.status))
                                .foregroundStyle(resultColor(result.status))
                            Text("\(result.platform.displayName): \(result.detail)")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Text("Existing settings are preserved. MCP configs reference ANEMLL_TOKEN; the token is never written to disk.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(vm.isInstallingSkills)
                Spacer()
                Button("Install Selected") {
                    vm.installSkills(targets: selectedPlatforms)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedPlatforms.isEmpty || vm.isInstallingSkills)
            }
        }
        .padding(20)
        .frame(width: 540, height: 570)
        .interactiveDismissDisabled(vm.isInstallingSkills)
        .onAppear {
            guard !initializedSelection else { return }
            let detected = AgentPlatform.allCases.filter(vm.isAgentDetected)
            selectedPlatforms = detected.isEmpty ? Set(AgentPlatform.allCases) : Set(detected)
            initializedSelection = true
        }
    }

    private func selectionBinding(for platform: AgentPlatform) -> Binding<Bool> {
        Binding(
            get: { selectedPlatforms.contains(platform) },
            set: { isSelected in
                if isSelected {
                    selectedPlatforms.insert(platform)
                } else {
                    selectedPlatforms.remove(platform)
                }
            }
        )
    }

    private func resultIcon(_ status: AgentInstallStatus) -> String {
        switch status {
        case .installed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private func resultColor(_ status: AgentInstallStatus) -> Color {
        switch status {
        case .installed: .green
        case .warning: .orange
        case .failed: .red
        }
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {
    @EnvironmentObject var vm: HostViewModel

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Welcome to AnemllAgentHost")
                    .font(.headline)
                Spacer()
            }

            Text("This app needs permissions to capture screens and control the mouse/keyboard for UI automation.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            // Step 1: Screen Recording
            OnboardingStepView(
                stepNumber: 1,
                title: "Screen Recording",
                description: "Required for taking screenshots",
                isComplete: vm.screenCaptureAllowed,
                isCurrent: vm.onboardingStep == 0
            ) {
                // Trigger the macOS prompt. Don't auto-open System Settings here: doing so can
                // steal focus and hide the permission dialog behind Settings.
                vm.requestScreenCapture()
            }

            // Step 2: Accessibility
            OnboardingStepView(
                stepNumber: 2,
                title: "Accessibility",
                description: "Required for mouse clicks and typing",
                isComplete: vm.accessibilityAllowed,
                isCurrent: vm.onboardingStep == 1
            ) {
                // Trigger the macOS prompt. Don't auto-open System Settings here for the same
                // reason as Screen Recording (it can hide the dialog behind Settings).
                vm.requestAccessibility()
            }

            Spacer()

            // Bottom buttons
            HStack {
                Button("Skip") {
                    vm.skipOnboarding()
                }
                .foregroundStyle(.secondary)

                Spacer()

                Button("Check Permissions") {
                    vm.advanceOnboarding()
                }

                if vm.screenCaptureAllowed && vm.accessibilityAllowed {
                    Button("Done") {
                        vm.showOnboarding = false
                        if !vm.serverRunning {
                            vm.startServer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            // Show help for stale permissions (when user has likely already enabled but it's not detected)
            StalePermissionHelpView()

            Text("Tip: After enabling, you may need to restart the app")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct OnboardingStepView: View {
    let stepNumber: Int
    let title: String
    let description: String
    let isComplete: Bool
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            ZStack {
                Circle()
                    .fill(isComplete ? Color.green : (isCurrent ? Color.blue : Color.gray.opacity(0.3)))
                    .frame(width: 28, height: 28)

                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                } else {
                    Text("\(stepNumber)")
                        .font(.caption.bold())
                        .foregroundStyle(isCurrent ? .white : .secondary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(isCurrent ? .semibold : .regular)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !isComplete && isCurrent {
                Button("Enable") {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(8)
        .background(isCurrent ? Color.blue.opacity(0.05) : Color.clear)
        .cornerRadius(8)
    }
}

// MARK: - Stale Permission Help View

struct StalePermissionHelpView: View {
    @EnvironmentObject var vm: HostViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Permission appears enabled but not working?")
                    .font(.caption)
                    .fontWeight(.semibold)
            }

            Text("After reinstalling or rebuilding, macOS caches old permissions. Use 'Reset & Restart' - the app will reappear in System Settings after restart.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button("Reset & Restart") {
                    vm.resetAndRestart()
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)

                Button("Open Settings") {
                    // Just open the Privacy pane. Requesting permissions here can trigger system
                    // dialogs that then get hidden behind System Settings.
                    vm.openSystemSettingsPrivacy()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }
}
