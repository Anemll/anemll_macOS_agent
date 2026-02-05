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
                    resizeMode: resizeMode
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

    static func html(_ status: Int, _ html: String) -> HTTPResponse {
        return HTTPResponse(status: status, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
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
