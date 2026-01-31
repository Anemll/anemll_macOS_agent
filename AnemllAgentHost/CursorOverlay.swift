import AppKit
import SwiftUI

final class CursorOverlay {
    private var window: NSWindow?
    private var timer: Timer?
    private let size: CGFloat = 18

    func start() {
        guard window == nil else { return }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.contentView = NSHostingView(rootView: CursorOverlayView())
        w.makeKeyAndOrderFront(nil)
        window = w

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updatePosition()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
        updatePosition()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
    }

    private func updatePosition() {
        guard let window else { return }
        let loc = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: loc.x - size / 2.0, y: loc.y - size / 2.0))
    }
}

private struct CursorOverlayView: View {
    var body: some View {
        Circle()
            .stroke(Color.red.opacity(0.9), lineWidth: 2)
            .frame(width: 16, height: 16)
            .background(Color.clear)
    }
}
