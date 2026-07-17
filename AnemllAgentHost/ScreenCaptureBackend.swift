import Foundation
import CoreGraphics
import ScreenCaptureKit

@available(macOS 14.0, *)
actor ScreenCaptureBackend {
    static let shared = ScreenCaptureBackend()

    private var cachedContent: SCShareableContent?
    private var cacheDate = Date.distantPast
    private let cacheLifetime: TimeInterval = 0.75

    func captureMainDisplay() async throws -> CGImage {
        var content = try await shareableContent()
        let display: SCDisplay
        if let cachedDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) {
            display = cachedDisplay
        } else {
            content = try await shareableContent(forceRefresh: true)
            guard let refreshed = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                throw ScreenAndInput.Err.captureFailed
            }
            display = refreshed
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = configuration(for: filter)
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    func captureWindow(windowID: CGWindowID) async throws -> CGImage {
        var content = try await shareableContent()
        let window: SCWindow
        if let cachedWindow = content.windows.first(where: { $0.windowID == windowID }) {
            window = cachedWindow
        } else {
            content = try await shareableContent(forceRefresh: true)
            guard let refreshed = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ScreenAndInput.Err.windowNotFound
            }
            window = refreshed
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = configuration(for: filter)
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    func invalidateContentCache() {
        cachedContent = nil
        cacheDate = .distantPast
    }

    private func shareableContent(forceRefresh: Bool = false) async throws -> SCShareableContent {
        if !forceRefresh,
           let cachedContent,
           Date().timeIntervalSince(cacheDate) < cacheLifetime {
            return cachedContent
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        cachedContent = content
        cacheDate = Date()
        return content
    }

    private func configuration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(max(filter.pointPixelScale, 1))
        configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.scalesToFit = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }
}
