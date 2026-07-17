import Foundation

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var jsonBody: [String: Any]? {
        guard !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    var pathOnly: String {
        guard let components = URLComponents(string: path) else {
            return path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        }
        return components.path
    }

    func queryParam(_ key: String) -> String? {
        URLComponents(string: path)?.queryItems?.first(where: { $0.name == key })?.value
    }

    static func tryParse(data: Data) throws -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let separatorRange = data.range(of: separator) else {
            if data.count > AutomationLimits.maximumHeaderBytes {
                throw HTTPParseError.headersTooLarge
            }
            return nil
        }

        guard separatorRange.lowerBound <= AutomationLimits.maximumHeaderBytes else {
            throw HTTPParseError.headersTooLarge
        }

        let headerData = data.subdata(in: data.startIndex..<separatorRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw HTTPParseError.invalidEncoding
        }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw HTTPParseError.invalidRequestLine }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3,
              requestParts[2].hasPrefix("HTTP/1.")
        else {
            throw HTTPParseError.invalidRequestLine
        }

        let method = String(requestParts[0]).uppercased()
        let path = String(requestParts[1])
        guard !method.isEmpty, path.hasPrefix("/") else {
            throw HTTPParseError.invalidRequestLine
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                throw HTTPParseError.invalidHeader
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw HTTPParseError.invalidHeader }
            guard headers[key] == nil else { throw HTTPParseError.invalidHeader }
            headers[key] = value
        }

        if headers["transfer-encoding"] != nil {
            throw HTTPParseError.unsupportedTransferEncoding
        }
        guard let contentLength = Int(headers["content-length"] ?? "0"), contentLength >= 0 else {
            throw HTTPParseError.invalidContentLength
        }
        guard contentLength <= AutomationLimits.maximumRequestBodyBytes else {
            throw HTTPParseError.bodyTooLarge
        }

        let bodyStart = separatorRange.upperBound
        let totalLength = bodyStart + contentLength
        guard data.count >= totalLength else { return nil }
        let body = data.subdata(in: bodyStart..<totalLength)
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}

enum HTTPParseError: Error, LocalizedError, Sendable {
    case headersTooLarge
    case bodyTooLarge
    case invalidEncoding
    case invalidRequestLine
    case invalidHeader
    case invalidContentLength
    case unsupportedTransferEncoding

    var errorDescription: String? {
        switch self {
        case .headersTooLarge: "request headers too large"
        case .bodyTooLarge: "request body too large"
        case .invalidEncoding: "request is not valid UTF-8"
        case .invalidRequestLine: "invalid HTTP request line"
        case .invalidHeader: "invalid HTTP header"
        case .invalidContentLength: "invalid Content-Length"
        case .unsupportedTransferEncoding: "Transfer-Encoding is not supported"
        }
    }

    var status: Int {
        switch self {
        case .headersTooLarge, .bodyTooLarge: 413
        case .unsupportedTransferEncoding: 501
        default: 400
        }
    }
}

struct HTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    func serialize() -> Data {
        var responseHeaders = headers
        responseHeaders["Content-Length"] = "\(body.count)"
        responseHeaders["Connection"] = "close"

        var lines = ["HTTP/1.1 \(status) \(Self.statusText(status))"]
        for key in responseHeaders.keys.sorted() {
            lines.append("\(key): \(responseHeaders[key] ?? "")")
        }
        lines.append("")

        var output = Data(lines.joined(separator: "\r\n").utf8)
        output.append(Data("\r\n".utf8))
        output.append(body)
        return output
    }

    static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        jsonAny(status, object)
    }

    static func jsonAny(_ status: Int, _ object: Any) -> HTTPResponse {
        let data = JSONSerialization.isValidJSONObject(object)
            ? ((try? JSONSerialization.data(withJSONObject: object)) ?? Data())
            : Data()
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    static func text(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(text.utf8)
        )
    }

    static func html(_ status: Int, _ html: String) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data(html.utf8)
        )
    }

    func addingHeaders(_ additionalHeaders: [String: String]) -> HTTPResponse {
        var merged = headers
        for (key, value) in additionalHeaders { merged[key] = value }
        return HTTPResponse(status: status, headers: merged, body: body)
    }

    private static func statusText(_ code: Int) -> String {
        switch code {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}
