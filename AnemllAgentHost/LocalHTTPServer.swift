import Foundation
import Network
import CoreGraphics

final class LocalHTTPServer: @unchecked Sendable {
    enum ServerError: Error { case startFailed(String) }

    var onLog: ((String) -> Void)?
    var onState: ((NWListener.State) -> Void)?

    // Debug viewer state: sequence-based to avoid relying on filesystem mtime resolution.
    private final class DebugCaptureState: @unchecked Sendable {
        let lock = NSLock()
        var sequence: Int64 = 0
        var milliseconds: Int64 = 0
    }

    private final class RequestBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func appendAndSnapshot(_ newData: Data?) -> Data {
            lock.withLock {
                if let newData, !newData.isEmpty { data.append(newData) }
                return data
            }
        }
    }
    private static let debugCaptureState = DebugCaptureState()

    private static func bumpDebugCapture(nowMs: Int64? = nil) {
        let ms = nowMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        debugCaptureState.lock.withLock {
            debugCaptureState.sequence += 1
            debugCaptureState.milliseconds = max(debugCaptureState.milliseconds, ms)
        }
    }

    private static func debugCaptureMeta(fileMtimeMs: Int64?) -> (seq: Int64, ms: Int64) {
        debugCaptureState.lock.withLock {
            if let m = fileMtimeMs, m > debugCaptureState.milliseconds {
                debugCaptureState.sequence += 1
                debugCaptureState.milliseconds = m
            }
            return (debugCaptureState.sequence, debugCaptureState.milliseconds)
        }
    }

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var bearerToken: String
    private let tokenLock = NSLock()

    init(bindHost: String, port: UInt16, bearerToken: String) {
        self.host = NWEndpoint.Host(bindHost)
        self.port = NWEndpoint.Port(rawValue: port)!
        self.bearerToken = bearerToken
    }

    func setBearerToken(_ token: String) {
        tokenLock.withLock {
            self.bearerToken = token
        }
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: host, port: port)

        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            self?.onLog?("Listener: \(state)")
            self?.onState?(state)
        }

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
        receiveNext(on: conn, buffer: RequestBuffer())
    }

    private func receiveNext(on conn: NWConnection, buffer: RequestBuffer) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.onLog?("recv error: \(error)")
                conn.cancel()
                return
            }

            let requestData = buffer.appendAndSnapshot(data)
            do {
                if let req = try HTTPRequest.tryParse(data: requestData) {
                    Task { [weak self] in
                        guard let self else {
                            conn.cancel()
                            return
                        }
                        let response = await self.route(req)
                        conn.send(content: response.serialize(), completion: .contentProcessed { _ in
                            conn.cancel()
                        })
                    }
                    return
                }
            } catch let parseError as HTTPParseError {
                let response = HTTPResponse.json(
                    parseError.status,
                    ["error": "invalid_http_request", "detail": parseError.localizedDescription]
                )
                conn.send(content: response.serialize(), completion: .contentProcessed { _ in
                    conn.cancel()
                })
                return
            } catch {
                conn.cancel()
                return
            }

            if isComplete {
                conn.cancel()
                return
            }
            self.receiveNext(on: conn, buffer: buffer)
        }
    }

    private func route(_ req: HTTPRequest) async -> HTTPResponse {
        onLog?("Request \(req.method) \(req.pathOnly)")

        // The debug shell contains no capture data. Its fragment token is consumed by
        // JavaScript and sent as an Authorization header for protected subresources.
        let isPublicDebugShell = req.method == "GET" && req.pathOnly == "/debug"

        if req.method == "OPTIONS", req.pathOnly == "/mcp" {
            if let origin = req.headers["origin"], !LocalSecurityPolicy.isAllowedOrigin(origin) {
                return .json(403, ["error": "forbidden", "detail": "origin_not_allowed"])
            }
            var headers = [
                "Allow": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Authorization, Content-Type, MCP-Protocol-Version",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Vary": "Origin"
            ]
            if let origin = req.headers["origin"] {
                headers["Access-Control-Allow-Origin"] = origin
            }
            return HTTPResponse(
                status: 204,
                headers: headers,
                body: Data()
            )
        }

        // Protected endpoints accept credentials only through the bearer header.
        var authenticated = false

        if let auth = req.headers["authorization"] {
            let parts = auth.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                let token = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                let expectedToken = tokenLock.withLock { bearerToken }
                authenticated = LocalSecurityPolicy.constantTimeEquals(token, expectedToken)
            }
        }

        guard authenticated || isPublicDebugShell else {
            onLog?("Unauthorized request")
            return .json(401, ["error": "unauthorized"])
        }

        switch (req.method, req.pathOnly) {
        case ("GET", "/health"):
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            return .json(200, ["ok": true, "version": version])

        case ("POST", "/mcp"):
            let response = await routeMCP(req)
            if let origin = req.headers["origin"], LocalSecurityPolicy.isAllowedOrigin(origin) {
                return response.addingHeaders([
                    "Access-Control-Allow-Origin": origin,
                    "Vary": "Origin"
                ])
            }
            return response

        case ("GET", "/mcp"):
            return HTTPResponse(
                status: 405,
                headers: ["Allow": "POST, OPTIONS"],
                body: Data()
            )

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
                let body = req.jsonBody ?? [:]
                let includeCursor = (body["cursor"] as? Bool) ?? true
                let returnBase64 = (body["return_base64"] as? Bool) ?? false
                let saveToFile = (body["save_to_file"] as? Bool) ?? !returnBase64

                // Default to Claude-friendly size if caller doesn't specify
                let maxDimension: Int
                if let maxDimVal = body["max_dimension"] {
                    if let intVal = maxDimVal as? Int {
                        maxDimension = intVal
                    } else if let strVal = maxDimVal as? String {
                        switch strVal.lowercased() {
                        case "playwright", "default", "claude", "claudecode", "optimal", "recommended":
                            maxDimension = ScreenAndInput.defaultMaxDimension  // 1120
                        case "safe", "2000":
                            maxDimension = ScreenAndInput.safeMaxDimension     // 2000
                        case "max", "hard", "limit":
                            maxDimension = ScreenAndInput.hardMaxDimension     // 8000
                        case "full", "none", "0":
                            maxDimension = 0
                        default:
                            maxDimension = Int(strVal) ?? ScreenAndInput.defaultMaxDimension
                        }
                    } else {
                        maxDimension = ScreenAndInput.defaultMaxDimension
                    }
                } else {
                    maxDimension = ScreenAndInput.defaultMaxDimension
                }

                guard (try? AutomationLimits.validatedMaxDimension(maxDimension)) != nil else {
                    return .json(400, ["error": "bad_request", "detail": "max_dimension must be between 0 and 8000"])
                }

                let resizeMode: ScreenAndInput.ResizeMode
                if let modeStr = body["resize_mode"] as? String {
                    resizeMode = modeStr.lowercased() == "crop" ? .crop : .scale
                } else {
                    resizeMode = .scale
                }

                let info = try await ScreenAndInput.takeScreenshot(
                    path: saveToFile ? "/tmp/anemll_last.png" : nil,
                    includeCursor: includeCursor,
                    maxDimension: maxDimension,
                    resizeMode: resizeMode,
                    returnBase64: returnBase64
                )
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

        case ("POST", "/double_click"):
            guard let body = req.jsonBody,
                  let x = body["x"] as? Double,
                  let y = body["y"] as? Double
            else {
                return .json(400, ["error": "bad_request", "detail": "expected {x,y}"])
            }
            let space = ScreenAndInput.CoordinateSpace.parse(body["space"])
            let ok = ScreenAndInput.doubleClick(x: x, y: y, space: space)
            return .json(ok ? 200 : 500, ["ok": ok])

        case ("POST", "/right_click"):
            guard let body = req.jsonBody,
                  let x = body["x"] as? Double,
                  let y = body["y"] as? Double
            else {
                return .json(400, ["error": "bad_request", "detail": "expected {x,y}"])
            }
            let space = ScreenAndInput.CoordinateSpace.parse(body["space"])
            let ok = ScreenAndInput.rightClick(x: x, y: y, space: space)
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

        case ("POST", "/scroll"):
            guard let body = req.jsonBody else {
                return .json(400, ["error": "bad_request", "detail": "expected {dx,dy}"])
            }
            let dx = body["dx"] as? Double ?? 0
            let dy = body["dy"] as? Double ?? 0
            if dx == 0 && dy == 0 {
                return .json(400, ["error": "bad_request", "detail": "expected non-zero dx or dy"])
            }

            if let x = body["x"] as? Double, let y = body["y"] as? Double {
                let space = ScreenAndInput.CoordinateSpace.parse(body["space"])
                _ = ScreenAndInput.move(x: x, y: y, space: space)
            }

            let ok = ScreenAndInput.scroll(dx: dx, dy: dy, isContinuous: true)
            return .json(ok ? 200 : 500, ["ok": ok, "dx": dx, "dy": dy])

        case ("POST", "/type"):
            guard let body = req.jsonBody,
                  let text = body["text"] as? String
            else {
                return .json(400, ["error": "bad_request", "detail": "expected {text}"])
            }
            do {
                try AutomationLimits.validateText(text)
            } catch {
                return .json(400, ["error": "bad_request", "detail": error.localizedDescription])
            }
            let ok = ScreenAndInput.type(text: text)
            return .json(ok ? 200 : 500, ["ok": ok])

        case ("POST", "/paste"):
            guard let body = req.jsonBody, let text = body["text"] as? String else {
                return .json(400, ["error": "bad_request", "detail": "expected {text}"])
            }
            do {
                try AutomationLimits.validateText(text)
                let ok = await ScreenAndInput.paste(text: text)
                return .json(ok ? 200 : 500, ["ok": ok])
            } catch {
                return .json(400, ["error": "bad_request", "detail": error.localizedDescription])
            }

        case ("POST", "/hotkey"):
            guard let body = req.jsonBody, let keys = parseKeys(body["keys"] ?? body["shortcut"]), !keys.isEmpty else {
                return .json(400, ["error": "bad_request", "detail": "expected {keys:[...]} or {shortcut:'command+v'}"])
            }
            let ok = ScreenAndInput.hotkey(keys: keys)
            return .json(ok ? 200 : 500, ["ok": ok, "keys": keys])

        case ("POST", "/drag"):
            guard let body = req.jsonBody,
                  let fromX = doubleValue(body["from_x"]), let fromY = doubleValue(body["from_y"]),
                  let toX = doubleValue(body["to_x"]), let toY = doubleValue(body["to_y"])
            else {
                return .json(400, ["error": "bad_request", "detail": "expected {from_x,from_y,to_x,to_y}"])
            }
            let durationMs = intValue(body["duration_ms"]) ?? 350
            guard (50...10_000).contains(durationMs) else {
                return .json(400, ["error": "bad_request", "detail": "duration_ms must be between 50 and 10000"])
            }
            let space = ScreenAndInput.CoordinateSpace.parse(body["space"])
            let ok = await ScreenAndInput.drag(
                fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                space: space, durationMs: durationMs
            )
            return .json(ok ? 200 : 500, ["ok": ok])

        case ("POST", "/activate"):
            guard let body = req.jsonBody, let app = body["app"] as? String, !app.isEmpty else {
                return .json(400, ["error": "bad_request", "detail": "expected {app}"])
            }
            if let activation = await ScreenAndInput.activate(app: app) {
                return .json(activation.ok ? 200 : 500, activation.dictionary)
            }
            return .json(404, ["error": "application_not_found"])

        case ("POST", "/accessibility/tree"):
            do {
                return .json(200, try AccessibilityAutomation.snapshot(query: parseAccessibilityQuery(req.jsonBody ?? [:])))
            } catch {
                return accessibilityHTTPError(error)
            }

        case ("POST", "/accessibility/action"):
            let body = req.jsonBody ?? [:]
            guard let action = body["action"] as? String, !action.isEmpty else {
                return .json(400, ["error": "bad_request", "detail": "expected {action}"])
            }
            do {
                let info = try AccessibilityAutomation.perform(
                    query: parseAccessibilityQuery(body),
                    action: action,
                    value: body["value"] as? String
                )
                return .json(200, info)
            } catch {
                return accessibilityHTTPError(error)
            }

        case ("POST", "/accessibility/wait"):
            do {
                return .json(200, try await waitForAccessibility(arguments: req.jsonBody ?? [:]))
            } catch {
                return accessibilityHTTPError(error)
            }

        case ("POST", "/batch"):
            guard let actions = req.jsonBody?["actions"] as? [[String: Any]] else {
                return .json(400, ["error": "bad_request", "detail": "expected {actions:[...]} "])
            }
            do {
                return .json(200, try await executeBatch(actions))
            } catch {
                return .json(400, ["error": "batch_failed", "detail": error.localizedDescription])
            }

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
            let includeCursor = (body["cursor"] as? Bool) ?? true

            // Capture output options
            let returnBase64 = (body["return_base64"] as? Bool) ?? false
            let saveToFile = (body["save_to_file"] as? Bool) ?? !returnBase64
            let runOCR = (body["ocr"] as? Bool) ?? false

            // max_dimension: 0 = no resizing, "playwright" = 1120, "safe" = 2000, "max" = 8000, or specific int
            // "playwright" matches Playwright MCP's 1.15MP target - most reliable for Claude Code
            let maxDimension: Int
            if let maxDimVal = body["max_dimension"] {
                if let intVal = maxDimVal as? Int {
                    maxDimension = intVal
                } else if let strVal = maxDimVal as? String {
                    switch strVal.lowercased() {
                    case "playwright", "default", "claude", "claudecode", "optimal", "recommended":
                        maxDimension = ScreenAndInput.defaultMaxDimension  // 1120 (Playwright target)
                    case "safe", "2000":
                        maxDimension = ScreenAndInput.safeMaxDimension     // 2000
                    case "max", "hard", "limit":
                        maxDimension = ScreenAndInput.hardMaxDimension     // 8000
                    default:
                        maxDimension = Int(strVal) ?? 0
                    }
                } else {
                    maxDimension = 0
                }
            } else {
                maxDimension = 0
            }

            guard (try? AutomationLimits.validatedMaxDimension(maxDimension)) != nil else {
                return .json(400, ["error": "bad_request", "detail": "max_dimension must be between 0 and 8000"])
            }

            // resize_mode: "crop" (default) preserves pixel accuracy, "scale" resizes proportionally
            let resizeMode: ScreenAndInput.ResizeMode
            if let modeStr = body["resize_mode"] as? String {
                resizeMode = modeStr.lowercased() == "scale" ? .scale : .crop
            } else {
                resizeMode = .crop
            }

            if windowID == nil && pid == nil && app == nil && title == nil {
                return .json(400, ["error": "bad_request", "detail": "expected at least one of: window_id, pid, app, title"])
            }

            do {
                let info = try await ScreenAndInput.captureWindow(
                    windowID: windowID,
                    pid: pid,
                    app: app,
                    title: title,
                    path: saveToFile ? "/tmp/anemll_window.png" : nil,
                    includeCursor: includeCursor,
                    maxDimension: maxDimension,
                    resizeMode: resizeMode,
                    returnBase64: returnBase64,
                    runOCR: runOCR
                )
                if (info["path"] as? String) == "/tmp/anemll_window.png" {
                    Self.bumpDebugCapture()
                }
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

        case ("POST", "/scroll_window"):
            let body = req.jsonBody ?? [:]

            // At least one identifier must be provided
            let windowID = (body["window_id"] as? Int).map { CGWindowID($0) }
            let pid = (body["pid"] as? Int).map { pid_t($0) }
            let app = body["app"] as? String
            let title = body["title"] as? String

            if windowID == nil && pid == nil && app == nil && title == nil {
                return .json(400, ["error": "bad_request", "detail": "expected at least one of: window_id, pid, app, title"])
            }

            let dx = body["dx"] as? Double ?? 0
            let dy = body["dy"] as? Double ?? 0
            if dx == 0 && dy == 0 {
                return .json(400, ["error": "bad_request", "detail": "expected non-zero dx or dy"])
            }

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
                let ok = ScreenAndInput.scroll(dx: dx, dy: dy, isContinuous: true)
                var payload = info
                payload["ok"] = ok
                payload["dx"] = dx
                payload["dy"] = dy
                return .json(ok ? 200 : 500, payload)
            } catch ScreenAndInput.Err.windowNotFound {
                return .json(404, ["error": "window_not_found", "detail": "No matching window found"])
            } catch {
                return .json(500, ["error": "scroll_window_failed", "detail": "\(error)"])
            }

        case ("POST", "/burst"):
            let body = req.jsonBody ?? [:]

            // Optional window targeting (if none provided, captures full screen)
            let windowID = (body["window_id"] as? Int).map { CGWindowID($0) }
            let pid = (body["pid"] as? Int).map { pid_t($0) }
            let app = body["app"] as? String
            let title = body["title"] as? String

            // Burst parameters
            let count = (body["count"] as? Int) ?? 10
            let intervalMs = (body["interval_ms"] as? Int) ?? 100
            let burstParameters: (count: Int, intervalMs: Int)
            do {
                burstParameters = try AutomationLimits.validatedBurst(count: count, intervalMs: intervalMs)
            } catch {
                return .json(400, ["error": "bad_request", "detail": error.localizedDescription])
            }

            // Resize parameters
            let maxDimension: Int
            if let maxDimVal = body["max_dimension"] {
                if let intVal = maxDimVal as? Int {
                    maxDimension = intVal
                } else if let strVal = maxDimVal as? String {
                    switch strVal.lowercased() {
                    case "playwright", "default", "claude", "claudecode", "optimal", "recommended":
                        maxDimension = ScreenAndInput.defaultMaxDimension
                    case "safe", "2000":
                        maxDimension = ScreenAndInput.safeMaxDimension
                    case "max", "hard", "limit":
                        maxDimension = ScreenAndInput.hardMaxDimension
                    default:
                        maxDimension = Int(strVal) ?? 0
                    }
                } else {
                    maxDimension = 0
                }
            } else {
                maxDimension = 0
            }

            guard (try? AutomationLimits.validatedMaxDimension(maxDimension)) != nil else {
                return .json(400, ["error": "bad_request", "detail": "max_dimension must be between 0 and 8000"])
            }

            let resizeMode: ScreenAndInput.ResizeMode
            if let modeStr = body["resize_mode"] as? String {
                resizeMode = modeStr.lowercased() == "scale" ? .scale : .crop
            } else {
                resizeMode = .crop
            }

            do {
                let info = try await ScreenAndInput.burstCapture(
                    windowID: windowID,
                    pid: pid,
                    app: app,
                    title: title,
                    count: burstParameters.count,
                    intervalMs: burstParameters.intervalMs,
                    maxDimension: maxDimension,
                    resizeMode: resizeMode
                )
                return .json(200, info)
            } catch ScreenAndInput.Err.windowNotFound {
                return .json(404, ["error": "window_not_found", "detail": "No matching window found"])
            } catch ScreenAndInput.Err.screenCaptureNotAllowed {
                return .json(403, ["error": "screen_capture_not_allowed", "detail": "Screen Recording permission required"])
            } catch {
                return .json(500, ["error": "burst_failed", "detail": "\(error)"])
            }

        case ("GET", "/debug"):
            // Debug viewer - serves HTML page that shows latest capture without full-page refresh
            // Access via: http://127.0.0.1:8765/debug#token=YOUR_TOKEN (fragment is not sent in HTTP requests)
            // For SSH tunnel: ssh -L 8765:localhost:8765 user@mac
            let html = """
            <!DOCTYPE html>
            <html>
            <head>
                <title>AnemllAgentHost Debug Viewer</title>
                <style>
                    body { font-family: -apple-system, sans-serif; margin: 20px; background: #1a1a1a; color: #fff; }
                    h1 { margin: 0 0 10px 0; }
                    .info { font-size: 12px; color: #888; margin-bottom: 10px; }
                    .container { display: flex; gap: 20px; }
                    .image-box { flex: 1; }
                    img { max-width: 100%; border: 1px solid #333; }
                    .no-image { padding: 40px; text-align: center; color: #666; border: 1px dashed #333; }
                </style>
            </head>
            <body>
                <h1>AnemllAgentHost Debug</h1>
                <div class="info">Updates only when a new capture is available (no flashing).</div>
                <div class="container">
                    <div class="image-box">
                        <img id="capture" src="" style="display:none;"
                             onerror="this.style.display='none';document.getElementById('no-img').style.display='block';">
                        <div id="no-img" class="no-image">No capture available.<br>Run /capture to see image here.</div>
                    </div>
                </div>
                <script>
                    let lastSeq = 0;
                    let lastMtime = 0;
                    const token = decodeURIComponent(location.hash.replace(/^#token=/, ""));
                    history.replaceState(null, "", location.pathname);
                    const authHeaders = token ? { "Authorization": `Bearer ${token}` } : {};
                    const metaUrl = "/debug/meta";
                    const imgBase = "/debug/image?t=";
                    let previousObjectUrl = null;

                    async function poll() {
                        try {
                            const res = await fetch(metaUrl, { cache: "no-store", headers: authHeaders });
                            if (!res.ok) return;
                            const data = await res.json();
                            const seq = data.seq || 0;
                            const mtime = data.mtime_ms || 0;
                            if ((seq && seq !== lastSeq) || (!seq && mtime && mtime !== lastMtime)) {
                                lastSeq = seq;
                                lastMtime = mtime || Date.now();
                                const img = document.getElementById("capture");
                                const imageResponse = await fetch(imgBase + (mtime || lastMtime), {
                                    cache: "no-store",
                                    headers: authHeaders
                                });
                                if (!imageResponse.ok) return;
                                const objectUrl = URL.createObjectURL(await imageResponse.blob());
                                img.src = objectUrl;
                                if (previousObjectUrl) URL.revokeObjectURL(previousObjectUrl);
                                previousObjectUrl = objectUrl;
                                img.style.display = "block";
                                document.getElementById("no-img").style.display = "none";
                            }
                        } catch (e) {
                            // Ignore transient errors
                        }
                    }

                    poll();
                    setInterval(poll, 2000);
                </script>
            </body>
            </html>
            """
            return HTTPResponse(
                status: 200,
                headers: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
                    "Pragma": "no-cache"
                ],
                body: Data(html.utf8)
            )

        case ("GET", "/debug/image"):
            // Serve the last captured window image
            let path = "/tmp/anemll_window.png"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                return HTTPResponse(status: 200, headers: ["Content-Type": "image/png", "Cache-Control": "no-cache"], body: data)
            } else {
                // Return a 1x1 transparent PNG if no image exists
                let emptyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
                return HTTPResponse(status: 200, headers: ["Content-Type": "image/png"], body: emptyPNG)
            }
        case ("GET", "/debug/meta"):
            // Return last modified time for the capture image (to avoid flashing refresh)
            let path = "/tmp/anemll_window.png"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let modDate = attrs[.modificationDate] as? Date {
                let mtimeMs = Int64(modDate.timeIntervalSince1970 * 1000)
                let meta = Self.debugCaptureMeta(fileMtimeMs: mtimeMs)
                return .json(200, ["ok": true, "mtime_ms": mtimeMs, "seq": meta.seq, "last_capture_ms": meta.ms])
            } else {
                let meta = Self.debugCaptureMeta(fileMtimeMs: nil)
                return .json(200, ["ok": false, "mtime_ms": 0, "seq": meta.seq, "last_capture_ms": meta.ms])
            }

        case ("POST", "/calibrate"):
            // Calibration endpoint: captures window, runs OCR, returns scale and offset info
            // Agent can use this to measure actual vs expected positions
            //
            // Calibration procedure for agents:
            // 1. POST /calibrate with window identifier (app, title, etc.)
            // 2. Response includes: window bounds, image dimensions, scale factors
            // 3. OCR results include both raw pixel coords AND click coords
            // 4. Agent can click a known element and verify cursor position
            // 5. If offset observed, agent stores calibration offset for future clicks
            //
            // For iPhone mirroring: capture the iPhone window, find a known UI element,
            // click it, observe if click lands correctly, adjust offset if needed.

            let body = req.jsonBody ?? [:]
            let windowID = (body["window_id"] as? Int).map { CGWindowID($0) }
            let pid = (body["pid"] as? Int).map { pid_t($0) }
            let app = body["app"] as? String
            let title = body["title"] as? String

            if windowID == nil && pid == nil && app == nil && title == nil {
                return .json(400, ["error": "bad_request", "detail": "expected at least one of: window_id, pid, app, title"])
            }

            do {
                // Capture with OCR enabled
                let captureInfo = try await ScreenAndInput.captureWindow(
                    windowID: windowID,
                    pid: pid,
                    app: app,
                    title: title,
                    includeCursor: true,
                    maxDimension: 0,  // No resize for accurate calibration
                    runOCR: true
                )

                var response: [String: Any] = [
                    "ok": true,
                    "calibration": [
                        "image_w": captureInfo["w"] ?? 0,
                        "image_h": captureInfo["h"] ?? 0,
                        "ocr_scale": captureInfo["ocr_scale"] ?? 1.0,
                        "instructions": [
                            "1. OCR 'click_x' and 'click_y' are in window points, ready for /click_window offset_x/offset_y",
                            "2. To verify: pick an OCR element, call /click_window with its click_x, click_y",
                            "3. If click lands offset from target, measure the delta",
                            "4. Apply delta correction to future click_x, click_y values",
                            "5. For consistent results, keep window at same position/size"
                        ]
                    ]
                ]

                // Copy relevant fields from capture
                for key in ["window_id", "app", "title", "pid", "bounds", "path", "ocr", "ocr_count"] {
                    if let val = captureInfo[key] {
                        response[key] = val
                    }
                }

                return .json(200, response)
            } catch ScreenAndInput.Err.windowNotFound {
                return .json(404, ["error": "window_not_found"])
            } catch {
                return .json(500, ["error": "calibrate_failed", "detail": "\(error)"])
            }

        default:
            return .json(404, ["error": "not_found"])
        }
    }

    // MARK: - Compact semantic automation

    private func parseKeys(_ raw: Any?) -> [String]? {
        if let keys = raw as? [String] {
            return (1...6).contains(keys.count) ? keys : nil
        }
        if let shortcut = raw as? String {
            let keys = shortcut.split(separator: "+").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            return (1...6).contains(keys.count) ? keys : nil
        }
        return nil
    }

    private func parseAccessibilityQuery(_ args: [String: Any]) -> AccessibilityAutomation.Query {
        AccessibilityAutomation.Query(
            pid: intValue(args["pid"]).map { pid_t($0) },
            app: args["app"] as? String,
            role: args["role"] as? String,
            title: (args["title"] as? String) ?? (args["text"] as? String),
            identifier: args["identifier"] as? String,
            maxDepth: intValue(args["max_depth"]) ?? 8,
            maxElements: intValue(args["max_elements"]) ?? 500
        )
    }

    private func accessibilityHTTPError(_ error: Swift.Error) -> HTTPResponse {
        guard let accessibilityError = error as? AccessibilityAutomation.Error else {
            return .json(400, ["error": "accessibility_failed", "detail": error.localizedDescription])
        }
        switch accessibilityError {
        case .permissionRequired:
            return .json(403, ["error": "accessibility_not_allowed", "detail": accessibilityError.localizedDescription])
        case .applicationNotFound, .elementNotFound:
            return .json(404, ["error": "not_found", "detail": accessibilityError.localizedDescription])
        case .unsupportedAction:
            return .json(400, ["error": "unsupported_action", "detail": accessibilityError.localizedDescription])
        case .operationFailed:
            return .json(409, ["error": "operation_failed", "detail": accessibilityError.localizedDescription])
        }
    }

    private func waitForAccessibility(arguments: [String: Any]) async throws -> [String: Any] {
        let timeoutMs = try AutomationLimits.validatedWaitMs(intValue(arguments["timeout_ms"]) ?? 5_000)
        let pollMs = min(max(intValue(arguments["poll_ms"]) ?? 100, 25), 5_000)
        let desiredExists = (arguments["state"] as? String)?.lowercased() != "gone"
        let query = parseAccessibilityQuery(arguments)
        let startedAt = CFAbsoluteTimeGetCurrent()

        while true {
            let exists: Bool
            do {
                exists = try AccessibilityAutomation.elementExists(query: query)
            } catch AccessibilityAutomation.Error.applicationNotFound {
                exists = false
            }

            let elapsedMs = Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000).rounded())
            if exists == desiredExists {
                return ["ok": true, "exists": exists, "elapsed_ms": elapsedMs]
            }
            if elapsedMs >= timeoutMs {
                return ["ok": false, "exists": exists, "timed_out": true, "elapsed_ms": elapsedMs]
            }
            try await Task.sleep(for: .milliseconds(min(pollMs, max(timeoutMs - elapsedMs, 1))))
        }
    }

    private func executeBatch(_ actions: [[String: Any]]) async throws -> [String: Any] {
        guard !actions.isEmpty else { throw AutomationValidationError("actions must not be empty") }
        guard actions.count <= AutomationLimits.maximumBatchActions else {
            throw AutomationValidationError("actions exceeds \(AutomationLimits.maximumBatchActions)")
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        var results: [[String: Any]] = []
        for (index, action) in actions.enumerated() {
            do {
                var result = try await executeAutomationAction(action)
                result["index"] = index
                results.append(result)
            } catch {
                throw AutomationValidationError("action \(index) failed: \(error.localizedDescription)")
            }
        }
        return [
            "ok": true,
            "count": results.count,
            "elapsed_ms": Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000).rounded()),
            "results": results
        ]
    }

    private func executeAutomationAction(_ args: [String: Any]) async throws -> [String: Any] {
        guard let action = (args["type"] as? String)?.lowercased() else {
            throw AutomationValidationError("action requires type")
        }

        switch action {
        case "click", "double_click", "right_click", "move":
            guard let x = doubleValue(args["x"]), let y = doubleValue(args["y"]) else {
                throw AutomationValidationError("\(action) requires x and y")
            }
            let space = ScreenAndInput.CoordinateSpace.parse(args["space"])
            let ok: Bool = switch action {
            case "click": ScreenAndInput.click(x: x, y: y, space: space)
            case "double_click": ScreenAndInput.doubleClick(x: x, y: y, space: space)
            case "right_click": ScreenAndInput.rightClick(x: x, y: y, space: space)
            default: ScreenAndInput.move(x: x, y: y, space: space)
            }
            guard ok else { throw AutomationValidationError("\(action) failed") }
            return ["ok": true, "type": action]

        case "scroll":
            let dx = doubleValue(args["dx"]) ?? 0
            let dy = doubleValue(args["dy"]) ?? 0
            guard dx != 0 || dy != 0 else { throw AutomationValidationError("scroll requires non-zero dx or dy") }
            guard ScreenAndInput.scroll(dx: dx, dy: dy) else { throw AutomationValidationError("scroll failed") }
            return ["ok": true, "type": action]

        case "type", "paste":
            guard let text = args["text"] as? String else { throw AutomationValidationError("\(action) requires text") }
            try AutomationLimits.validateText(text)
            let ok = action == "paste" ? await ScreenAndInput.paste(text: text) : ScreenAndInput.type(text: text)
            guard ok else { throw AutomationValidationError("\(action) failed") }
            return ["ok": true, "type": action, "characters": text.count]

        case "hotkey":
            guard let keys = parseKeys(args["keys"] ?? args["shortcut"]), ScreenAndInput.hotkey(keys: keys) else {
                throw AutomationValidationError("hotkey requires one non-modifier key")
            }
            return ["ok": true, "type": action, "keys": keys]

        case "drag":
            guard let fromX = doubleValue(args["from_x"]), let fromY = doubleValue(args["from_y"]),
                  let toX = doubleValue(args["to_x"]), let toY = doubleValue(args["to_y"])
            else { throw AutomationValidationError("drag requires from_x, from_y, to_x, to_y") }
            let durationMs = intValue(args["duration_ms"]) ?? 350
            guard (50...10_000).contains(durationMs) else {
                throw AutomationValidationError("duration_ms must be between 50 and 10000")
            }
            let ok = await ScreenAndInput.drag(
                fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                space: .parse(args["space"]), durationMs: durationMs
            )
            guard ok else { throw AutomationValidationError("drag failed") }
            return ["ok": true, "type": action]

        case "activate":
            guard let app = args["app"] as? String,
                  let activation = await ScreenAndInput.activate(app: app), activation.ok
            else {
                throw AccessibilityAutomation.Error.applicationNotFound
            }
            return activation.dictionary

        case "wait":
            let delayMs = try AutomationLimits.validatedWaitMs(intValue(args["duration_ms"]) ?? intValue(args["timeout_ms"]) ?? 100)
            try await Task.sleep(for: .milliseconds(delayMs))
            return ["ok": true, "type": action, "elapsed_ms": delayMs]

        case "accessibility_action":
            guard let axAction = args["action"] as? String else {
                throw AutomationValidationError("accessibility_action requires action")
            }
            return try AccessibilityAutomation.perform(
                query: parseAccessibilityQuery(args),
                action: axAction,
                value: args["value"] as? String
            )

        case "accessibility_wait":
            return try await waitForAccessibility(arguments: args)

        default:
            throw AutomationValidationError("unsupported batch action: \(action)")
        }
    }

    // MARK: - MCP (Model Context Protocol) JSON-RPC

    private static let supportedMCPProtocolVersions: [String] = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26"
    ]

    private func routeMCP(_ req: HTTPRequest) async -> HTTPResponse {
        // Basic Origin validation (MCP recommends rejecting browser origins to prevent DNS rebinding).
        if let origin = req.headers["origin"], !isAllowedMCPOrigin(origin) {
            return .json(403, ["error": "forbidden", "detail": "origin_not_allowed"])
        }

        if let protocolVersion = req.headers["mcp-protocol-version"],
           !Self.supportedMCPProtocolVersions.contains(protocolVersion) {
            return .json(400, ["error": "unsupported_protocol_version", "detail": protocolVersion])
        }

        if let contentType = req.headers["content-type"]?.lowercased(),
           !contentType.hasPrefix("application/json") {
            return .json(415, ["error": "unsupported_media_type", "detail": "expected application/json"])
        }

        guard !req.body.isEmpty else {
            return HTTPResponse.jsonAny(200, jsonrpcError(id: nil, code: -32700, message: "Parse error", data: "empty_body"))
        }

        let payloadAny: Any
        do {
            payloadAny = try JSONSerialization.jsonObject(with: req.body, options: [])
        } catch {
            return HTTPResponse.jsonAny(200, jsonrpcError(id: nil, code: -32700, message: "Parse error", data: "\(error)"))
        }

        if let msg = payloadAny as? [String: Any] {
            if let response = await handleMCPMessage(msg) {
                return HTTPResponse.jsonAny(200, response)
            }
            // Notification: no JSON-RPC response.
            return HTTPResponse(status: 202, headers: ["Content-Type": "application/json"], body: Data())
        }

        if payloadAny is [Any] {
            return HTTPResponse.jsonAny(
                200,
                jsonrpcError(id: nil, code: -32600, message: "Invalid Request", data: "MCP Streamable HTTP accepts one JSON-RPC message per POST")
            )
        }

        return HTTPResponse.jsonAny(200, jsonrpcError(id: nil, code: -32600, message: "Invalid Request", data: "expected_object_or_array"))
    }

    private func isAllowedMCPOrigin(_ origin: String) -> Bool {
        LocalSecurityPolicy.isAllowedOrigin(origin)
    }

    private func handleMCPMessage(_ msg: [String: Any]) async -> [String: Any]? {
        // JSON-RPC 2.0 envelope
        guard (msg["jsonrpc"] as? String) == "2.0" else {
            return jsonrpcError(id: nil, code: -32600, message: "Invalid Request", data: "missing_jsonrpc_2.0")
        }

        let id = msg["id"]
        guard let method = msg["method"] as? String else {
            return jsonrpcError(id: nil, code: -32600, message: "Invalid Request", data: "missing_method")
        }

        let params = msg["params"] as? [String: Any] ?? [:]

        // Notifications have no id and must not return a JSON-RPC response.
        let isNotification = (id == nil)

        do {
            switch method {
            case "initialize":
                if isNotification {
                    return jsonrpcError(id: nil, code: -32600, message: "Invalid Request", data: "initialize_requires_id")
                }
                let result = try mcpInitialize(params: params)
                return jsonrpcResult(id: id, result: result)

            case "ping":
                return isNotification ? nil : jsonrpcResult(id: id, result: [:])

            case "tools/list":
                let result: [String: Any] = ["tools": mcpToolsList()]
                return isNotification ? nil : jsonrpcResult(id: id, result: result)

            case "tools/call":
                let result = try await mcpToolsCall(params: params)
                return isNotification ? nil : jsonrpcResult(id: id, result: result)

            case "resources/list":
                let result: [String: Any] = ["resources": []]
                return isNotification ? nil : jsonrpcResult(id: id, result: result)

            case "prompts/list":
                let result: [String: Any] = ["prompts": []]
                return isNotification ? nil : jsonrpcResult(id: id, result: result)

            case "notifications/initialized":
                return nil

            default:
                if isNotification { return nil }
                return jsonrpcError(id: id, code: -32601, message: "Method not found", data: method)
            }
        } catch let err as MCPToolError {
            if isNotification { return nil }
            return jsonrpcError(id: id, code: -32602, message: "Invalid params", data: err.message)
        } catch {
            if isNotification { return nil }
            return jsonrpcError(id: id, code: -32603, message: "Internal error", data: "\(error)")
        }
    }

    private func mcpInitialize(params: [String: Any]) throws -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let negotiated: String
        if let requested, Self.supportedMCPProtocolVersions.contains(requested) {
            negotiated = requested
        } else if requested == nil {
            negotiated = Self.supportedMCPProtocolVersions.first ?? "2025-06-18"
        } else {
            throw MCPToolError("unsupported_protocol_version: \(requested ?? "missing")")
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let serverInfo: [String: Any] = ["name": "AnemllAgentHost", "version": version]
        let capabilities: [String: Any] = [
            "tools": ["listChanged": false]
        ]

        return [
            "protocolVersion": negotiated,
            "capabilities": capabilities,
            "serverInfo": serverInfo,
            "instructions": "Local macOS UI automation tools (screenshot, window capture, click, type) over localhost."
        ]
    }

    private func mcpToolsList() -> [[String: Any]] {
        // Minimal, stable tool surface. Names are prefixed to avoid collisions in multi-server clients.
        return [
            [
                "name": "anemll_screenshot",
                "description": "Take a full-screen screenshot. Writes /tmp/anemll_last.png and can optionally return base64 PNG.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "cursor": ["type": "boolean", "default": true],
                        "return_base64": ["type": "boolean", "default": false],
                        "save_to_file": ["type": "boolean", "description": "Write /tmp/anemll_last.png. Defaults to false for inline images."],
                        "max_dimension": [
                            "anyOf": [
                                ["type": "integer"],
                                ["type": "string"]
                            ],
                            "description": "0 or \"full\" for no resize; \"playwright\"(1120), \"safe\"(2000), \"max\"(8000), or an integer."
                        ],
                        "resize_mode": ["type": "string", "enum": ["scale", "crop"], "default": "scale"]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "anemll_mouse",
                "description": "Get current mouse position (screen points plus image pixel coords when available).",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false
                ]
            ],
            [
                "name": "anemll_windows",
                "description": "List visible windows and bounds.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "on_screen": ["type": "boolean", "default": true]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "anemll_capture",
                "description": "Capture a specific window by id/pid/app/title. Writes /tmp/anemll_window.png and can optionally return base64 PNG and/or OCR results.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "window_id": ["type": "integer"],
                        "pid": ["type": "integer"],
                        "app": ["type": "string"],
                        "title": ["type": "string"],
                        "cursor": ["type": "boolean", "default": true],
                        "return_base64": ["type": "boolean", "default": false],
                        "save_to_file": ["type": "boolean", "description": "Write /tmp/anemll_window.png. Defaults to false for inline images."],
                        "ocr": ["type": "boolean", "default": false],
                        "max_dimension": [
                            "anyOf": [
                                ["type": "integer"],
                                ["type": "string"]
                            ],
                            "description": "0 for no resize; \"playwright\"(1120), \"safe\"(2000), \"max\"(8000), or an integer."
                        ],
                        "resize_mode": ["type": "string", "enum": ["crop", "scale"], "default": "crop"]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "anemll_click",
                "description": "Click at screen coordinates.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "space": ["type": "string", "enum": ["screen_points", "image_pixels"], "default": "screen_points"]
                    ],
                    "required": ["x", "y"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "anemll_double_click",
                "description": "Double-click at screen coordinates.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "space": ["type": "string", "enum": ["screen_points", "image_pixels"], "default": "screen_points"]
                    ],
                    "required": ["x", "y"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "anemll_right_click",
                "description": "Right-click at screen coordinates.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "space": ["type": "string", "enum": ["screen_points", "image_pixels"], "default": "screen_points"]
                    ],
                    "required": ["x", "y"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "anemll_move",
                "description": "Move mouse to screen coordinates.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "space": ["type": "string", "enum": ["screen_points", "image_pixels"], "default": "screen_points"]
                    ],
                    "required": ["x", "y"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "anemll_scroll",
                "description": "Scroll by dx/dy (pixels). Optional x/y moves cursor first.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "dx": ["type": "number", "default": 0],
                        "dy": ["type": "number"],
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "space": ["type": "string", "enum": ["screen_points", "image_pixels"], "default": "screen_points"]
                    ],
                    "required": ["dy"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "anemll_type",
                "description": "Type text into the currently focused control.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "maxLength": AutomationLimits.maximumTextCharacters]
                    ],
                    "required": ["text"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "anemll_focus_window",
                "description": "Move cursor to a window (optionally to an offset in window points).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "window_id": ["type": "integer"],
                        "pid": ["type": "integer"],
                        "app": ["type": "string"],
                        "title": ["type": "string"],
                        "offset_x": ["type": "number"],
                        "offset_y": ["type": "number"]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "anemll_click_window",
                "description": "Click inside a window (optionally at an offset in window points).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "window_id": ["type": "integer"],
                        "pid": ["type": "integer"],
                        "app": ["type": "string"],
                        "title": ["type": "string"],
                        "offset_x": ["type": "number"],
                        "offset_y": ["type": "number"]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "anemll_scroll_window",
                "description": "Scroll inside a window by dx/dy (pixels), optionally at an offset in window points.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "window_id": ["type": "integer"],
                        "pid": ["type": "integer"],
                        "app": ["type": "string"],
                        "title": ["type": "string"],
                        "offset_x": ["type": "number"],
                        "offset_y": ["type": "number"],
                        "dx": ["type": "number", "default": 0],
                        "dy": ["type": "number", "default": 0]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "anemll_paste",
                "description": "Paste text into the focused control in one operation. Faster than typing long text and restores the previous plain-text clipboard.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["text": ["type": "string", "maxLength": AutomationLimits.maximumTextCharacters]],
                    "required": ["text"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "anemll_hotkey",
                "description": "Press a keyboard shortcut such as command+shift+p.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "keys": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 6],
                        "shortcut": ["type": "string", "description": "Plus-separated alternative to keys."]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "anemll_drag",
                "description": "Drag from one point to another using screen-point or image-pixel coordinates.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "from_x": ["type": "number"], "from_y": ["type": "number"],
                        "to_x": ["type": "number"], "to_y": ["type": "number"],
                        "space": ["type": "string", "enum": ["screen_points", "image_pixels"], "default": "screen_points"],
                        "duration_ms": ["type": "integer", "minimum": 50, "maximum": 10000, "default": 350]
                    ],
                    "required": ["from_x", "from_y", "to_x", "to_y"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "anemll_activate",
                "description": "Bring a running application and all its windows to the foreground by app name or bundle id.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["app": ["type": "string"]],
                    "required": ["app"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "anemll_accessibility_tree",
                "description": "Return a compact text accessibility tree for a running app. Prefer this for no-image models and precise element discovery.",
                "inputSchema": accessibilityQuerySchema(includeAction: false)
            ],
            [
                "name": "anemll_accessibility_action",
                "description": "Find an accessibility element by role/title/identifier and press, focus, or set its value.",
                "inputSchema": accessibilityQuerySchema(includeAction: true)
            ],
            [
                "name": "anemll_accessibility_wait",
                "description": "Wait until a matching accessibility element exists or disappears, avoiding fixed sleeps.",
                "inputSchema": accessibilityWaitSchema()
            ],
            [
                "name": "anemll_batch",
                "description": "Execute up to 50 compact input and accessibility actions in one request to reduce model/tool round trips.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "actions": [
                            "type": "array",
                            "items": ["type": "object"],
                            "minItems": 1,
                            "maxItems": AutomationLimits.maximumBatchActions
                        ]
                    ],
                    "required": ["actions"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "anemll_burst",
                "description": "Capture multiple frames rapidly (optionally from a window). Writes /tmp/anemll_burst_*.png.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "window_id": ["type": "integer"],
                        "pid": ["type": "integer"],
                        "app": ["type": "string"],
                        "title": ["type": "string"],
                        "count": ["type": "integer", "minimum": 1, "maximum": AutomationLimits.maximumBurstFrames, "default": 10],
                        "interval_ms": ["type": "integer", "minimum": AutomationLimits.minimumBurstIntervalMs, "maximum": AutomationLimits.maximumBurstIntervalMs, "default": 100],
                        "max_dimension": [
                            "anyOf": [
                                ["type": "integer"],
                                ["type": "string"]
                            ]
                        ],
                        "resize_mode": ["type": "string", "enum": ["crop", "scale"], "default": "crop"]
                    ],
                    "additionalProperties": false
                ]
            ]
        ]
    }

    private func accessibilityQuerySchema(includeAction: Bool) -> [String: Any] {
        var properties: [String: Any] = [
            "pid": ["type": "integer"],
            "app": ["type": "string", "description": "Running app name or bundle id (required if pid is omitted)."],
            "role": ["type": "string", "description": "Case-insensitive role substring, e.g. AXButton."],
            "title": ["type": "string", "description": "Case-insensitive title, label, or value substring."],
            "identifier": ["type": "string", "description": "Case-insensitive accessibility identifier substring."],
            "max_depth": ["type": "integer", "minimum": 0, "maximum": AutomationLimits.maximumAccessibilityDepth, "default": 8],
            "max_elements": ["type": "integer", "minimum": 1, "maximum": AutomationLimits.maximumAccessibilityElements, "default": 500]
        ]
        var required: [String] = []
        if includeAction {
            properties["action"] = [
                "type": "string",
                "enum": ["press", "click", "confirm", "cancel", "increment", "decrement", "show_menu", "focus", "set_value"]
            ]
            properties["value"] = ["type": "string", "description": "Required for set_value."]
            required.append("action")
        }
        return [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false
        ]
    }

    private func accessibilityWaitSchema() -> [String: Any] {
        var schema = accessibilityQuerySchema(includeAction: false)
        var properties = schema["properties"] as? [String: Any] ?? [:]
        properties["state"] = ["type": "string", "enum": ["exists", "gone"], "default": "exists"]
        properties["timeout_ms"] = ["type": "integer", "minimum": 0, "maximum": AutomationLimits.maximumWaitMs, "default": 5000]
        properties["poll_ms"] = ["type": "integer", "minimum": 25, "maximum": 5000, "default": 100]
        schema["properties"] = properties
        return schema
    }

    private func mcpToolsCall(params: [String: Any]) async throws -> [String: Any] {
        guard let toolName = params["name"] as? String else {
            throw MCPToolError("missing_tool_name")
        }
        let arguments = (params["arguments"] as? [String: Any]) ?? (params["args"] as? [String: Any]) ?? [:]

        switch toolName {
        case "anemll_screenshot":
            let includeCursor = (arguments["cursor"] as? Bool) ?? true
            let returnBase64 = (arguments["return_base64"] as? Bool) ?? false
            let saveToFile = (arguments["save_to_file"] as? Bool) ?? !returnBase64
            let maxDimension = parseMaxDimension(arguments["max_dimension"], defaultValue: ScreenAndInput.defaultMaxDimension)
            let resizeMode = parseResizeMode(arguments["resize_mode"], defaultValue: .scale)
            guard (try? AutomationLimits.validatedMaxDimension(maxDimension)) != nil else {
                throw MCPToolError("max_dimension must be between 0 and 8000")
            }

            let info = try await ScreenAndInput.takeScreenshot(
                path: saveToFile ? "/tmp/anemll_last.png" : nil,
                includeCursor: includeCursor,
                maxDimension: maxDimension,
                resizeMode: resizeMode,
                returnBase64: returnBase64
            )
            return mcpToolResult(from: info)

        case "anemll_mouse":
            guard let pt = ScreenAndInput.mouseLocation() else {
                return mcpToolErrorResult("mouse_unavailable")
            }
            var payload: [String: Any] = ["x": Double(pt.x), "y": Double(pt.y), "space": "screen_points"]
            if let imagePt = ScreenAndInput.imageLocation(fromScreen: pt) {
                payload["image_x"] = Double(imagePt.x)
                payload["image_y"] = Double(imagePt.y)
                payload["image_space"] = "image_pixels"
            }
            return mcpToolResult(from: payload)

        case "anemll_windows":
            let onScreenOnly = (arguments["on_screen"] as? Bool) ?? true
            let windows = ScreenAndInput.listWindows(onScreenOnly: onScreenOnly)
            return mcpToolResult(from: ["ok": true, "count": windows.count, "windows": windows])

        case "anemll_capture":
            let windowID = intValue(arguments["window_id"]).map { CGWindowID($0) }
            let pid = intValue(arguments["pid"]).map { pid_t($0) }
            let app = arguments["app"] as? String
            let title = arguments["title"] as? String

            if windowID == nil && pid == nil && app == nil && title == nil {
                throw MCPToolError("expected at least one of: window_id, pid, app, title")
            }

            let includeCursor = (arguments["cursor"] as? Bool) ?? true
            let returnBase64 = (arguments["return_base64"] as? Bool) ?? false
            let saveToFile = (arguments["save_to_file"] as? Bool) ?? !returnBase64
            let runOCR = (arguments["ocr"] as? Bool) ?? false
            let maxDimension = parseMaxDimension(arguments["max_dimension"], defaultValue: 0)
            let resizeMode = parseResizeMode(arguments["resize_mode"], defaultValue: .crop)
            guard (try? AutomationLimits.validatedMaxDimension(maxDimension)) != nil else {
                throw MCPToolError("max_dimension must be between 0 and 8000")
            }

            let info = try await ScreenAndInput.captureWindow(
                windowID: windowID,
                pid: pid,
                app: app,
                title: title,
                path: saveToFile ? "/tmp/anemll_window.png" : nil,
                includeCursor: includeCursor,
                maxDimension: maxDimension,
                resizeMode: resizeMode,
                returnBase64: returnBase64,
                runOCR: runOCR
            )
            return mcpToolResult(from: info)

        case "anemll_click":
            let (x, y, space) = try parseXY(arguments)
            let ok = ScreenAndInput.click(x: x, y: y, space: space)
            return mcpToolResult(from: ["ok": ok])

        case "anemll_double_click":
            let (x, y, space) = try parseXY(arguments)
            let ok = ScreenAndInput.doubleClick(x: x, y: y, space: space)
            return mcpToolResult(from: ["ok": ok])

        case "anemll_right_click":
            let (x, y, space) = try parseXY(arguments)
            let ok = ScreenAndInput.rightClick(x: x, y: y, space: space)
            return mcpToolResult(from: ["ok": ok])

        case "anemll_move":
            let (x, y, space) = try parseXY(arguments)
            let ok = ScreenAndInput.move(x: x, y: y, space: space)
            return mcpToolResult(from: ["ok": ok])

        case "anemll_scroll":
            let dx = doubleValue(arguments["dx"]) ?? 0
            let dy = doubleValue(arguments["dy"]) ?? 0
            if dx == 0 && dy == 0 {
                throw MCPToolError("expected non-zero dx or dy")
            }
            if let x = doubleValue(arguments["x"]), let y = doubleValue(arguments["y"]) {
                let space = ScreenAndInput.CoordinateSpace.parse(arguments["space"])
                _ = ScreenAndInput.move(x: x, y: y, space: space)
            }
            let ok = ScreenAndInput.scroll(dx: dx, dy: dy, isContinuous: true)
            return mcpToolResult(from: ["ok": ok, "dx": dx, "dy": dy])

        case "anemll_type":
            guard let text = arguments["text"] as? String else { throw MCPToolError("expected {text}") }
            do {
                try AutomationLimits.validateText(text)
            } catch {
                throw MCPToolError(error.localizedDescription)
            }
            let ok = ScreenAndInput.type(text: text)
            return mcpToolResult(from: ["ok": ok])

        case "anemll_paste":
            guard let text = arguments["text"] as? String else { throw MCPToolError("expected {text}") }
            do { try AutomationLimits.validateText(text) } catch { throw MCPToolError(error.localizedDescription) }
            let ok = await ScreenAndInput.paste(text: text)
            return mcpToolResult(from: ["ok": ok, "characters": text.count])

        case "anemll_hotkey":
            guard let keys = parseKeys(arguments["keys"] ?? arguments["shortcut"]), !keys.isEmpty else {
                throw MCPToolError("expected {keys:[...]} or {shortcut:'command+v'}")
            }
            let ok = ScreenAndInput.hotkey(keys: keys)
            return ok ? mcpToolResult(from: ["ok": true, "keys": keys]) : mcpToolErrorResult("invalid_or_failed_hotkey")

        case "anemll_drag":
            guard let fromX = doubleValue(arguments["from_x"]), let fromY = doubleValue(arguments["from_y"]),
                  let toX = doubleValue(arguments["to_x"]), let toY = doubleValue(arguments["to_y"])
            else { throw MCPToolError("expected {from_x,from_y,to_x,to_y}") }
            let durationMs = intValue(arguments["duration_ms"]) ?? 350
            guard (50...10_000).contains(durationMs) else { throw MCPToolError("duration_ms must be between 50 and 10000") }
            let ok = await ScreenAndInput.drag(
                fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                space: .parse(arguments["space"]), durationMs: durationMs
            )
            return ok ? mcpToolResult(from: ["ok": true]) : mcpToolErrorResult("drag_failed")

        case "anemll_activate":
            guard let app = arguments["app"] as? String else { throw MCPToolError("expected {app}") }
            guard let activation = await ScreenAndInput.activate(app: app), activation.ok else {
                return mcpToolErrorResult("application_not_found")
            }
            return mcpToolResult(from: activation.dictionary)

        case "anemll_accessibility_tree":
            do {
                return mcpToolResult(from: try AccessibilityAutomation.snapshot(query: parseAccessibilityQuery(arguments)))
            } catch {
                return mcpToolErrorResult(error.localizedDescription)
            }

        case "anemll_accessibility_action":
            guard let action = arguments["action"] as? String else { throw MCPToolError("expected {action}") }
            do {
                let info = try AccessibilityAutomation.perform(
                    query: parseAccessibilityQuery(arguments),
                    action: action,
                    value: arguments["value"] as? String
                )
                return mcpToolResult(from: info)
            } catch {
                return mcpToolErrorResult(error.localizedDescription)
            }

        case "anemll_accessibility_wait":
            do {
                return mcpToolResult(from: try await waitForAccessibility(arguments: arguments))
            } catch {
                return mcpToolErrorResult(error.localizedDescription)
            }

        case "anemll_batch":
            guard let actions = arguments["actions"] as? [[String: Any]] else {
                throw MCPToolError("expected {actions:[...]}")
            }
            do {
                return mcpToolResult(from: try await executeBatch(actions))
            } catch {
                return mcpToolErrorResult(error.localizedDescription)
            }

        case "anemll_focus_window":
            let (windowID, pid, app, title) = parseWindowTarget(arguments)
            if windowID == nil && pid == nil && app == nil && title == nil {
                throw MCPToolError("expected at least one of: window_id, pid, app, title")
            }
            let offsetX = doubleValue(arguments["offset_x"])
            let offsetY = doubleValue(arguments["offset_y"])
            let info = try ScreenAndInput.moveCursorToWindow(
                windowID: windowID,
                pid: pid,
                app: app,
                title: title,
                offsetX: offsetX,
                offsetY: offsetY
            )
            return mcpToolResult(from: info)

        case "anemll_click_window":
            let (windowID, pid, app, title) = parseWindowTarget(arguments)
            if windowID == nil && pid == nil && app == nil && title == nil {
                throw MCPToolError("expected at least one of: window_id, pid, app, title")
            }
            let offsetX = doubleValue(arguments["offset_x"])
            let offsetY = doubleValue(arguments["offset_y"])
            let info = try ScreenAndInput.clickInWindow(
                windowID: windowID,
                pid: pid,
                app: app,
                title: title,
                offsetX: offsetX,
                offsetY: offsetY
            )
            return mcpToolResult(from: info)

        case "anemll_scroll_window":
            let (windowID, pid, app, title) = parseWindowTarget(arguments)
            if windowID == nil && pid == nil && app == nil && title == nil {
                throw MCPToolError("expected at least one of: window_id, pid, app, title")
            }
            let dx = doubleValue(arguments["dx"]) ?? 0
            let dy = doubleValue(arguments["dy"]) ?? 0
            if dx == 0 && dy == 0 {
                throw MCPToolError("expected non-zero dx or dy")
            }
            let offsetX = doubleValue(arguments["offset_x"])
            let offsetY = doubleValue(arguments["offset_y"])
            var info = try ScreenAndInput.moveCursorToWindow(
                windowID: windowID,
                pid: pid,
                app: app,
                title: title,
                offsetX: offsetX,
                offsetY: offsetY
            )
            let ok = ScreenAndInput.scroll(dx: dx, dy: dy, isContinuous: true)
            info["ok"] = ok
            info["dx"] = dx
            info["dy"] = dy
            return mcpToolResult(from: info)

        case "anemll_burst":
            let windowID = intValue(arguments["window_id"]).map { CGWindowID($0) }
            let pid = intValue(arguments["pid"]).map { pid_t($0) }
            let app = arguments["app"] as? String
            let title = arguments["title"] as? String

            let count = intValue(arguments["count"]) ?? 10
            let intervalMs = intValue(arguments["interval_ms"]) ?? 100
            let burstParameters: (count: Int, intervalMs: Int)
            do {
                burstParameters = try AutomationLimits.validatedBurst(count: count, intervalMs: intervalMs)
            } catch {
                throw MCPToolError(error.localizedDescription)
            }

            let maxDimension = parseMaxDimension(arguments["max_dimension"], defaultValue: 0)
            let resizeMode = parseResizeMode(arguments["resize_mode"], defaultValue: .crop)
            guard (try? AutomationLimits.validatedMaxDimension(maxDimension)) != nil else {
                throw MCPToolError("max_dimension must be between 0 and 8000")
            }

            let info = try await ScreenAndInput.burstCapture(
                windowID: windowID,
                pid: pid,
                app: app,
                title: title,
                count: burstParameters.count,
                intervalMs: burstParameters.intervalMs,
                maxDimension: maxDimension,
                resizeMode: resizeMode
            )
            return mcpToolResult(from: info)

        default:
            throw MCPToolError("unknown_tool: \(toolName)")
        }
    }

    private func mcpToolResult(from info: [String: Any]) -> [String: Any] {
        var content: [[String: Any]] = []

        var textInfo = info
        let maybeBase64 = textInfo.removeValue(forKey: "image_base64") as? String

        if let json = jsonString(textInfo) {
            content.append(["type": "text", "text": json])
        } else {
            content.append(["type": "text", "text": "\(textInfo)"])
        }

        if let base64 = maybeBase64 {
            content.append(["type": "image", "data": base64, "mimeType": "image/png"])
        }

        return ["content": content]
    }

    private func mcpToolErrorResult(_ message: String) -> [String: Any] {
        return [
            "isError": true,
            "content": [
                ["type": "text", "text": message]
            ]
        ]
    }

    private func jsonString(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    private func jsonrpcResult(id: Any?, result: Any) -> [String: Any] {
        var resp: [String: Any] = ["jsonrpc": "2.0", "result": result]
        resp["id"] = id ?? NSNull()
        return resp
    }

    private func jsonrpcError(id: Any?, code: Int, message: String, data: Any? = nil) -> [String: Any] {
        var err: [String: Any] = ["code": code, "message": message]
        if let data { err["data"] = data }
        var resp: [String: Any] = ["jsonrpc": "2.0", "error": err]
        resp["id"] = id ?? NSNull()
        return resp
    }

    private func parseMaxDimension(_ raw: Any?, defaultValue: Int) -> Int {
        guard let raw else { return defaultValue }
        if let intVal = raw as? Int { return intVal }
        if let dblVal = raw as? Double { return Int(dblVal) }
        if let strVal = raw as? String {
            switch strVal.lowercased() {
            case "playwright", "default", "claude", "claudecode", "optimal", "recommended":
                return ScreenAndInput.defaultMaxDimension
            case "safe", "2000":
                return ScreenAndInput.safeMaxDimension
            case "max", "hard", "limit":
                return ScreenAndInput.hardMaxDimension
            case "full", "none", "0":
                return 0
            default:
                return Int(strVal) ?? defaultValue
            }
        }
        return defaultValue
    }

    private func parseResizeMode(_ raw: Any?, defaultValue: ScreenAndInput.ResizeMode) -> ScreenAndInput.ResizeMode {
        guard let s = raw as? String else { return defaultValue }
        switch s.lowercased() {
        case "crop":
            return .crop
        case "scale":
            return .scale
        default:
            return defaultValue
        }
    }

    private func parseXY(_ args: [String: Any]) throws -> (Double, Double, ScreenAndInput.CoordinateSpace) {
        guard let x = doubleValue(args["x"]), let y = doubleValue(args["y"]) else {
            throw MCPToolError("expected {x,y}")
        }
        let space = ScreenAndInput.CoordinateSpace.parse(args["space"])
        return (x, y, space)
    }

    private func parseWindowTarget(_ args: [String: Any]) -> (CGWindowID?, pid_t?, String?, String?) {
        let windowID = intValue(args["window_id"]).map { CGWindowID($0) }
        let pid = intValue(args["pid"]).map { pid_t($0) }
        let app = args["app"] as? String
        let title = args["title"] as? String
        return (windowID, pid, app, title)
    }

    private func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    private func doubleValue(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    private struct MCPToolError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
