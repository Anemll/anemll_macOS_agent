import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var viewModel: HostViewModel!

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
}
