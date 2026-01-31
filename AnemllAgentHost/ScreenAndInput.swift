import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ScreenAndInput {
    enum Err: Error { case screenCaptureNotAllowed; case captureFailed; case writeFailed }
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
}
