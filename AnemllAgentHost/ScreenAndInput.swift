import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

enum ScreenAndInput {
    struct ApplicationActivation: Sendable {
        let ok: Bool
        let pid: Int
        let app: String
        let bundleID: String

        var dictionary: [String: Any] {
            ["ok": ok, "pid": pid, "app": app, "bundle_id": bundleID]
        }
    }

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

    private final class CoordinateMappingState: @unchecked Sendable {
        private let lock = NSLock()
        private var geometry: CaptureGeometry?

        func update(_ value: CaptureGeometry) {
            lock.withLock { geometry = value }
        }

        func snapshot() -> CaptureGeometry? {
            lock.withLock { geometry }
        }
    }

    private actor PasteCoordinator {
        func perform(text: String) async -> Bool {
            let previousText = await MainActor.run { NSPasteboard.general.string(forType: .string) }
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }

            let pasted = ScreenAndInput.hotkey(keys: ["command", "v"])
            if pasted { try? await Task.sleep(for: .milliseconds(150)) }

            await MainActor.run {
                NSPasteboard.general.clearContents()
                if let previousText {
                    NSPasteboard.general.setString(previousText, forType: .string)
                }
            }
            return pasted
        }
    }

    private static let coordinateMappingState = CoordinateMappingState()
    private static let pasteCoordinator = PasteCoordinator()

    // Writes /tmp/anemll_last.png and returns info JSON
    // maxDimension: if > 0, resizes image to keep largest dimension under this limit
    // resizeMode: .crop trims (keeps top-left if no cursor), .scale resizes proportionally
    static func takeScreenshot(
        path: String? = "/tmp/anemll_last.png",
        includeCursor: Bool = true,
        maxDimension: Int = 0,
        resizeMode: ResizeMode = .scale,
        returnBase64: Bool = false
    ) async throws -> [String: Any] {
        let startedAt = CFAbsoluteTimeGetCurrent()
        guard CGPreflightScreenCaptureAccess() else {
            throw Err.screenCaptureNotAllowed
        }

        let cgImage: CGImage
        if #available(macOS 14.0, *) {
            cgImage = try await ScreenCaptureBackend.shared.captureMainDisplay()
        } else {
            let displayBounds = CGDisplayBounds(CGMainDisplayID())
            guard let legacyImage = CGWindowListCreateImage(
                displayBounds,
                .optionOnScreenOnly,
                kCGNullWindowID,
                [.bestResolution]
            ) else {
                throw Err.captureFailed
            }
            cgImage = legacyImage
        }

        let display = mainDisplayInfo()
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

        let capturedAt = CFAbsoluteTimeGetCurrent()
        let encodedImage = try pngData(cgImage: finalImage)
        let encodedAt = CFAbsoluteTimeGetCurrent()
        if let path {
            try writeImageData(encodedImage, to: URL(fileURLWithPath: path))
        }
        var info: [String: Any] = [
            "ok": true,
            "w": finalImage.width,
            "h": finalImage.height,
            "ts": Int(Date().timeIntervalSince1970),
            "capture_ms": Int(((capturedAt - startedAt) * 1_000).rounded()),
            "encode_ms": Int(((encodedAt - capturedAt) * 1_000).rounded()),
            "total_ms": Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000).rounded())
        ]
        if let path {
            info["path"] = path
        }
        if returnBase64 {
            info["image_base64"] = encodedImage.base64EncodedString()
        }
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
            let trimOrigin = CGPoint(
                x: (resizeInfo?["trim_x"] as? Int).map { CGFloat($0) } ?? 0,
                y: (resizeInfo?["trim_y"] as? Int).map { CGFloat($0) } ?? 0
            )
            let outputScale = (resizeInfo?["scale"] as? Double).map { CGFloat($0) } ?? 1
            let geometry = CaptureGeometry(
                windowBounds: display.bounds,
                originalPixelSize: CGSize(width: baseImage.width, height: baseImage.height),
                outputPixelSize: CGSize(width: finalImage.width, height: finalImage.height),
                trimOrigin: trimOrigin,
                outputScale: outputScale
            )
            coordinateMappingState.update(geometry)
            info["screen_w"] = Double(display.bounds.width)
            info["screen_h"] = Double(display.bounds.height)
            info["screen_x"] = Double(display.bounds.origin.x)
            info["screen_y"] = Double(display.bounds.origin.y)
            info["screen_scale"] = Double(scale)
            info["screen_pixel_w"] = Int(round(Double(display.bounds.width) * scale))
            info["screen_pixel_h"] = Int(round(Double(display.bounds.height) * scale))
            info["image_scale_x"] = Double(geometry.sourcePixelsPerPoint.x * outputScale)
            info["image_scale_y"] = Double(geometry.sourcePixelsPerPoint.y * outputScale)
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
        if let geometry = coordinateMappingState.snapshot() {
            let pixelsPerPoint = geometry.sourcePixelsPerPoint
            let source = CGPoint(
                x: (point.x - geometry.windowBounds.origin.x) * pixelsPerPoint.x,
                y: (point.y - geometry.windowBounds.origin.y) * pixelsPerPoint.y
            )
            return CGPoint(
                x: (source.x - geometry.trimOrigin.x) * geometry.outputScale,
                y: (source.y - geometry.trimOrigin.y) * geometry.outputScale
            )
        }

        guard let display = mainDisplayInfo() else { return nil }
        return CGPoint(
            x: (point.x - display.bounds.origin.x) * display.scale,
            y: (point.y - display.bounds.origin.y) * display.scale
        )
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

    /// Paste is substantially faster and more reliable than per-scalar key injection for long text.
    /// The previous plain-text clipboard value is restored after the target receives Command-V.
    static func paste(text: String) async -> Bool {
        await pasteCoordinator.perform(text: text)
    }

    static func hotkey(keys: [String]) -> Bool {
        guard !keys.isEmpty else { return false }
        var flags: CGEventFlags = []
        var keyName: String?

        for raw in keys {
            switch raw.lowercased().replacingOccurrences(of: "-", with: "") {
            case "command", "cmd", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            case "function", "fn": flags.insert(.maskSecondaryFn)
            default:
                guard keyName == nil else { return false }
                keyName = raw
            }
        }

        guard let keyName, let code = keyCode(for: keyName),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        else { return false }

        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(10_000)
        up.post(tap: .cghidEventTap)
        return true
    }

    static func drag(
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        space: CoordinateSpace = .screenPoints,
        durationMs: Int = 350
    ) async -> Bool {
        guard let start = screenPoint(x: fromX, y: fromY, space: space),
              let end = screenPoint(x: toX, y: toY, space: space),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)
        else { return false }

        _ = move(x: fromX, y: fromY, space: space)
        down.post(tap: .cghidEventTap)
        let boundedDuration = min(max(durationMs, 50), 10_000)
        let steps = min(max(boundedDuration / 16, 4), 240)

        var completed = true
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
            guard let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) else {
                completed = false
                break
            }
            event.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(boundedDuration / steps))
        }

        up.post(tap: .cghidEventTap)
        return completed
    }

    @MainActor
    static func activate(app: String) -> ApplicationActivation? {
        guard !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let target = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").localizedCaseInsensitiveContains(app)
            || ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(app)
        }) else { return nil }

        target.unhide()
        let activated = target.activate(options: [.activateAllWindows])
        return ApplicationActivation(
            ok: activated,
            pid: Int(target.processIdentifier),
            app: target.localizedName ?? "",
            bundleID: target.bundleIdentifier ?? ""
        )
    }

    private static func keyCode(for raw: String) -> CGKeyCode? {
        let key = raw.lowercased().replacingOccurrences(of: "_", with: "")
        let codes: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
            "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "enter": 36, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
            ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
            "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
        ]
        return codes[key]
    }

    private static func pngData(cgImage: CGImage) throws -> Data {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        )
        else { throw Err.writeFailed }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw Err.writeFailed }
        return mutableData as Data
    }

    private static func writeImageData(_ data: Data, to url: URL) throws {
        // Use a per-request temporary path so concurrent captures cannot corrupt each other.
        let tmpURL = URL(fileURLWithPath: url.path + ".\(UUID().uuidString).tmp")
        try data.write(to: tmpURL, options: .atomic)

        guard isValidPNG(at: tmpURL) else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw Err.writeFailed
        }

        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: url)
        }
    }

    private static func writePNG(cgImage: CGImage, to url: URL) throws {
        try writeImageData(pngData(cgImage: cgImage), to: url)
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
        try? pngData(cgImage: cgImage).base64EncodedString()
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

        guard let mousePt = mouseLocation(), let display = mainDisplayInfo()
        else { return ctx.makeImage() }

        let x = (mousePt.x - display.bounds.origin.x) * CGFloat(width) / display.bounds.width
        let y = (mousePt.y - display.bounds.origin.y) * CGFloat(height) / display.bounds.height
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

    private static func effectiveScale(display: DisplayInfo) -> Double {
        return Double(display.scale)
    }

    private static func mainDisplayInfo() -> DisplayInfo? {
        let id = CGMainDisplayID()
        let bounds = CGDisplayBounds(id)
        // CGDisplayPixelsWide/High can report the logical mode size on a Retina display.
        // pixelWidth/pixelHeight preserve the physical backing resolution used by ScreenCaptureKit.
        let mode = CGDisplayCopyDisplayMode(id)
        let pixelWidth = mode?.pixelWidth ?? Int(CGDisplayPixelsWide(id))
        let pixelHeight = mode?.pixelHeight ?? Int(CGDisplayPixelsHigh(id))
        return DisplayInfo(id: id, bounds: bounds, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    private static func screenPoint(x: Double, y: Double, space: CoordinateSpace) -> CGPoint? {
        switch space {
        case .screenPoints:
            return CGPoint(x: x, y: y)
        case .imagePixels:
            if let geometry = coordinateMappingState.snapshot() {
                let relative = geometry.windowPoint(fromOutputPixel: CGPoint(x: x, y: y))
                return CGPoint(
                    x: geometry.windowBounds.origin.x + relative.x,
                    y: geometry.windowBounds.origin.y + relative.y
                )
            }
            guard let display = mainDisplayInfo() else { return nil }
            let scale = effectiveScale(display: display)
            if scale <= 0 { return nil }

            let xPt = x / scale + Double(display.bounds.origin.x)
            let yPt = y / scale + Double(display.bounds.origin.y)
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
    ) async throws -> [String: Any] {
        let startedAt = CFAbsoluteTimeGetCurrent()
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

        let cgImage: CGImage
        if #available(macOS 14.0, *) {
            cgImage = try await ScreenCaptureBackend.shared.captureWindow(windowID: targetWindowID)
        } else {
            guard let legacyImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                targetWindowID,
                [.bestResolution, .boundsIgnoreFraming]
            ) else {
                throw Err.captureFailed
            }
            cgImage = legacyImage
        }

        // Apply cursor overlay if requested and cursor is within window bounds
        var processedImage: CGImage
        var cursorPositionInImage: CGPoint? = nil

        if includeCursor, let bounds = windowBounds {
            // Calculate cursor position in image coordinates for trimming
            if let mousePt = mouseLocation() {
                let relativeX = mousePt.x - bounds.origin.x
                let relativeY = mousePt.y - bounds.origin.y

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

        let capturedAt = CFAbsoluteTimeGetCurrent()
        let encodedImage = try pngData(cgImage: finalImage)
        let encodedAt = CFAbsoluteTimeGetCurrent()

        // Write to file if path is provided
        if let path = path {
            try writeImageData(encodedImage, to: URL(fileURLWithPath: path))
        }

        var info: [String: Any] = [
            "ok": true,
            "w": finalImage.width,
            "h": finalImage.height,
            "window_id": Int(targetWindowID),
            "ts": Int(Date().timeIntervalSince1970),
            "capture_ms": Int(((capturedAt - startedAt) * 1_000).rounded()),
            "encode_ms": Int(((encodedAt - capturedAt) * 1_000).rounded())
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
            info["image_base64"] = encodedImage.base64EncodedString()
        }

        // Run OCR if requested
        if runOCR {
            let ocrStartedAt = CFAbsoluteTimeGetCurrent()
            let ocrResults = performOCR(on: finalImage)

            let trimOrigin = CGPoint(
                x: (resizeInfo?["trim_x"] as? Int).map { CGFloat($0) } ?? 0,
                y: (resizeInfo?["trim_y"] as? Int).map { CGFloat($0) } ?? 0
            )
            let outputScale = (resizeInfo?["scale"] as? Double).map { CGFloat($0) } ?? 1
            let geometry = windowBounds.map {
                CaptureGeometry(
                    windowBounds: $0,
                    originalPixelSize: CGSize(width: cgImage.width, height: cgImage.height),
                    outputPixelSize: CGSize(width: finalImage.width, height: finalImage.height),
                    trimOrigin: trimOrigin,
                    outputScale: outputScale
                )
            }

            // Convert OCR results with scale-adjusted coordinates for clicking
            var ocrDicts = ocrResultsToDictArray(ocrResults)
            for i in 0..<ocrDicts.count {
                // Add click_x, click_y that are ready to use with /click_window offset_x, offset_y
                if let x = ocrDicts[i]["x"] as? Int,
                   let y = ocrDicts[i]["y"] as? Int,
                   let w = ocrDicts[i]["w"] as? Int,
                   let h = ocrDicts[i]["h"] as? Int {
                    let center = CGPoint(
                        x: Double(x) + Double(w) / 2.0,
                        y: Double(y) + Double(h) / 2.0
                    )
                    if let geometry {
                        let source = geometry.sourcePixel(fromOutputPixel: center)
                        let windowPoint = geometry.windowPoint(fromOutputPixel: center)
                        ocrDicts[i]["source_x"] = Int(source.x.rounded())
                        ocrDicts[i]["source_y"] = Int(source.y.rounded())
                        ocrDicts[i]["click_x"] = Int(windowPoint.x.rounded())
                        ocrDicts[i]["click_y"] = Int(windowPoint.y.rounded())
                    }
                }
            }

            info["ocr"] = ocrDicts
            info["ocr_count"] = ocrResults.count
            if let pixelsPerPoint = geometry?.sourcePixelsPerPoint {
                info["ocr_scale_x"] = Double(pixelsPerPoint.x)
                info["ocr_scale_y"] = Double(pixelsPerPoint.y)
                info["ocr_scale"] = Double(pixelsPerPoint.x)
            }
            info["ocr_ms"] = Int(((CFAbsoluteTimeGetCurrent() - ocrStartedAt) * 1_000).rounded())
        }

        info["total_ms"] = Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000).rounded())

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
    ) async throws -> [String: Any] {
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

            // Capture frame using the cached ScreenCaptureKit content graph on modern macOS.
            let cgImage: CGImage?
            if let winID = targetWindowID {
                if #available(macOS 14.0, *) {
                    cgImage = try? await ScreenCaptureBackend.shared.captureWindow(windowID: winID)
                } else {
                    cgImage = CGWindowListCreateImage(
                        .null,
                        .optionIncludingWindow,
                        winID,
                        [.bestResolution, .boundsIgnoreFraming]
                    )
                }
            } else {
                if #available(macOS 14.0, *) {
                    cgImage = try? await ScreenCaptureBackend.shared.captureMainDisplay()
                } else {
                    cgImage = CGWindowListCreateImage(
                        CGDisplayBounds(CGMainDisplayID()),
                        .optionOnScreenOnly,
                        kCGNullWindowID,
                        [.bestResolution]
                    )
                }
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
                try await Task.sleep(for: .milliseconds(intervalMs))
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
