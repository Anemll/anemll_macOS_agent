import Cocoa
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var viewModel: HostViewModel!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewModel = HostViewModel()

        let contentView = ContentView()
            .environmentObject(viewModel)

        popover = NSPopover()
        // Larger size to accommodate onboarding
        popover.contentSize = NSSize(width: 400, height: 380)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Anemll Agent Host")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Observe server running state to update icon color
        viewModel.$serverRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] isRunning in
                self?.updateStatusIcon(isRunning: isRunning)
            }
            .store(in: &cancellables)

        checkForMultipleInstances()

        // Auto-start server if permissions are granted
        if viewModel.screenCaptureAllowed && viewModel.accessibilityAllowed {
            viewModel.startServer()
        } else {
            // Auto-show popover if permissions are missing (helps user find the app)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showPopover()
            }
        }
    }

    private func checkForMultipleInstances() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.anemll.AnemllAgentHost"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard running.count > 1 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            Task { @MainActor in
                self?.showMultipleInstancesAlert(count: running.count)
            }
        }
    }

    @MainActor
    private func showMultipleInstancesAlert(count: Int) {
        let alert = NSAlert()
        alert.messageText = "Multiple AnemllAgentHost instances detected"
        alert.informativeText = """
        There are \(count) instances running. This can cause port 8765 conflicts or token mismatches.
        Quit extra instances from the menu bar or use Activity Monitor to stop them.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
        viewModel.lastStatus = "Multiple instances detected"
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @MainActor @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Refresh permissions when popover opens
            viewModel.refreshPermissions()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func updateStatusIcon(isRunning: Bool) {
        guard let button = statusItem.button else { return }
        let symbolName = "sparkles"
        guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Anemll Agent Host") else { return }

        if isRunning {
            // Create green-tinted version when server is running
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
            button.image = baseImage.withSymbolConfiguration(config)
        } else {
            // Default appearance when server is stopped
            button.image = baseImage
        }
    }
}

