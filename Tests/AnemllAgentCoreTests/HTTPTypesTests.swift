import XCTest
@testable import AnemllAgentCore

final class HTTPTypesTests: XCTestCase {
    func testParserWaitsForCompleteBodyAndParsesJSON() throws {
        let header = "POST /batch?mode=fast HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n"
        XCTAssertNil(try HTTPRequest.tryParse(data: Data((header + "{\"ok\":").utf8)))

        let request = try XCTUnwrap(HTTPRequest.tryParse(data: Data((header + "{\"ok\":true}").utf8)))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.pathOnly, "/batch")
        XCTAssertEqual(request.queryParam("mode"), "fast")
        XCTAssertEqual(request.jsonBody?["ok"] as? Bool, true)
    }

    func testParserRejectsTransferEncodingAndOversizedBodies() {
        XCTAssertThrowsError(try HTTPRequest.tryParse(data: Data(
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8
        ))) { error in
            XCTAssertEqual((error as? HTTPParseError)?.status, 501)
        }

        XCTAssertThrowsError(try HTTPRequest.tryParse(data: Data(
            "POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8
        ))) { error in
            XCTAssertEqual((error as? HTTPParseError)?.status, 413)
        }
    }

    func testParserRejectsMalformedRequestLine() {
        XCTAssertThrowsError(try HTTPRequest.tryParse(data: Data("NOT_HTTP\r\n\r\n".utf8))) { error in
            XCTAssertEqual((error as? HTTPParseError)?.status, 400)
        }
    }

    func testParserRejectsDuplicateHeaders() {
        XCTAssertThrowsError(try HTTPRequest.tryParse(data: Data(
            "POST / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n".utf8
        ))) { error in
            XCTAssertEqual((error as? HTTPParseError)?.status, 400)
        }
    }
}
