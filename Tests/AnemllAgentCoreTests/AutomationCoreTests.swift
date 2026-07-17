import XCTest
@testable import AnemllAgentCore

final class AutomationCoreTests: XCTestCase {
    func testBearerTokensAreURLSafeAndUnique() {
        let first = BearerToken.generate()
        let second = BearerToken.generate()
        XCTAssertNotEqual(first, second)
        XCTAssertGreaterThanOrEqual(first.count, 40)
        XCTAssertNil(first.range(of: #"[^A-Za-z0-9_-]"#, options: .regularExpression))
    }

    func testConstantTimeComparisonAndOriginValidation() {
        XCTAssertTrue(LocalSecurityPolicy.constantTimeEquals("secret", "secret"))
        XCTAssertFalse(LocalSecurityPolicy.constantTimeEquals("secret", "secreu"))
        XCTAssertFalse(LocalSecurityPolicy.constantTimeEquals("short", "longer"))
        XCTAssertFalse(LocalSecurityPolicy.constantTimeEquals("secret", "secret" + String(repeating: "\0", count: 256)))

        XCTAssertTrue(LocalSecurityPolicy.isAllowedOrigin("http://localhost:8765"))
        XCTAssertTrue(LocalSecurityPolicy.isAllowedOrigin("http://127.0.0.1"))
        XCTAssertTrue(LocalSecurityPolicy.isAllowedOrigin("http://[::1]:8765"))
        XCTAssertFalse(LocalSecurityPolicy.isAllowedOrigin("http://localhost.evil.example"))
        XCTAssertFalse(LocalSecurityPolicy.isAllowedOrigin("https://example.com"))
        XCTAssertFalse(LocalSecurityPolicy.isAllowedOrigin("null"))
        XCTAssertFalse(LocalSecurityPolicy.isAllowedOrigin("file:///tmp/client.html"))
    }

    func testLimitsRejectCrashAndResourceExhaustionInputs() throws {
        XCTAssertThrowsError(try AutomationLimits.validatedBurst(count: -1, intervalMs: 100))
        XCTAssertThrowsError(try AutomationLimits.validatedBurst(count: 101, intervalMs: 100))
        XCTAssertThrowsError(try AutomationLimits.validatedBurst(count: 1, intervalMs: 1))
        XCTAssertEqual(try AutomationLimits.validatedBurst(count: 10, intervalMs: 100).count, 10)
        XCTAssertThrowsError(try AutomationLimits.validatedMaxDimension(8_001))
        XCTAssertThrowsError(try AutomationLimits.validatedWaitMs(60_001))
    }

    func testCaptureGeometryAccountsForCropAndScale() {
        let geometry = CaptureGeometry(
            windowBounds: CGRect(x: 100, y: 200, width: 500, height: 400),
            originalPixelSize: CGSize(width: 1_000, height: 800),
            outputPixelSize: CGSize(width: 400, height: 300),
            trimOrigin: CGPoint(x: 100, y: 50),
            outputScale: 0.5
        )

        XCTAssertEqual(geometry.sourcePixel(fromOutputPixel: CGPoint(x: 100, y: 75)), CGPoint(x: 300, y: 200))
        XCTAssertEqual(geometry.windowPoint(fromOutputPixel: CGPoint(x: 100, y: 75)), CGPoint(x: 150, y: 100))
    }
}
