import Foundation
import Network
import CoreGraphics

final class LocalHTTPServer {
    enum ServerError: Error { case startFailed(String) }

    var onLog: ((String) -> Void)?
    var onState: ((NWListener.State) -> Void)?

    // Debug viewer state: sequence-based to avoid relying on filesystem mtime resolution.
    private static let debugCaptureLock = NSLock()
    private static var debugCaptureSeq: Int64 = 0
    private static var debugCaptureMs: Int64 = 0

    private static func bumpDebugCapture(nowMs: Int64? = nil) {
        let ms = nowMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        debugCaptureLock.lock()
        debugCaptureSeq += 1
        debugCaptureMs = max(debugCaptureMs, ms)
        debugCaptureLock.unlock()
    }

    private static func debugCaptureMeta(fileMtimeMs: Int64?) -> (seq: Int64, ms: Int64) {
        debugCaptureLock.lock()
        if let m = fileMtimeMs, m > debugCaptureMs {
            debugCaptureSeq += 1
            debugCaptureMs = m
        }
        let seq = debugCaptureSeq
        let ms = debugCaptureMs
        debugCaptureLock.unlock()
        return (seq, ms)
    }

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
            self?.onState?(state)
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

        // Auth - check header first, then URL query param (for browser access to debug endpoints)
        var authenticated = false

        if let auth = req.headers["authorization"] {
            let parts = auth.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                let token = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                authenticated = (token == bearerToken)
            }
        }

        // Allow token via URL query param for browser access (e.g., /debug?token=xxx)
        if !authenticated, let urlToken = req.queryParam("token") {
            authenticated = (urlToken == bearerToken)
        }

        guard authenticated else {
            onLog?("Unauthorized request")
            return .json(401, ["error": "unauthorized"])
        }

        switch (req.method, req.pathOnly) {
        case ("GET", "/health"):
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            return .json(200, ["ok": true, "version": version])

        case ("POST", "/mcp"):
            return routeMCP(req)

        case ("OPTIONS", "/mcp"):
            // Allow non-browser MCP clients that may probe endpoints.
            return HTTPResponse(status: 204, headers: [:], body: Data())

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

                let resizeMode: ScreenAndInput.ResizeMode
                if let modeStr = body["resize_mode"] as? String {
                    resizeMode = modeStr.lowercased() == "crop" ? .crop : .scale
                } else {
                    resizeMode = .scale
                }

                let info = try ScreenAndInput.takeScreenshot(
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
            let includeCursor = (body["cursor"] as? Bool) ?? true

            // New options for v0.1.4
            let returnBase64 = (body["return_base64"] as? Bool) ?? false
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
                let info = try ScreenAndInput.captureWindow(
                    windowID: windowID,
                    pid: pid,
                    app: app,
                    title: title,
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

            let resizeMode: ScreenAndInput.ResizeMode
            if let modeStr = body["resize_mode"] as? String {
                resizeMode = modeStr.lowercased() == "scale" ? .scale : .crop
            } else {
                resizeMode = .crop
            }

            do {
                let info = try ScreenAndInput.burstCapture(
                    windowID: windowID,
                    pid: pid,
                    app: app,
                    title: title,
                    count: min(count, 100),  // Cap at 100 frames
                    intervalMs: max(intervalMs, 10),  // Min 10ms interval
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
            // Access via: http://127.0.0.1:8765/debug?token=YOUR_TOKEN (browser-friendly)
            // For SSH tunnel: ssh -L 8765:localhost:8765 user@mac
            let urlToken = req.queryParam("token") ?? ""
            let tokenParam = urlToken.isEmpty ? "" : "token=\(urlToken)"
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
                    const tokenParam = "\(tokenParam)";
                    const metaUrl = tokenParam ? `/debug/meta?${tokenParam}` : "/debug/meta";
                    const imgBase = tokenParam ? `/debug/image?${tokenParam}&t=` : "/debug/image?t=";

                    async function poll() {
                        try {
                            const res = await fetch(metaUrl, { cache: "no-store" });
                            if (!res.ok) return;
                            const data = await res.json();
                            const seq = data.seq || 0;
                            const mtime = data.mtime_ms || 0;
                            if ((seq && seq !== lastSeq) || (!seq && mtime && mtime !== lastMtime)) {
                                lastSeq = seq;
                                lastMtime = mtime || Date.now();
                                const img = document.getElementById("capture");
                                img.src = imgBase + (mtime || lastMtime);
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
                let captureInfo = try ScreenAndInput.captureWindow(
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

    // MARK: - MCP (Model Context Protocol) JSON-RPC

    private static let supportedMCPProtocolVersions: [String] = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26"
    ]

    private func routeMCP(_ req: HTTPRequest) -> HTTPResponse {
        // Basic Origin validation (MCP recommends rejecting browser origins to prevent DNS rebinding).
        if let origin = req.headers["origin"], !isAllowedMCPOrigin(origin) {
            return .json(403, ["error": "forbidden", "detail": "origin_not_allowed"])
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
            if let response = handleMCPMessage(msg) {
                return HTTPResponse.jsonAny(200, response)
            }
            // Notification: no JSON-RPC response.
            return HTTPResponse(status: 202, headers: ["Content-Type": "application/json"], body: Data())
        }

        if let batch = payloadAny as? [Any] {
            var responses: [Any] = []
            for item in batch {
                guard let msg = item as? [String: Any] else {
                    responses.append(jsonrpcError(id: nil, code: -32600, message: "Invalid Request"))
                    continue
                }
                if let resp = handleMCPMessage(msg) {
                    responses.append(resp)
                }
            }

            if responses.isEmpty {
                return HTTPResponse(status: 202, headers: ["Content-Type": "application/json"], body: Data())
            }
            return HTTPResponse.jsonAny(200, responses)
        }

        return HTTPResponse.jsonAny(200, jsonrpcError(id: nil, code: -32600, message: "Invalid Request", data: "expected_object_or_array"))
    }

    private func isAllowedMCPOrigin(_ origin: String) -> Bool {
        let o = origin.lowercased()
        if o == "null" { return true }
        if o.hasPrefix("file://") { return true }
        // Only strictly validate browser-like origins (http/https). Non-http schemes are allowed.
        if o.hasPrefix("http://") || o.hasPrefix("https://") {
            if o.hasPrefix("http://127.0.0.1") { return true }
            if o.hasPrefix("http://localhost") { return true }
            if o.hasPrefix("https://127.0.0.1") { return true }
            if o.hasPrefix("https://localhost") { return true }
            return false
        }
        return true
    }

    private func handleMCPMessage(_ msg: [String: Any]) -> [String: Any]? {
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
                let result = try mcpToolsCall(params: params)
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
            throw MCPToolError("unsupported_protocol_version: \(requested)")
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
                        "text": ["type": "string"]
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
                "name": "anemll_burst",
                "description": "Capture multiple frames rapidly (optionally from a window). Writes /tmp/anemll_burst_*.png.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "window_id": ["type": "integer"],
                        "pid": ["type": "integer"],
                        "app": ["type": "string"],
                        "title": ["type": "string"],
                        "count": ["type": "integer", "default": 10],
                        "interval_ms": ["type": "integer", "default": 100],
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

    private func mcpToolsCall(params: [String: Any]) throws -> [String: Any] {
        guard let toolName = params["name"] as? String else {
            throw MCPToolError("missing_tool_name")
        }
        let arguments = (params["arguments"] as? [String: Any]) ?? (params["args"] as? [String: Any]) ?? [:]

        switch toolName {
        case "anemll_screenshot":
            let includeCursor = (arguments["cursor"] as? Bool) ?? true
            let returnBase64 = (arguments["return_base64"] as? Bool) ?? false
            let maxDimension = parseMaxDimension(arguments["max_dimension"], defaultValue: ScreenAndInput.defaultMaxDimension)
            let resizeMode = parseResizeMode(arguments["resize_mode"], defaultValue: .scale)

            let info = try ScreenAndInput.takeScreenshot(
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
            let runOCR = (arguments["ocr"] as? Bool) ?? false
            let maxDimension = parseMaxDimension(arguments["max_dimension"], defaultValue: 0)
            let resizeMode = parseResizeMode(arguments["resize_mode"], defaultValue: .crop)

            let info = try ScreenAndInput.captureWindow(
                windowID: windowID,
                pid: pid,
                app: app,
                title: title,
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
            let ok = ScreenAndInput.type(text: text)
            return mcpToolResult(from: ["ok": ok])

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

            let maxDimension = parseMaxDimension(arguments["max_dimension"], defaultValue: 0)
            let resizeMode = parseResizeMode(arguments["resize_mode"], defaultValue: .crop)

            let info = try ScreenAndInput.burstCapture(
                windowID: windowID,
                pid: pid,
                app: app,
                title: title,
                count: count,
                intervalMs: intervalMs,
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
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
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

    static func jsonAny(_ status: Int, _ obj: Any) -> HTTPResponse {
        let data: Data
        if JSONSerialization.isValidJSONObject(obj) {
            data = (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data()
        } else {
            data = Data()
        }
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    static func text(_ status: Int, _ text: String) -> HTTPResponse {
        return HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
    }

    static func html(_ status: Int, _ html: String) -> HTTPResponse {
        return HTTPResponse(status: status, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
    }
}

private func statusText(_ code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 202: return "Accepted"
    case 204: return "No Content"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    default: return "Error"
    }
}
