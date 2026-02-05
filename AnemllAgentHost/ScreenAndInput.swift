import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

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
    // maxDimension: if > 0, resizes image to keep largest dimension under this limit
    // resizeMode: .crop trims (keeps top-left if no cursor), .scale resizes proportionally
    static func takeScreenshot(
        path: String = "/tmp/anemll_last.png",
        includeCursor: Bool = true,
        maxDimension: Int = 0,
        resizeMode: ResizeMode = .scale
    ) throws -> [String: Any] {
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

        let baseImage: CGImage
        if includeCursor, let withCursor = drawCursorOverlay(on: cgImage) {
            baseImage = withCursor
        } else {
            baseImage = cgImage
        }

        // Apply resizing if maxDimension is specified and image exceeds it
        let finalImage: CGImage
        var resizeInfo: [String: Any]? = nil

        if maxDimension > 0 && (baseImage.width > maxDimension || baseImage.height > maxDimension) {
            switch resizeMode {
            case .crop:
                let (cropped, info) = cropImageToMaxDimension(
                    baseImage,
                    maxDimension: maxDimension,
                    cursorPosition: nil
                )
                finalImage = cropped ?? baseImage
                resizeInfo = info
                resizeInfo?["mode"] = "crop"
            case .scale:
                let (scaled, info) = scaleImageToMaxDimension(
                    baseImage,
                    maxDimension: maxDimension
                )
                finalImage = scaled ?? baseImage
                resizeInfo = info
                resizeInfo?["mode"] = "scale"
            }
        } else {
            finalImage = baseImage
        }

        try writePNG(cgImage: finalImage, to: URL(fileURLWithPath: path))
        var info: [String: Any] = [
            "ok": true,
            "path": path,
            "w": finalImage.width,
            "h": finalImage.height,
            "ts": Int(Date().timeIntervalSince1970)
        ]
        if let resize = resizeInfo {
            info["resized"] = true
            info["resize_mode"] = resize["mode"]
            info["original_w"] = resize["original_w"]
            info["original_h"] = resize["original_h"]
            if let trimX = resize["trim_x"] { info["trim_x"] = trimX }
            if let trimY = resize["trim_y"] { info["trim_y"] = trimY }
            if let scale = resize["scale"] { info["scale"] = scale }
        }
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

    static func click(x: Double, y: Double, space: CoordinateSpace = .screenPoints, clickCount: Int = 1, button: CGMouseButton = .left) -> Bool {
        guard let pt = screenPoint(x: x, y: y, space: space) else { return false }

        let (downType, upType): (CGEventType, CGEventType) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }

        guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: pt, mouseButton: button),
              let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: pt, mouseButton: button)
        else { return false }

        // Set click count for double/triple clicks
        down.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))

        down.post(tap: .cghidEventTap)
        usleep(10_000)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Double-click at coordinates
    static func doubleClick(x: Double, y: Double, space: CoordinateSpace = .screenPoints) -> Bool {
        guard let pt = screenPoint(x: x, y: y, space: space) else { return false }

        // First click
        guard let down1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left),
              let up1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left),
              let down2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left),
              let up2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)
        else { return false }

        down1.setIntegerValueField(.mouseEventClickState, value: 1)
        up1.setIntegerValueField(.mouseEventClickState, value: 1)
        down2.setIntegerValueField(.mouseEventClickState, value: 2)
        up2.setIntegerValueField(.mouseEventClickState, value: 2)

        down1.post(tap: .cghidEventTap)
        usleep(10_000)
        up1.post(tap: .cghidEventTap)
        usleep(50_000) // Brief pause between clicks
        down2.post(tap: .cghidEventTap)
        usleep(10_000)
        up2.post(tap: .cghidEventTap)
        return true
    }

    /// Right-click at coordinates
    static func rightClick(x: Double, y: Double, space: CoordinateSpace = .screenPoints) -> Bool {
        return click(x: x, y: y, space: space, clickCount: 1, button: .right)
    }

    static func move(x: Double, y: Double, space: CoordinateSpace = .screenPoints) -> Bool {
        guard let pt = screenPoint(x: x, y: y, space: space) else { return false }
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left) else {
            return false
        }
        move.post(tap: .cghidEventTap)
        return true
    }

    // Scroll by dx/dy in pixels. Positive dy scrolls up, negative dy scrolls down.
    static func scroll(dx: Double = 0, dy: Double, isContinuous: Bool = true) -> Bool {
        let wheel1 = Int32(dy.rounded())
        let wheel2 = Int32(dx.rounded())
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: wheel1, wheel2: wheel2, wheel3: 0) else {
            return false
        }
        if isContinuous {
            ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        }
        ev.post(tap: .cghidEventTap)
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
        // Write atomically to avoid readers seeing partial PNGs.
        let tmpURL = URL(fileURLWithPath: url.path + ".tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmpURL as CFURL,
                                                         UTType.png.identifier as CFString,
                                                         1,
                                                         nil)
        else { throw Err.writeFailed }

        CGImageDestinationAddImage(dest, cgImage, nil)
        if !CGImageDestinationFinalize(dest) {
            throw Err.writeFailed
        }

        guard isValidPNG(at: tmpURL) else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw Err.writeFailed
        }

        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
    }

    private static func isValidPNG(at url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }

        let sig = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        if let data = try? fh.read(upToCount: 8), data == sig {
            return true
        }
        return false
    }

    // MARK: - Base64 encoding

    /// Encodes a CGImage to PNG base64 string
    static func imageToBase64(cgImage: CGImage) -> String? {
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            return nil
        }
        return (mutableData as Data).base64EncodedString()
    }

    // MARK: - OCR using Vision framework

    /// OCR result for a detected text element
    struct OCRResult {
        let text: String
        let x: Int
        let y: Int
        let w: Int
        let h: Int
        let confidence: Float
    }

    /// Performs OCR on a CGImage and returns detected text with bounding boxes
    /// Coordinates are in image pixels (top-left origin)
    static func performOCR(on cgImage: CGImage) -> [OCRResult] {
        var results: [OCRResult] = []

        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        let request = VNRecognizeTextRequest { request, error in
            guard error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation] else {
                return
            }

            let imageWidth = CGFloat(cgImage.width)
            let imageHeight = CGFloat(cgImage.height)

            for observation in observations {
                guard let topCandidate = observation.topCandidates(1).first else { continue }

                // Convert normalized coordinates to image pixels
                // Vision uses bottom-left origin with normalized coords (0-1)
                let boundingBox = observation.boundingBox

                let x = Int(boundingBox.origin.x * imageWidth)
                let y = Int((1.0 - boundingBox.origin.y - boundingBox.height) * imageHeight)  // Flip Y
                let w = Int(boundingBox.width * imageWidth)
                let h = Int(boundingBox.height * imageHeight)

                results.append(OCRResult(
                    text: topCandidate.string,
                    x: x, y: y, w: w, h: h,
                    confidence: topCandidate.confidence
                ))
            }
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        do {
            try requestHandler.perform([request])
        } catch {
            // OCR failed, return empty results
        }

        return results
    }

    /// Converts OCR results to dictionary format for JSON response
    static func ocrResultsToDictArray(_ results: [OCRResult]) -> [[String: Any]] {
        return results.map { result in
            [
                "text": result.text,
                "x": result.x,
                "y": result.y,
                "w": result.w,
                "h": result.h,
                "confidence": Double(result.confidence)
            ]
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

    /// Draws cursor overlay for window captures
    /// windowBounds is from CGWindowListCopyWindowInfo (origin top-left in Quartz screen coords)
    /// Returns nil only if cursor position cannot be determined or is far outside window
    private static func drawCursorOverlayForWindow(on cgImage: CGImage, windowBounds: CGRect) -> CGImage? {
        guard let mousePt = mouseLocation() else { return nil }

        // Mouse location from CGEvent is in Quartz coordinates (origin top-left of main display)
        // Window bounds from CGWindowListCopyWindowInfo are also in Quartz coordinates (origin top-left)
        // So we can directly compare them!

        // Calculate cursor position relative to window's top-left corner
        // mousePt.y is already in top-left origin (Quartz global coordinates)
        var relativeX = mousePt.x - windowBounds.origin.x
        var relativeY = mousePt.y - windowBounds.origin.y

        // Check if cursor is outside window bounds
        let padding: CGFloat = 30  // Padding to allow cursor ring to show at edges
        let isOutside = relativeX < -padding || relativeX > windowBounds.width + padding ||
                        relativeY < -padding || relativeY > windowBounds.height + padding

        if isOutside {
            // Cursor is too far outside window, don't draw
            return nil
        }

        // Clamp to window bounds (keep cursor visible even if slightly outside)
        relativeX = max(0, min(relativeX, windowBounds.width))
        relativeY = max(0, min(relativeY, windowBounds.height))

        // Calculate scale between window points and image pixels
        // Window capture images are typically at 2x retina scale
        let scaleX = CGFloat(cgImage.width) / windowBounds.width
        let scaleY = CGFloat(cgImage.height) / windowBounds.height

        // Convert to image pixel coordinates (top-left origin in image)
        let imgX = relativeX * scaleX
        let imgY = relativeY * scaleY

        // Draw the overlay
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

        // CGContext has origin at bottom-left, so flip Y for drawing
        // imgY is from top, so we need: height - imgY
        let yFlip = CGFloat(height) - imgY

        // Draw cursor ring (red circle with better visibility)
        let radius: CGFloat = 14
        let strokeWidth: CGFloat = 4
        ctx.setStrokeColor(CGColor(red: 1.0, green: 0.1, blue: 0.1, alpha: 1.0))
        ctx.setLineWidth(strokeWidth)
        ctx.strokeEllipse(in: CGRect(x: imgX - radius, y: yFlip - radius, width: radius * 2, height: radius * 2))

        // Draw center dot (filled)
        ctx.setFillColor(CGColor(red: 1.0, green: 0.1, blue: 0.1, alpha: 1.0))
        ctx.fillEllipse(in: CGRect(x: imgX - 3, y: yFlip - 3, width: 6, height: 6))

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

    /// Claude API image size limits
    /// - Playwright MCP targets 1.15 megapixels (~1124x1072) - most reliable
    /// - 2000 pixels: limit for many-image requests (>20 images)
    /// - 8000 pixels: hard limit for single image requests
    static let defaultMaxDimension: Int = 1120  // Playwright MCP target (~1.15MP)
    static let safeMaxDimension: Int = 2000     // Safe for many-image requests
    static let hardMaxDimension: Int = 8000     // Hard limit from Claude API

    /// Resize mode for large images
    enum ResizeMode: String {
        case crop   // Default: crop to size, cursor-aware, preserves pixel accuracy
        case scale  // Scale down proportionally (loses pixel accuracy for clicks)
    }

    /// Captures a specific window by ID, PID, app name, or title
    /// Priority: windowID > pid > app > title (uses first match)
    /// maxDimension: if > 0, resizes image to keep largest dimension under this limit
    /// resizeMode: .crop (default) preserves pixel accuracy; .scale resizes proportionally
    /// returnBase64: if true, includes base64-encoded PNG in response (skips file write if path is nil)
    /// performOCR: if true, runs text detection and includes results in response
    static func captureWindow(
        windowID: CGWindowID? = nil,
        pid: pid_t? = nil,
        app: String? = nil,
        title: String? = nil,
        path: String? = "/tmp/anemll_window.png",
        includeCursor: Bool = true,
        maxDimension: Int = 0,
        resizeMode: ResizeMode = .crop,
        returnBase64: Bool = false,
        runOCR: Bool = false
    ) throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else {
            throw Err.screenCaptureNotAllowed
        }

        // Find the target window
        guard let targetWindowID = findWindowID(windowID: windowID, pid: pid, app: app, title: title) else {
            throw Err.windowNotFound
        }

        // Get window bounds for cursor overlay calculation
        let windowInfo = getWindowInfo(windowID: targetWindowID)
        let windowBounds: CGRect?
        if let bounds = windowInfo?["bounds"] as? [String: Double],
           let x = bounds["x"], let y = bounds["y"],
           let w = bounds["w"], let h = bounds["h"] {
            windowBounds = CGRect(x: x, y: y, width: w, height: h)
        } else {
            windowBounds = nil
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

        // Apply cursor overlay if requested and cursor is within window bounds
        var processedImage: CGImage
        var cursorPositionInImage: CGPoint? = nil

        if includeCursor, let bounds = windowBounds {
            // Calculate cursor position in image coordinates for trimming
            if let mousePt = mouseLocation(), let mainScreen = NSScreen.main {
                let screenHeight = mainScreen.frame.height
                let mouseYTopLeft = screenHeight - mousePt.y
                let relativeX = mousePt.x - bounds.origin.x
                let relativeY = mouseYTopLeft - bounds.origin.y

                let scaleX = CGFloat(cgImage.width) / bounds.width
                let scaleY = CGFloat(cgImage.height) / bounds.height

                let imgX = relativeX * scaleX
                let imgY = relativeY * scaleY

                // Check if cursor is within window
                if imgX >= 0 && imgX < CGFloat(cgImage.width) &&
                   imgY >= 0 && imgY < CGFloat(cgImage.height) {
                    cursorPositionInImage = CGPoint(x: imgX, y: imgY)
                }
            }

            if let withCursor = drawCursorOverlayForWindow(on: cgImage, windowBounds: bounds) {
                processedImage = withCursor
            } else {
                processedImage = cgImage
            }
        } else {
            processedImage = cgImage
        }

        // Apply resizing if maxDimension is specified and image exceeds it
        let finalImage: CGImage
        var resizeInfo: [String: Any]? = nil

        if maxDimension > 0 && (processedImage.width > maxDimension || processedImage.height > maxDimension) {
            switch resizeMode {
            case .crop:
                let (cropped, info) = cropImageToMaxDimension(
                    processedImage,
                    maxDimension: maxDimension,
                    cursorPosition: cursorPositionInImage
                )
                finalImage = cropped ?? processedImage
                resizeInfo = info
                resizeInfo?["mode"] = "crop"

            case .scale:
                let (scaled, info) = scaleImageToMaxDimension(
                    processedImage,
                    maxDimension: maxDimension
                )
                finalImage = scaled ?? processedImage
                resizeInfo = info
                resizeInfo?["mode"] = "scale"
            }
        } else {
            finalImage = processedImage
        }

        // Write to file if path is provided
        if let path = path {
            try writePNG(cgImage: finalImage, to: URL(fileURLWithPath: path))
        }

        var info: [String: Any] = [
            "ok": true,
            "w": finalImage.width,
            "h": finalImage.height,
            "window_id": Int(targetWindowID),
            "ts": Int(Date().timeIntervalSince1970)
        ]

        if let path = path {
            info["path"] = path
        }

        // Add resize info if image was resized
        if let resize = resizeInfo {
            info["resized"] = true
            info["resize_mode"] = resize["mode"]
            info["original_w"] = resize["original_w"]
            info["original_h"] = resize["original_h"]
            if let trimX = resize["trim_x"] { info["trim_x"] = trimX }
            if let trimY = resize["trim_y"] { info["trim_y"] = trimY }
            if let scale = resize["scale"] { info["scale"] = scale }
        }

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

        // Add base64 image if requested
        if returnBase64 {
            if let base64 = imageToBase64(cgImage: finalImage) {
                info["image_base64"] = base64
            }
        }

        // Run OCR if requested
        if runOCR {
            let ocrResults = performOCR(on: finalImage)

            // Calculate scale factor for converting OCR pixel coords to window point coords
            // OCR returns image pixels, but /click_window expects window points
            var ocrScale: Double = 1.0
            if let bounds = windowBounds {
                // Scale is image pixels / window points
                ocrScale = Double(finalImage.width) / Double(bounds.width)
            }

            // Convert OCR results with scale-adjusted coordinates for clicking
            var ocrDicts = ocrResultsToDictArray(ocrResults)
            for i in 0..<ocrDicts.count {
                // Add click_x, click_y that are ready to use with /click_window offset_x, offset_y
                if let x = ocrDicts[i]["x"] as? Int,
                   let y = ocrDicts[i]["y"] as? Int,
                   let w = ocrDicts[i]["w"] as? Int,
                   let h = ocrDicts[i]["h"] as? Int {
                    // Center of the text bounding box, converted to window points
                    let centerX = Double(x) + Double(w) / 2.0
                    let centerY = Double(y) + Double(h) / 2.0
                    ocrDicts[i]["click_x"] = Int(centerX / ocrScale)
                    ocrDicts[i]["click_y"] = Int(centerY / ocrScale)
                }
            }

            info["ocr"] = ocrDicts
            info["ocr_count"] = ocrResults.count
            info["ocr_scale"] = ocrScale
        }

        return info
    }

    /// Crops an image to fit within maxDimension, preserving the region containing the cursor
    /// Returns the cropped image and info about the crop operation
    private static func cropImageToMaxDimension(
        _ image: CGImage,
        maxDimension: Int,
        cursorPosition: CGPoint?
    ) -> (CGImage?, [String: Any]) {
        let width = image.width
        let height = image.height
        let maxDim = CGFloat(maxDimension)

        var cropRect = CGRect(x: 0, y: 0, width: width, height: height)
        var info: [String: Any] = [
            "original_w": width,
            "original_h": height
        ]

        // Trim width if needed
        if CGFloat(width) > maxDim {
            let excess = CGFloat(width) - maxDim

            if let cursor = cursorPosition {
                // Cursor-aware trimming for width
                let cursorX = cursor.x

                if cursorX < maxDim / 2 {
                    // Cursor in left half - keep left, trim from right
                    cropRect.origin.x = 0
                } else if cursorX > CGFloat(width) - maxDim / 2 {
                    // Cursor in right portion - keep right, trim from left
                    cropRect.origin.x = excess
                } else {
                    // Cursor in middle - center the crop around cursor
                    cropRect.origin.x = cursorX - maxDim / 2
                }
            } else {
                // No cursor - trim from right (keep top-left)
                cropRect.origin.x = 0
            }
            cropRect.size.width = maxDim
        }

        // Trim height if needed
        if CGFloat(height) > maxDim {
            let excess = CGFloat(height) - maxDim

            if let cursor = cursorPosition {
                // Cursor-aware trimming for height
                let cursorY = cursor.y

                if cursorY < maxDim / 2 {
                    // Cursor in top half - keep top, trim from bottom
                    cropRect.origin.y = 0
                } else if cursorY > CGFloat(height) - maxDim / 2 {
                    // Cursor in bottom portion - keep bottom, trim from top
                    cropRect.origin.y = excess
                } else {
                    // Cursor in middle - center the crop around cursor
                    cropRect.origin.y = cursorY - maxDim / 2
                }
            } else {
                // No cursor - trim from bottom (keep top)
                cropRect.origin.y = 0
            }
            cropRect.size.height = maxDim
        }

        info["trim_x"] = Int(cropRect.origin.x)
        info["trim_y"] = Int(cropRect.origin.y)

        // CGImage.cropping uses bottom-left origin, but our coordinates are top-left
        // Need to flip Y for the crop rect
        let flippedY = CGFloat(height) - cropRect.origin.y - cropRect.size.height
        let cgCropRect = CGRect(
            x: cropRect.origin.x,
            y: flippedY,
            width: cropRect.size.width,
            height: cropRect.size.height
        )

        let cropped = image.cropping(to: cgCropRect)
        return (cropped, info)
    }

    /// Scales an image proportionally to fit within maxDimension
    /// Returns the scaled image and info about the scale operation
    /// WARNING: Scaling loses pixel accuracy - click coordinates must be multiplied by scale factor
    private static func scaleImageToMaxDimension(
        _ image: CGImage,
        maxDimension: Int
    ) -> (CGImage?, [String: Any]) {
        let width = image.width
        let height = image.height
        let maxDim = CGFloat(maxDimension)

        var info: [String: Any] = [
            "original_w": width,
            "original_h": height
        ]

        // Calculate scale factor to fit within maxDimension
        let scale = min(maxDim / CGFloat(width), maxDim / CGFloat(height))
        let newWidth = Int(CGFloat(width) * scale)
        let newHeight = Int(CGFloat(height) * scale)

        info["scale"] = Double(scale)

        // Create scaled image
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil,
                                  width: newWidth,
                                  height: newHeight,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo)
        else { return (nil, info) }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        return (ctx.makeImage(), info)
    }

    // MARK: - Burst capture

    /// Captures multiple frames rapidly for animation/video analysis
    /// - count: number of frames to capture (default 10)
    /// - intervalMs: milliseconds between captures (default 100 = 10 fps)
    /// - Returns array of capture info dictionaries, images saved as burst_0.png, burst_1.png, etc.
    static func burstCapture(
        windowID: CGWindowID? = nil,
        pid: pid_t? = nil,
        app: String? = nil,
        title: String? = nil,
        count: Int = 10,
        intervalMs: Int = 100,
        maxDimension: Int = 0,
        resizeMode: ResizeMode = .crop,
        basePath: String = "/tmp/anemll_burst"
    ) throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else {
            throw Err.screenCaptureNotAllowed
        }

        let isWindowCapture = windowID != nil || pid != nil || app != nil || title != nil
        var targetWindowID: CGWindowID? = nil

        if isWindowCapture {
            guard let winID = findWindowID(windowID: windowID, pid: pid, app: app, title: title) else {
                throw Err.windowNotFound
            }
            targetWindowID = winID
        }

        var frames: [[String: Any]] = []
        let startTime = Date()

        for i in 0..<count {
            let framePath = "\(basePath)_\(i).png"

            // Capture frame
            let cgImage: CGImage?
            if let winID = targetWindowID {
                cgImage = CGWindowListCreateImage(
                    .null,
                    .optionIncludingWindow,
                    winID,
                    [.bestResolution, .boundsIgnoreFraming]
                )
            } else {
                cgImage = CGWindowListCreateImage(
                    .infinite,
                    .optionOnScreenOnly,
                    kCGNullWindowID,
                    [.bestResolution]
                )
            }

            guard let image = cgImage else { continue }

            // Apply resizing if needed
            var finalImage = image
            var resizeInfo: [String: Any]? = nil

            if maxDimension > 0 && (image.width > maxDimension || image.height > maxDimension) {
                switch resizeMode {
                case .crop:
                    let (cropped, info) = cropImageToMaxDimension(image, maxDimension: maxDimension, cursorPosition: nil)
                    if let cropped = cropped { finalImage = cropped }
                    resizeInfo = info
                case .scale:
                    let (scaled, info) = scaleImageToMaxDimension(image, maxDimension: maxDimension)
                    if let scaled = scaled { finalImage = scaled }
                    resizeInfo = info
                }
            }

            // Write frame
            do {
                try writePNG(cgImage: finalImage, to: URL(fileURLWithPath: framePath))
            } catch {
                continue
            }

            var frameInfo: [String: Any] = [
                "frame": i,
                "path": framePath,
                "w": finalImage.width,
                "h": finalImage.height,
                "ts": Int(Date().timeIntervalSince1970 * 1000)
            ]

            if let resize = resizeInfo {
                frameInfo["original_w"] = resize["original_w"]
                frameInfo["original_h"] = resize["original_h"]
            }

            frames.append(frameInfo)

            // Wait for next frame (except after last frame)
            if i < count - 1 {
                usleep(UInt32(intervalMs * 1000))
            }
        }

        let duration = Date().timeIntervalSince(startTime)

        return [
            "ok": true,
            "count": frames.count,
            "requested": count,
            "interval_ms": intervalMs,
            "duration_ms": Int(duration * 1000),
            "fps": frames.count > 1 ? Double(frames.count - 1) / duration : 0,
            "frames": frames
        ]
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
