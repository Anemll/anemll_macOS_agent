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
            button.image = makeStatusBarIcon(isRunning: false)
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

    private func makeStatusBarIcon(isRunning: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            let color: NSColor = isRunning ? .systemGreen : NSColor(white: 0.78, alpha: 1.0)
            color.setFill()
            color.setStroke()

            let pad: CGFloat = 1
            let w = rect.width - pad * 2
            let h = rect.height - pad * 2

            // Antenna
            let antennaX = pad + w / 2
            let antennaTop = pad + h * 0.02
            let antennaBot = pad + h * 0.22
            let antennaPath = NSBezierPath()
            antennaPath.lineWidth = 1.4
            antennaPath.move(to: NSPoint(x: antennaX, y: antennaBot))
            antennaPath.line(to: NSPoint(x: antennaX, y: antennaTop))
            antennaPath.stroke()
            // Antenna ball
            let ballR: CGFloat = 1.5
            NSBezierPath(ovalIn: NSRect(x: antennaX - ballR, y: antennaTop - ballR, width: ballR * 2, height: ballR * 2)).fill()

            // Head (rounded rect)
            let headY = pad + h * 0.22
            let headH = h * 0.50
            let headRect = NSRect(x: pad + w * 0.12, y: headY, width: w * 0.76, height: headH)
            let headPath = NSBezierPath(roundedRect: headRect, xRadius: 3, yRadius: 3)
            headPath.lineWidth = 1.4
            headPath.stroke()

            // Eyes
            let eyeY = headY + headH * 0.35
            let eyeW: CGFloat = 2.8
            let eyeH: CGFloat = 2.8
            let leftEyeX = pad + w * 0.30
            let rightEyeX = pad + w * 0.70 - eyeW
            NSBezierPath(ovalIn: NSRect(x: leftEyeX, y: eyeY, width: eyeW, height: eyeH)).fill()
            NSBezierPath(ovalIn: NSRect(x: rightEyeX, y: eyeY, width: eyeW, height: eyeH)).fill()

            // Mouth
            let mouthY = headY + headH * 0.68
            let mouthPath = NSBezierPath()
            mouthPath.lineWidth = 1.2
            mouthPath.move(to: NSPoint(x: pad + w * 0.35, y: mouthY))
            mouthPath.line(to: NSPoint(x: pad + w * 0.65, y: mouthY))
            mouthPath.stroke()

            // Ears (small rects on sides)
            let earW: CGFloat = 2.0
            let earH: CGFloat = 4.0
            let earY = headY + headH * 0.3
            NSBezierPath(roundedRect: NSRect(x: pad + w * 0.05, y: earY, width: earW, height: earH), xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(roundedRect: NSRect(x: pad + w * 0.95 - earW, y: earY, width: earW, height: earH), xRadius: 0.8, yRadius: 0.8).fill()

            // Body (smaller rounded rect below head)
            let bodyY = headY + headH + h * 0.04
            let bodyH = h * 0.22
            let bodyRect = NSRect(x: pad + w * 0.22, y: bodyY, width: w * 0.56, height: bodyH)
            let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 2, yRadius: 2)
            bodyPath.lineWidth = 1.2
            bodyPath.stroke()

            return true
        }
        image.isTemplate = false
        return image
    }

    private func updateStatusIcon(isRunning: Bool) {
        guard let button = statusItem.button else { return }
        button.image = makeStatusBarIcon(isRunning: isRunning)
    }
}

