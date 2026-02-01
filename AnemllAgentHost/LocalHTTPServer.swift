import Foundation
import Network
import CoreGraphics

final class LocalHTTPServer {
    enum ServerError: Error { case startFailed(String) }

    var onLog: ((String) -> Void)?

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var bearerToken: String

    init(bindHost: String, port: UInt16, bearerToken: String) {
        self.host = NWEndpoint.Host(bindHost)
        self.port = NWEndpoint.Port(rawValue: port)!
        self.bearerToken = bearerToken
    }

    func setBearerToken(_ token: String) {
        self.bearerToken = token
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let l = try NWListener(using: params, on: port)
        l.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            self?.onLog?("Listener: \(state)")
        }

        // Bind to localhost only by rejecting non-127.0.0.1 after accept:
        // (NWListener doesn't always hard-bind to a host; we enforce in handler.)
        self.listener = l
        l.start(queue: .global(qos: .userInitiated))
        onLog?("Started on 127.0.0.1:\(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        onLog?("Stopped")
    }

    private func handle(_ conn: NWConnection) {
        // Enforce localhost origin
        if case let .hostPort(h, _) = conn.endpoint, h.debugDescription != "127.0.0.1" && h.debugDescription != "::1" {
            conn.cancel()
            return
        }

        conn.start(queue: .global(qos: .userInitiated))
        receiveRequest(on: conn)
    }

    private func receiveRequest(on conn: NWConnection) {
        var buffer = Data()

        func receiveNext() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let error {
                    self.onLog?("recv error: \(error)")
                    conn.cancel()
                    return
                }
                if let data, !data.isEmpty {
                    buffer.append(data)
                }

                if let req = HTTPRequest.tryParse(data: buffer) {
                    let response = self.route(req)
                    conn.send(content: response.serialize(), completion: .contentProcessed { _ in
                        conn.cancel()
                    })
                    return
                }

                if isComplete {
                    conn.cancel()
                    return
                }

                receiveNext()
            }
        }

        receiveNext()
    }

    private func route(_ req: HTTPRequest) -> HTTPResponse {
        guard req.isLocalhost else {
            return .text(403, "forbidden")
        }

        onLog?("Request \(req.method) \(req.path)")

        // Auth
        guard let auth = req.headers["authorization"] else {
            onLog?("Unauthorized request (missing auth)")
            return .json(401, ["error": "unauthorized"])
        }
        let parts = auth.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else {
            onLog?("Unauthorized request (bad scheme)")
            return .json(401, ["error": "unauthorized"])
        }
        let token = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard token == bearerToken else {
            onLog?("Unauthorized request")
            return .json(401, ["error": "unauthorized"])
        }

        switch (req.method, req.pathOnly) {
        case ("GET", "/health"):
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            return .json(200, ["ok": true, "version": version])

        case ("GET", "/mouse"):
            if let pt = ScreenAndInput.mouseLocation() {
                var payload: [String: Any] = ["x": Double(pt.x), "y": Double(pt.y), "space": "screen_points"]
                if let imagePt = ScreenAndInput.imageLocation(fromScreen: pt) {
                    payload["image_x"] = Double(imagePt.x)
                    payload["image_y"] = Double(imagePt.y)
                    payload["image_space"] = "image_pixels"
                }
                return .json(200, payload)
            } else {
                return .json(500, ["error": "mouse_unavailable"])
            }

        case ("POST", "/screenshot"):
            do {
                let includeCursor = (req.jsonBody?["cursor"] as? Bool) ?? true
                let info = try ScreenAndInput.takeScreenshot(includeCursor: includeCursor)
                return .json(200, info)
            } catch {
                return .json(500, ["error": "screenshot_failed", "detail": "\(error)"])
            }

        case ("POST", "/click"):
            guard let body = req.jsonBody,
                  let x = body["x"] as? Double,
                  let y = body["y"] as? Double
            else {
                return .json(400, ["error": "bad_request", "detail": "expected {x,y}"])
            }
            let space = ScreenAndInput.CoordinateSpace.parse(body["space"])
            let ok = ScreenAndInput.click(x: x, y: y, space: space)
            return .json(ok ? 200 : 500, ["ok": ok])

        case ("POST", "/move"):
            guard let body = req.jsonBody,
                  let x = body["x"] as? Double,
                  let y = body["y"] as? Double
            else {
                return .json(400, ["error": "bad_request", "detail": "expected {x,y}"])
            }
            let space = ScreenAndInput.CoordinateSpace.parse(body["space"])
            let ok = ScreenAndInput.move(x: x, y: y, space: space)
            return .json(ok ? 200 : 500, ["ok": ok])

        case ("POST", "/type"):
            guard let body = req.jsonBody,
                  let text = body["text"] as? String
            else {
                return .json(400, ["error": "bad_request", "detail": "expected {text}"])
            }
            let ok = ScreenAndInput.type(text: text)
            return .json(ok ? 200 : 500, ["ok": ok])

        case ("GET", "/windows"):
            let onScreenOnly = req.queryParam("on_screen") != "false"
            let windows = ScreenAndInput.listWindows(onScreenOnly: onScreenOnly)
            return .json(200, ["ok": true, "count": windows.count, "windows": windows])

        case ("POST", "/capture"):
            let body = req.jsonBody ?? [:]

            // At least one identifier must be provided
            let windowID = (body["window_id"] as? Int).map { CGWindowID($0) }
            let pid = (body["pid"] as? Int).map { pid_t($0) }
            let app = body["app"] as? String
            let title = body["title"] as? String

            if windowID == nil && pid == nil && app == nil && title == nil {
                return .json(400, ["error": "bad_request", "detail": "expected at least one of: window_id, pid, app, title"])
            }

            do {
                let info = try ScreenAndInput.captureWindow(
                    windowID: windowID,
                    pid: pid,
                    app: app,
                    title: title
                )
                return .json(200, info)
            } catch ScreenAndInput.Err.windowNotFound {
                return .json(404, ["error": "window_not_found", "detail": "No matching window found"])
            } catch ScreenAndInput.Err.screenCaptureNotAllowed {
                return .json(403, ["error": "screen_capture_not_allowed", "detail": "Screen Recording permission required"])
            } catch {
                return .json(500, ["error": "capture_failed", "detail": "\(error)"])
            }

        case ("POST", "/focus"):
            let body = req.jsonBody ?? [:]

            // At least one identifier must be provided
            let windowID = (body["window_id"] as? Int).map { CGWindowID($0) }
            let pid = (body["pid"] as? Int).map { pid_t($0) }
            let app = body["app"] as? String
            let title = body["title"] as? String

            if windowID == nil && pid == nil && app == nil && title == nil {
                return .json(400, ["error": "bad_request", "detail": "expected at least one of: window_id, pid, app, title"])
            }

            // Optional offset within window (default: center)
            let offsetX = body["offset_x"] as? Double
            let offsetY = body["offset_y"] as? Double

            do {
                let info = try ScreenAndInput.moveCursorToWindow(
                    windowID: windowID,
                    pid: pid,
                    app: app,
                    title: title,
                    offsetX: offsetX,
                    offsetY: offsetY
                )
                return .json(200, info)
            } catch ScreenAndInput.Err.windowNotFound {
                return .json(404, ["error": "window_not_found", "detail": "No matching window found"])
            } catch {
                return .json(500, ["error": "focus_failed", "detail": "\(error)"])
            }

        case ("POST", "/click_window"):
            let body = req.jsonBody ?? [:]

            // At least one identifier must be provided
            let windowID = (body["window_id"] as? Int).map { CGWindowID($0) }
            let pid = (body["pid"] as? Int).map { pid_t($0) }
            let app = body["app"] as? String
            let title = body["title"] as? String

            if windowID == nil && pid == nil && app == nil && title == nil {
                return .json(400, ["error": "bad_request", "detail": "expected at least one of: window_id, pid, app, title"])
            }

            // Optional offset within window (default: center)
            let offsetX = body["offset_x"] as? Double
            let offsetY = body["offset_y"] as? Double

            do {
                let info = try ScreenAndInput.clickInWindow(
                    windowID: windowID,
                    pid: pid,
                    app: app,
                    title: title,
                    offsetX: offsetX,
                    offsetY: offsetY
                )
                return .json(200, info)
            } catch ScreenAndInput.Err.windowNotFound {
                return .json(404, ["error": "window_not_found", "detail": "No matching window found"])
            } catch {
                return .json(500, ["error": "click_window_failed", "detail": "\(error)"])
            }

        default:
            return .json(404, ["error": "not_found"])
        }
    }
}

// MARK: - HTTP parsing (minimal)

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var jsonBody: [String: Any]? {
        guard !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    var isLocalhost: Bool { true } // we already enforce endpoint check

    /// Returns just the path component without query string
    var pathOnly: String {
        if let idx = path.firstIndex(of: "?") {
            return String(path[..<idx])
        }
        return path
    }

    /// Returns value for a query parameter, or nil if not present
    func queryParam(_ key: String) -> String? {
        guard let idx = path.firstIndex(of: "?") else { return nil }
        let queryString = String(path[path.index(after: idx)...])
        let pairs = queryString.split(separator: "&")
        for pair in pairs {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count >= 1, String(kv[0]) == key {
                return kv.count >= 2 ? String(kv[1]).removingPercentEncoding ?? String(kv[1]) : ""
            }
        }
        return nil
    }

    static func parse(data: Data) -> HTTPRequest {
        let s = String(data: data, encoding: .utf8) ?? ""
        let parts = s.components(separatedBy: "\r\n\r\n")
        let head = parts.first ?? ""
        let bodyStr = parts.dropFirst().joined(separator: "\r\n\r\n")
        let body = Data(bodyStr.utf8)

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? "GET / HTTP/1.1"
        let rl = requestLine.split(separator: " ")
        let method = rl.count > 0 ? String(rl[0]) : "GET"
        let path = rl.count > 1 ? String(rl[1]) : "/"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let k = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    static func tryParse(data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let sepRange = data.range(of: separator) else { return nil }

        let headerData = data.subdata(in: data.startIndex..<sepRange.lowerBound)
        let headerStr = String(data: headerData, encoding: .utf8) ?? ""
        let lines = headerStr.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? "GET / HTTP/1.1"
        let rl = requestLine.split(separator: " ")
        let method = rl.count > 0 ? String(rl[0]) : "GET"
        let path = rl.count > 1 ? String(rl[1]) : "/"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let k = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = sepRange.upperBound
        let totalNeeded = bodyStart + contentLength
        if data.count < totalNeeded { return nil }

        let body = data.subdata(in: bodyStart..<totalNeeded)
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}

struct HTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    func serialize() -> Data {
        var lines: [String] = []
        lines.append("HTTP/1.1 \(status) \(statusText(status))")
        var hdrs = headers
        hdrs["Content-Length"] = "\(body.count)"
        hdrs["Connection"] = "close"
        for (k, v) in hdrs {
            lines.append("\(k): \(v)")
        }
        lines.append("")
        let head = lines.joined(separator: "\r\n")
        var out = Data(head.utf8)
        out.append(Data("\r\n".utf8))
        out.append(body)
        return out
    }

    static func json(_ status: Int, _ obj: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data()
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    static func text(_ status: Int, _ text: String) -> HTTPResponse {
        return HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
    }
}

private func statusText(_ code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    default: return "Error"
    }
}
