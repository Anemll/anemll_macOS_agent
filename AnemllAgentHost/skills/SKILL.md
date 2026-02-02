---
name: anemll-macos-agent
description: Control macOS UI via AnemllAgentHost HTTP API for automated testing, screen capture, and UI interaction. Use when you need to take screenshots, click UI elements, type text, or control specific application windows on macOS. Provides both full-screen and window-based automation commands. Do not use for tasks that don't require GUI interaction.
---

# ANEMLL macOS Agent (UI Automation via HTTP)

## What this skill is for
Automate macOS UI interactions via the AnemllAgentHost localhost HTTP API. Enables screenshot capture, mouse clicks, keyboard input, and window-specific operations for testing, QC, and verification tasks.

## When to use / when not to use
Use when:
- Taking screenshots of the macOS desktop or specific application windows
- Clicking UI elements by coordinates (screen or window-relative)
- Typing text into focused controls
- Automating UI testing workflows
- Controlling iPhone Mirroring or other apps via mouse/keyboard
- Performing QC verification by visual inspection

Do not use when:
- Task doesn't require GUI interaction
- You need to modify files or run shell commands (use standard tools instead)
- Target machine is not running AnemllAgentHost

## Preconditions
1. AnemllAgentHost is running (menu bar icon visible)
2. Screen Recording permission: Allowed (green)
3. Accessibility permission: Allowed (green)
4. Server is running (green indicator, port 8765)
5. You have the Bearer token from the app UI

## Environment setup (one-time per shell)

```bash
export ANEMLL_HOST="http://127.0.0.1:8765"
export ANEMLL_TOKEN="PASTE_TOKEN_FROM_MENU_APP"
```

**Important**: The HTTP server is localhost only. Commands must run on the same Mac that is running AnemllAgentHost.

## API Reference

### Health check
```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" "$ANEMLL_HOST/health"
```
Response: `{"ok":true,"version":"0.1.4"}`

### Screenshot (full screen)
Saves to `/tmp/anemll_last.png`
```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -X POST "$ANEMLL_HOST/screenshot"
```

With cursor overlay disabled:
```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/screenshot" -d '{"cursor":false}'
```

### Click at coordinates
```bash
# Screen points (origin bottom-left)
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/click" -d '{"x":960,"y":540}'

# Image pixels from screenshot (origin top-left)
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/click" -d '{"x":1920,"y":1080,"space":"image_pixels"}'
```

### Type text
```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/type" -d '{"text":"Hello from Claude"}'
```

### Move mouse
```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/move" -d '{"x":960,"y":540}'
```

### Get mouse position
```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" "$ANEMLL_HOST/mouse"
```

## Window-Based Commands (Recommended)

Window-based commands are **faster and more precise** than full-screen operations.

### List all windows
```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" "$ANEMLL_HOST/windows" | python3 -m json.tool
```

Response fields per window:
- `id` - Window ID (use for precise targeting)
- `app` - Application name
- `title` - Window title
- `pid` - Process ID
- `bounds` - `{x, y, w, h}` in screen points
- `layer` - Window layer (0 = normal app)
- `on_screen` - Visibility flag

### Capture specific window
Saves to `/tmp/anemll_window.png`

**Claude Code image limits:**
- **1120 pixels** - Playwright MCP target (most reliable)
- **2000 pixels** - safe for many-image sessions
- **8000 pixels** - hard API limit

```bash
# Basic capture
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/capture" -d '{"app": "Safari"}'

# With auto-crop for Claude Code (RECOMMENDED)
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/capture" -d '{"app": "Safari", "max_dimension": "playwright"}'

# By window title
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/capture" -d '{"title": "iPhone Mirroring", "max_dimension": 1120}'
```

**`max_dimension` options:**
| Value | Pixels | Use case |
|-------|--------|----------|
| `"playwright"` | 1120 | **Recommended** for Claude Code |
| `"safe"` | 2000 | Safe for many images |
| `1500` (int) | 1500 | Custom value |
| `0` (default) | none | No cropping |

**`resize_mode` options:**
- `"crop"` (default) - Cursor-aware cropping, preserves pixel accuracy
- `"scale"` - Proportional scaling, loses pixel accuracy

### Base64 Image Response (v0.1.4+)
Get image data directly in JSON response instead of reading from file:
```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/capture" -d '{"app": "Safari", "return_base64": true}'
```

Response includes `"image_base64": "iVBORw0KGgo..."` - decode with `base64 -d`.
**Benefit:** Eliminates file read step, faster automation loop.

### OCR Text Detection (v0.1.4+)
Detect text and get bounding boxes without visual analysis:
```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/capture" -d '{"app": "Safari", "ocr": true}'
```

Response includes:
```json
{
  "ocr": [
    {"text": "Download", "x": 250, "y": 300, "w": 80, "h": 24, "confidence": 0.95},
    {"text": "Cancel", "x": 250, "y": 340, "w": 60, "h": 24, "confidence": 0.92}
  ],
  "ocr_count": 2
}
```

**Click by text:** Find element in OCR array, click at center: `x + w/2, y + h/2`
**Combine with base64:** `{"app": "...", "ocr": true, "return_base64": true}`

**Cursor positioning for reliable overlay:**
The red cursor dot overlay only shows when cursor is inside the window. Use `/focus` to move cursor before capture:
```bash
# Move cursor to specific position in window, then capture
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/focus" -d '{"app": "Safari", "offset_x": 200, "offset_y": 150}'
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/capture" -d '{"app": "Safari", "max_dimension": "playwright"}'
```

**Cursor-aware cropping:** When cropping, the visible region is centered on the cursor position. If cursor is in top-left, keeps top-left. Move cursor to area of interest before capture.

**Response with cropping:**
```json
{"ok":true, "w":1120, "h":900, "resized":true, "resize_mode":"crop",
 "original_w":2688, "original_h":1800, "trim_x":784, "trim_y":450}
```

**Important:** Use `trim_x`/`trim_y` to adjust click coordinates. If button at (500, 200) in cropped image and `trim_x=784`, actual coordinate is (500+784, 200) = (1284, 200).

### Click inside window
Click relative to window's top-left corner (no global coordinate calculation needed)
```bash
# Click center of window (default)
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/click_window" -d '{"title": "iPhone Mirroring"}'

# Click at offset from window's top-left (in points)
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/click_window" -d '{"app": "Safari", "offset_x": 100, "offset_y": 50}'
```

**Coordinate conversion from capture response:**
```json
{"w": 652, "h": 1440, "bounds": {"w": 326, "h": 720, ...}}
```
- `w`, `h` = image pixels
- `bounds.w`, `bounds.h` = window points
- **Scale factor** = `w / bounds.w` (e.g., 652/326 = 2x retina)
- **Click offset** = `pixel_position / scale`

**Example**: Button visible at pixel (500, 300) in a 2x retina capture:
```
scale = image_w / bounds_w = 652 / 326 = 2
offset_x = 500 / 2 = 250
offset_y = 300 / 2 = 150
```
Then click: `{"title": "...", "offset_x": 250, "offset_y": 150}`

**For 1x windows** (w == bounds.w): pixel coordinates = point offsets directly.

### Move cursor to window position
```bash
# Move to center
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/focus" -d '{"app": "Safari"}'

# Move to specific offset
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/focus" -d '{"title": "iPhone Mirroring", "offset_x": 163, "offset_y": 200}'
```

### Window targeting priority
When multiple identifiers are provided: `window_id` > `pid` > `app` > `title`

### Burst capture (rapid image sequences)
Capture multiple frames for animation/video analysis or detecting UI transitions.

```bash
# 10 frames at 100ms intervals from a window
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/burst" -d '{"app": "iPhone Mirroring", "count": 10, "interval_ms": 100}'

# Full-screen burst with auto-crop
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/burst" -d '{"count": 5, "interval_ms": 200, "max_dimension": "playwright"}'
```

**Parameters:** `count` (max 100), `interval_ms` (min 10), `max_dimension`, `resize_mode`

**Response:**
```json
{"ok":true, "count":10, "fps":9.75, "duration_ms":923,
 "frames":[{"frame":0, "path":"/tmp/anemll_burst_0.png", "w":1120, "h":900, "ts":...}, ...]}
```

## Recommended Automation Workflow

### For controlling a specific app (e.g., iPhone Mirroring):
```bash
# 1) List windows to find target
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" "$ANEMLL_HOST/windows" | python3 -m json.tool

# 2) Capture target window
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/capture" -d '{"title": "iPhone Mirroring"}'

# 3) Read and analyze /tmp/anemll_window.png to find UI elements

# 4) Click inside window using relative coordinates (image pixels / 2)
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/click_window" -d '{"title": "iPhone Mirroring", "offset_x": 163, "offset_y": 125}'

# 5) Capture again to verify result
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/capture" -d '{"title": "iPhone Mirroring"}'
```

### Full-screen automation loop:
```bash
# 1) Screenshot
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -X POST "$ANEMLL_HOST/screenshot"

# 2) Analyze /tmp/anemll_last.png

# 3) Action (click, type, etc.)
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/click" -d '{"x":200,"y":150}'

# 4) Screenshot again to confirm
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -X POST "$ANEMLL_HOST/screenshot"
```

## Debug Viewer (v0.1.4+)

View captures in browser with auto-refresh (useful for SSH debugging):
```
http://127.0.0.1:8765/debug
```

**For SSH access:** Forward port first:
```bash
ssh -L 8765:localhost:8765 user@mac
# Then open http://localhost:8765/debug in local browser
```

Shows last `/capture` image, auto-refreshes every 2 seconds. Requires auth token.

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| Exit code 7 / Connection refused | Server not running OR sandbox blocking localhost | Start server from menu bar; if running, retry with `dangerouslyDisableSandbox: true` |
| `{"error":"unauthorized"}` | Token mismatch | Get current token from app UI, re-export `ANEMLL_TOKEN` |
| `screenCaptureNotAllowed` | Missing permission | System Settings → Privacy → Screen Recording → enable AnemllAgentHost |
| Click/type does nothing | Accessibility missing | System Settings → Privacy → Accessibility → enable AnemllAgentHost |
| `window_not_found` | Window closed or wrong filter | Use `/windows` to verify target exists |

### Verify server is listening
```bash
lsof -nP -iTCP:8765 -sTCP:LISTEN
```
Expected: `AnemllAgentHost` is the listening process.

## Safety Constraints (Claude must follow)

- Only interact with apps/windows you explicitly intend to test
- Prefer small, reversible actions
- After any action that changes state, immediately take a screenshot to confirm
- Do not type secrets into UI fields unless explicitly instructed
- When in doubt, capture and analyze before clicking

## Claude Code Permissions (avoid repeated prompts)

Add to `.claude/settings.local.json` under `permissions.allow`:
```json
[
  "Bash(export ANEMLL_HOST=*:*)",
  "Bash(export ANEMLL_TOKEN=*:*)",
  "Bash(curl -s -H \"Authorization: Bearer $ANEMLL_TOKEN\" \"$ANEMLL_HOST/health\")",
  "Bash(curl -s -H \"Authorization: Bearer $ANEMLL_TOKEN\" -X POST \"$ANEMLL_HOST/screenshot\"*)",
  "Bash(curl -s -H \"Authorization: Bearer $ANEMLL_TOKEN\" -H \"Content-Type: application/json\" -X POST \"$ANEMLL_HOST/click\" -d * )",
  "Bash(curl -s -H \"Authorization: Bearer $ANEMLL_TOKEN\" -H \"Content-Type: application/json\" -X POST \"$ANEMLL_HOST/type\" -d * )",
  "Bash(curl -s -H \"Authorization: Bearer $ANEMLL_TOKEN\" -H \"Content-Type: application/json\" -X POST \"$ANEMLL_HOST/move\" -d * )",
  "Bash(curl -s -H \"Authorization: Bearer $ANEMLL_TOKEN\" \"$ANEMLL_HOST/mouse\")",
  "Bash(curl -s -H \"Authorization: Bearer $ANEMLL_TOKEN\" \"$ANEMLL_HOST/windows\"*)",
  "Bash(curl -s -H \"Authorization: Bearer $ANEMLL_TOKEN\" -H \"Content-Type: application/json\" -X POST \"$ANEMLL_HOST/capture\" -d * )",
  "Bash(curl -s -H \"Authorization: Bearer $ANEMLL_TOKEN\" -H \"Content-Type: application/json\" -X POST \"$ANEMLL_HOST/click_window\" -d * )",
  "Bash(curl -s -H \"Authorization: Bearer $ANEMLL_TOKEN\" -H \"Content-Type: application/json\" -X POST \"$ANEMLL_HOST/focus\" -d * )"
]
```

## Sandbox Note

Claude Code's sandbox may block localhost connections. If curl commands fail with exit code 7 but the server is running, retry with `dangerouslyDisableSandbox: true`. This is safe for localhost-only APIs.

## Version assumptions
- AnemllAgentHost v0.1.4+
- macOS 14+ (for screen capture APIs)
- HTTP API on port 8765

## File locations
- Full-screen screenshot: `/tmp/anemll_last.png`
- Window capture: `/tmp/anemll_window.png`
- Documentation: `CLAUDE_INSTRUCTIONS.md` in project repo
