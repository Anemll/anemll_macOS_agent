import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ScreenAndInput {
    enum Err: Error { case screenCaptureNotAllowed; case captureFailed; case writeFailed; case windowNotFound }
    enum CoordinateSpace: String {
        case screenPoints
        case imagePixels

        static func parse(_ raw: Any?) -> CoordinateSpace {
            guard let s = raw as? String else { return .screenPoints }
            switch s.lowercased() {
            case "image", "image_px", "image-px", "image_pixels", "imagepixels", "screenshot":
                return .imagePixels
            case "screen", "screen_points", "screenpoints":
                return .screenPoints
            default:
                return .screenPoints
            }
        }
    }

    private struct DisplayInfo {
        let id: CGDirectDisplayID
        let bounds: CGRect
        let pixelWidth: Int
        let pixelHeight: Int

        var scale: CGFloat {
            guard bounds.width > 0 else { return 1 }
            return CGFloat(pixelWidth) / bounds.width
        }
    }

    private static var lastCaptureScale: Double?
    private static var lastCaptureBounds: CGRect?

    // Writes /tmp/anemll_last.png and returns info JSON
    static func takeScreenshot(path: String = "/tmp/anemll_last.png", includeCursor: Bool = true) throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else {
            throw Err.screenCaptureNotAllowed
        }

        // Capture main display (use .optionOnScreenOnly for speed)
        let image = CGWindowListCreateImage(.infinite,
                                            .optionOnScreenOnly,
                                            kCGNullWindowID,
                                            [.bestResolution])
        guard let cgImage = image else {
            throw Err.captureFailed
        }

        let display = mainDisplayInfo()
        if let display {
            updateLastCaptureScale(pixelWidth: cgImage.width, pixelHeight: cgImage.height, display: display)
        }

        let finalImage: CGImage
        if includeCursor, let withCursor = drawCursorOverlay(on: cgImage) {
            finalImage = withCursor
        } else {
            finalImage = cgImage
        }

        try writePNG(cgImage: finalImage, to: URL(fileURLWithPath: path))
        var info: [String: Any] = [
            "ok": true,
            "path": path,
            "w": finalImage.width,
            "h": finalImage.height,
            "ts": Int(Date().timeIntervalSince1970)
        ]
        if let display {
            let scale = effectiveScale(display: display)
            info["screen_w"] = Double(display.bounds.width)
            info["screen_h"] = Double(display.bounds.height)
            info["screen_x"] = Double(display.bounds.origin.x)
            info["screen_y"] = Double(display.bounds.origin.y)
            info["screen_scale"] = Double(scale)
            info["screen_pixel_w"] = Int(round(Double(display.bounds.width) * scale))
            info["screen_pixel_h"] = Int(round(Double(display.bounds.height) * scale))
        }
        return info
    }

    static func click(x: Double, y: Double, space: CoordinateSpace = .screenPoints) -> Bool {
        guard let pt = screenPoint(x: x, y: y, space: space) else { return false }

        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)
        else { return false }

        down.post(tap: .cghidEventTap)
        usleep(10_000)
        up.post(tap: .cghidEventTap)
        return true
    }

    static func move(x: Double, y: Double, space: CoordinateSpace = .screenPoints) -> Bool {
        guard let pt = screenPoint(x: x, y: y, space: space) else { return false }
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left) else {
            return false
        }
        move.post(tap: .cghidEventTap)
        return true
    }

    static func mouseLocation() -> CGPoint? {
        return CGEvent(source: nil)?.location
    }

    static func imageLocation(fromScreen point: CGPoint) -> CGPoint? {
        guard let display = mainDisplayInfo() else { return nil }
        let scale = effectiveScale(display: display)
        if scale <= 0 { return nil }

        let xPx = (Double(point.x) - Double(display.bounds.origin.x)) * scale
        let yPx = (Double(display.bounds.height) - (Double(point.y) - Double(display.bounds.origin.y))) * scale
        return CGPoint(x: xPx, y: yPx)
    }

    static func type(text: String) -> Bool {
        // Type by Unicode injection
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let utf16: [UniChar]
            if value <= 0xFFFF {
                utf16 = [UniChar(value)]
            } else {
                // surrogate pair
                let v = value - 0x10000
                let high = UniChar(0xD800 + (v >> 10))
                let low  = UniChar(0xDC00 + (v & 0x3FF))
                utf16 = [high, low]
            }

            guard let evDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let evUp   = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else { return false }

            evDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            evUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

            evDown.post(tap: .cghidEventTap)
            usleep(3_000)
            evUp.post(tap: .cghidEventTap)
            usleep(3_000)
        }
        return true
    }

    private static func writePNG(cgImage: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.png.identifier as CFString,
                                                         1,
                                                         nil)
        else { throw Err.writeFailed }

        CGImageDestinationAddImage(dest, cgImage, nil)
        if !CGImageDestinationFinalize(dest) {
            throw Err.writeFailed
        }
    }

    private static func drawCursorOverlay(on cgImage: CGImage) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo)
        else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let mousePt = mouseLocation(),
              let imgPt = imageLocation(fromScreen: mousePt)
        else { return ctx.makeImage() }

        let x = CGFloat(imgPt.x)
        let y = CGFloat(imgPt.y)
        let yFlip = CGFloat(height) - y

        let radius: CGFloat = 12
        let strokeWidth: CGFloat = 3
        ctx.setStrokeColor(CGColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.9))
        ctx.setLineWidth(strokeWidth)
        ctx.strokeEllipse(in: CGRect(x: x - radius, y: yFlip - radius, width: radius * 2, height: radius * 2))

        // Small center dot for visibility
        ctx.setFillColor(CGColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.9))
        ctx.fillEllipse(in: CGRect(x: x - 2, y: yFlip - 2, width: 4, height: 4))

        return ctx.makeImage()
    }

    private static func updateLastCaptureScale(pixelWidth: Int, pixelHeight: Int, display: DisplayInfo) {
        let w = Double(display.bounds.width)
        let h = Double(display.bounds.height)
        guard w > 0, h > 0 else { return }

        let sx = Double(pixelWidth) / w
        let sy = Double(pixelHeight) / h
        let scale = normalizedScale(sx, sy)
        guard scale > 0.1, scale < 10 else { return }

        lastCaptureScale = scale
        lastCaptureBounds = display.bounds
    }

    private static func effectiveScale(display: DisplayInfo) -> Double {
        if let lastScale = lastCaptureScale,
           let lastBounds = lastCaptureBounds,
           abs(lastBounds.width - display.bounds.width) < 0.5,
           abs(lastBounds.height - display.bounds.height) < 0.5,
           lastScale > 0.1, lastScale < 10 {
            return lastScale
        }

        if let backing = NSScreen.main?.backingScaleFactor, backing > 0 {
            return Double(backing)
        }

        return Double(display.scale)
    }

    private static func normalizedScale(_ sx: Double, _ sy: Double) -> Double {
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else { return 0 }
        if abs(sx - sy) <= 0.05 {
            return (sx + sy) / 2.0
        }
        return 0
    }

    private static func mainDisplayInfo() -> DisplayInfo? {
        let id = CGMainDisplayID()
        let bounds = CGDisplayBounds(id)
        let pixelWidth = Int(CGDisplayPixelsWide(id))
        let pixelHeight = Int(CGDisplayPixelsHigh(id))
        return DisplayInfo(id: id, bounds: bounds, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    private static func screenPoint(x: Double, y: Double, space: CoordinateSpace) -> CGPoint? {
        switch space {
        case .screenPoints:
            return CGPoint(x: x, y: y)
        case .imagePixels:
            guard let display = mainDisplayInfo() else { return nil }
            let scale = effectiveScale(display: display)
            if scale <= 0 { return nil }

            let xPt = x / scale + Double(display.bounds.origin.x)
            let yPt = (Double(display.bounds.height) - (y / scale)) + Double(display.bounds.origin.y)
            return CGPoint(x: xPt, y: yPt)
        }
    }

    // MARK: - Window listing and capture

    /// Captures a specific window by ID, PID, app name, or title
    /// Priority: windowID > pid > app > title (uses first match)
    static func captureWindow(
        windowID: CGWindowID? = nil,
        pid: pid_t? = nil,
        app: String? = nil,
        title: String? = nil,
        path: String = "/tmp/anemll_window.png"
    ) throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else {
            throw Err.screenCaptureNotAllowed
        }

        // Find the target window
        guard let targetWindowID = findWindowID(windowID: windowID, pid: pid, app: app, title: title) else {
            throw Err.windowNotFound
        }

        // Capture the specific window
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            targetWindowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else {
            throw Err.captureFailed
        }

        try writePNG(cgImage: cgImage, to: URL(fileURLWithPath: path))

        // Get window info for response
        let windowInfo = getWindowInfo(windowID: targetWindowID)

        var info: [String: Any] = [
            "ok": true,
            "path": path,
            "w": cgImage.width,
            "h": cgImage.height,
            "window_id": Int(targetWindowID),
            "ts": Int(Date().timeIntervalSince1970)
        ]

        if let app = windowInfo?["app"] {
            info["app"] = app
        }
        if let title = windowInfo?["title"] {
            info["title"] = title
        }
        if let pid = windowInfo?["pid"] {
            info["pid"] = pid
        }
        if let bounds = windowInfo?["bounds"] {
            info["bounds"] = bounds
        }

        return info
    }

    /// Moves the cursor to a position within a specific window
    /// By default moves to the center of the window
    /// offsetX/offsetY are relative to the window's top-left corner (in points)
    /// If offsetX/offsetY are nil, cursor moves to center
    static func moveCursorToWindow(
        windowID: CGWindowID? = nil,
        pid: pid_t? = nil,
        app: String? = nil,
        title: String? = nil,
        offsetX: Double? = nil,
        offsetY: Double? = nil
    ) throws -> [String: Any] {
        // Find the target window
        guard let targetWindowID = findWindowID(windowID: windowID, pid: pid, app: app, title: title) else {
            throw Err.windowNotFound
        }

        // Get window bounds
        guard let windowInfo = getWindowInfo(windowID: targetWindowID),
              let bounds = windowInfo["bounds"] as? [String: Double],
              let winX = bounds["x"],
              let winY = bounds["y"],
              let winW = bounds["w"],
              let winH = bounds["h"]
        else {
            throw Err.windowNotFound
        }

        // Calculate target position
        let targetX: Double
        let targetY: Double

        if let offX = offsetX, let offY = offsetY {
            // Use provided offset from window's top-left
            targetX = winX + offX
            targetY = winY + offY
        } else {
            // Default to center of window
            targetX = winX + winW / 2.0
            targetY = winY + winH / 2.0
        }

        // Move the cursor
        guard let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: targetX, y: targetY), mouseButton: .left) else {
            throw Err.captureFailed
        }
        moveEvent.post(tap: .cghidEventTap)

        var info: [String: Any] = [
            "ok": true,
            "window_id": Int(targetWindowID),
            "cursor_x": targetX,
            "cursor_y": targetY
        ]

        if let app = windowInfo["app"] {
            info["app"] = app
        }
        if let title = windowInfo["title"] {
            info["title"] = title
        }
        if let pid = windowInfo["pid"] {
            info["pid"] = pid
        }
        info["bounds"] = bounds

        return info
    }

    /// Clicks at a position within a specific window
    /// offsetX/offsetY are relative to the window's top-left corner (in points)
    /// If offsetX/offsetY are nil, clicks at center of window
    static func clickInWindow(
        windowID: CGWindowID? = nil,
        pid: pid_t? = nil,
        app: String? = nil,
        title: String? = nil,
        offsetX: Double? = nil,
        offsetY: Double? = nil
    ) throws -> [String: Any] {
        // Find the target window
        guard let targetWindowID = findWindowID(windowID: windowID, pid: pid, app: app, title: title) else {
            throw Err.windowNotFound
        }

        // Get window bounds
        guard let windowInfo = getWindowInfo(windowID: targetWindowID),
              let bounds = windowInfo["bounds"] as? [String: Double],
              let winX = bounds["x"],
              let winY = bounds["y"],
              let winW = bounds["w"],
              let winH = bounds["h"]
        else {
            throw Err.windowNotFound
        }

        // Calculate target position
        let targetX: Double
        let targetY: Double

        if let offX = offsetX, let offY = offsetY {
            // Use provided offset from window's top-left
            targetX = winX + offX
            targetY = winY + offY
        } else {
            // Default to center of window
            targetX = winX + winW / 2.0
            targetY = winY + winH / 2.0
        }

        let pt = CGPoint(x: targetX, y: targetY)

        // Perform click
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)
        else {
            throw Err.captureFailed
        }

        down.post(tap: .cghidEventTap)
        usleep(10_000)
        up.post(tap: .cghidEventTap)

        var info: [String: Any] = [
            "ok": true,
            "window_id": Int(targetWindowID),
            "click_x": targetX,
            "click_y": targetY
        ]

        if let app = windowInfo["app"] {
            info["app"] = app
        }
        if let title = windowInfo["title"] {
            info["title"] = title
        }
        if let pid = windowInfo["pid"] {
            info["pid"] = pid
        }
        info["bounds"] = bounds

        return info
    }

    /// Find a window ID based on various criteria
    private static func findWindowID(
        windowID: CGWindowID?,
        pid: pid_t?,
        app: String?,
        title: String?
    ) -> CGWindowID? {
        // If windowID is provided directly, verify it exists and return it
        if let windowID = windowID {
            let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            let exists = windows.contains { ($0[kCGWindowNumber as String] as? Int) == Int(windowID) }
            return exists ? windowID : nil
        }

        // Otherwise search through windows
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        for window in windows {
            guard let winID = window[kCGWindowNumber as String] as? Int else { continue }

            // Match by PID
            if let targetPID = pid {
                if let winPID = window[kCGWindowOwnerPID as String] as? Int, winPID == Int(targetPID) {
                    // If app or title also specified, they must match too
                    if let targetApp = app {
                        guard let winApp = window[kCGWindowOwnerName as String] as? String,
                              winApp.localizedCaseInsensitiveContains(targetApp) else { continue }
                    }
                    if let targetTitle = title {
                        guard let winTitle = window[kCGWindowName as String] as? String,
                              winTitle.localizedCaseInsensitiveContains(targetTitle) else { continue }
                    }
                    return CGWindowID(winID)
                }
                continue
            }

            // Match by app name
            if let targetApp = app {
                guard let winApp = window[kCGWindowOwnerName as String] as? String,
                      winApp.localizedCaseInsensitiveContains(targetApp) else { continue }
                // If title also specified, it must match too
                if let targetTitle = title {
                    guard let winTitle = window[kCGWindowName as String] as? String,
                          winTitle.localizedCaseInsensitiveContains(targetTitle) else { continue }
                }
                return CGWindowID(winID)
            }

            // Match by title only
            if let targetTitle = title {
                guard let winTitle = window[kCGWindowName as String] as? String,
                      winTitle.localizedCaseInsensitiveContains(targetTitle) else { continue }
                return CGWindowID(winID)
            }
        }

        return nil
    }

    /// Get info for a specific window by ID
    private static func getWindowInfo(windowID: CGWindowID) -> [String: Any]? {
        let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []

        for window in windows {
            guard let winID = window[kCGWindowNumber as String] as? Int, winID == Int(windowID) else { continue }

            var info: [String: Any] = ["id": winID]

            if let ownerName = window[kCGWindowOwnerName as String] as? String {
                info["app"] = ownerName
            }
            if let ownerPID = window[kCGWindowOwnerPID as String] as? Int {
                info["pid"] = ownerPID
            }
            if let windowName = window[kCGWindowName as String] as? String, !windowName.isEmpty {
                info["title"] = windowName
            }
            if let bounds = window[kCGWindowBounds as String] as? [String: Any] {
                if let x = bounds["X"] as? Double,
                   let y = bounds["Y"] as? Double,
                   let w = bounds["Width"] as? Double,
                   let h = bounds["Height"] as? Double {
                    info["bounds"] = ["x": x, "y": y, "w": w, "h": h]
                }
            }

            return info
        }

        return nil
    }

    static func listWindows(onScreenOnly: Bool = true) -> [[String: Any]] {
        let options: CGWindowListOption = onScreenOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionAll]

        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var results: [[String: Any]] = []
        for window in windowList {
            var info: [String: Any] = [:]

            if let windowID = window[kCGWindowNumber as String] as? Int {
                info["id"] = windowID
            }
            if let ownerName = window[kCGWindowOwnerName as String] as? String {
                info["app"] = ownerName
            }
            if let ownerPID = window[kCGWindowOwnerPID as String] as? Int {
                info["pid"] = ownerPID
            }
            if let windowName = window[kCGWindowName as String] as? String, !windowName.isEmpty {
                info["title"] = windowName
            }
            if let layer = window[kCGWindowLayer as String] as? Int {
                info["layer"] = layer
            }
            if let alpha = window[kCGWindowAlpha as String] as? Double {
                info["alpha"] = alpha
            }
            if let bounds = window[kCGWindowBounds as String] as? [String: Any] {
                if let x = bounds["X"] as? Double,
                   let y = bounds["Y"] as? Double,
                   let w = bounds["Width"] as? Double,
                   let h = bounds["Height"] as? Double {
                    info["bounds"] = ["x": x, "y": y, "w": w, "h": h]
                }
            }
            if let isOnScreen = window[kCGWindowIsOnscreen as String] as? Bool {
                info["on_screen"] = isOnScreen
            }

            // Only include windows with bounds (skip system UI elements without size)
            if info["bounds"] != nil {
                results.append(info)
            }
        }

        return results
    }
}
