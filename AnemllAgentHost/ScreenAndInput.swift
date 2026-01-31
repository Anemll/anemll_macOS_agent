import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ScreenAndInput {
    enum Err: Error { case screenCaptureNotAllowed; case captureFailed; case writeFailed }

    // Writes /tmp/anemll_last.png and returns info JSON
    static func takeScreenshot(path: String = "/tmp/anemll_last.png") throws -> [String: Any] {
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

        try writePNG(cgImage: cgImage, to: URL(fileURLWithPath: path))
        return [
            "ok": true,
            "path": path,
            "w": cgImage.width,
            "h": cgImage.height,
            "ts": Int(Date().timeIntervalSince1970)
        ]
    }

    static func click(x: Double, y: Double) -> Bool {
        let pt = CGPoint(x: x, y: y)

        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)
        else { return false }

        down.post(tap: .cghidEventTap)
        usleep(10_000)
        up.post(tap: .cghidEventTap)
        return true
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
}
