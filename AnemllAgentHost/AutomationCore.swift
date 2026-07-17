import Foundation
import CoreGraphics
import Security

enum BearerToken {
    static func generate(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum AutomationLimits {
    static let maximumHeaderBytes = 32 * 1024
    static let maximumRequestBodyBytes = 2 * 1024 * 1024
    static let maximumTextCharacters = 100_000
    static let maximumBurstFrames = 100
    static let minimumBurstIntervalMs = 10
    static let maximumBurstIntervalMs = 60_000
    static let maximumImageDimension = 8_000
    static let maximumAccessibilityElements = 2_000
    static let maximumAccessibilityDepth = 20
    static let maximumBatchActions = 50
    static let maximumWaitMs = 60_000

    static func validatedBurst(count: Int, intervalMs: Int) throws -> (count: Int, intervalMs: Int) {
        guard (1...maximumBurstFrames).contains(count) else {
            throw AutomationValidationError("count must be between 1 and \(maximumBurstFrames)")
        }
        guard (minimumBurstIntervalMs...maximumBurstIntervalMs).contains(intervalMs) else {
            throw AutomationValidationError(
                "interval_ms must be between \(minimumBurstIntervalMs) and \(maximumBurstIntervalMs)"
            )
        }
        return (count, intervalMs)
    }

    static func validatedMaxDimension(_ value: Int) throws -> Int {
        guard (0...maximumImageDimension).contains(value) else {
            throw AutomationValidationError("max_dimension must be between 0 and \(maximumImageDimension)")
        }
        return value
    }

    static func validateText(_ text: String) throws {
        guard text.count <= maximumTextCharacters else {
            throw AutomationValidationError("text exceeds \(maximumTextCharacters) characters")
        }
    }

    static func validatedWaitMs(_ value: Int) throws -> Int {
        guard (0...maximumWaitMs).contains(value) else {
            throw AutomationValidationError("timeout_ms must be between 0 and \(maximumWaitMs)")
        }
        return value
    }
}

struct AutomationValidationError: Error, LocalizedError, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// Maps coordinates from an output image back to its uncropped source and window points.
struct CaptureGeometry: Equatable, Sendable {
    let windowBounds: CGRect
    let originalPixelSize: CGSize
    let outputPixelSize: CGSize
    let trimOrigin: CGPoint
    let outputScale: CGFloat

    init(
        windowBounds: CGRect,
        originalPixelSize: CGSize,
        outputPixelSize: CGSize,
        trimOrigin: CGPoint = .zero,
        outputScale: CGFloat = 1
    ) {
        self.windowBounds = windowBounds
        self.originalPixelSize = originalPixelSize
        self.outputPixelSize = outputPixelSize
        self.trimOrigin = trimOrigin
        self.outputScale = outputScale
    }

    var sourcePixelsPerPoint: CGPoint {
        CGPoint(
            x: windowBounds.width > 0 ? originalPixelSize.width / windowBounds.width : 1,
            y: windowBounds.height > 0 ? originalPixelSize.height / windowBounds.height : 1
        )
    }

    func sourcePixel(fromOutputPixel point: CGPoint) -> CGPoint {
        let safeScale = outputScale > 0 ? outputScale : 1
        return CGPoint(
            x: point.x / safeScale + trimOrigin.x,
            y: point.y / safeScale + trimOrigin.y
        )
    }

    func windowPoint(fromOutputPixel point: CGPoint) -> CGPoint {
        let source = sourcePixel(fromOutputPixel: point)
        let pixelsPerPoint = sourcePixelsPerPoint
        return CGPoint(
            x: pixelsPerPoint.x > 0 ? source.x / pixelsPerPoint.x : source.x,
            y: pixelsPerPoint.y > 0 ? source.y / pixelsPerPoint.y : source.y
        )
    }
}

enum LocalSecurityPolicy {
    static func isAllowedOrigin(_ origin: String) -> Bool {
        guard let components = URLComponents(string: origin),
              let scheme = components.scheme?.lowercased()
        else {
            return false
        }

        guard scheme == "http" || scheme == "https",
              let rawHost = components.host?.lowercased()
        else {
            return false
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            difference |= Int(l ^ r)
        }
        return difference == 0
    }
}
