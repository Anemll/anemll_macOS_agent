# Claude Code/Codex Instructions

This document contains instructions for Claude Code agents to interact with the AnemllAgentHost UI automation server.

## Preconditions

1) The GUI app AnemllAgentHost is running in the logged-in macOS session (menu bar icon visible).
2) In the app UI, both are green:
   - Screen Recording: Allowed
   - Accessibility: Allowed
3) The server is running (UI shows Running) and listening on:
   - http://127.0.0.1:8765
4) You have the Bearer token from the app UI.

Important: The HTTP server is localhost only. Commands must run on the same Mac that is running AnemllAgentHost. If Claude is on another machine, SSH into the target Mac and run curl there.

Optional: Turn on "Show Cursor Overlay" in the menu app UI to draw a small red ring at the current cursor location. This makes the cursor visible in screenshots for alignment/debugging.

## Claude Code permissions (avoid repeated bash prompts)

If Claude Code keeps asking "Allow this bash command?", add a tight allowlist for the harness commands in `.claude/settings.local.json`. This keeps prompts limited to only the UI-automation calls.

Minimal allowlist (paste under `permissions.allow`):

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

If you prefer auto-allow when sandboxed, add this to your Claude settings and restart Claude Code:

```json
"sandbox": {
  "enabled": true,
  "autoAllowBashIfSandboxed": true
}
```

## Environment setup (one-time per shell)

```sh
export ANEMLL_HOST="http://127.0.0.1:8765"
export ANEMLL_TOKEN="PASTE_TOKEN_FROM_MENU_APP"

# sanity check
echo "HOST=$ANEMLL_HOST"
echo "TOKEN=[$ANEMLL_TOKEN]"
```

## 0) Verify you are on the right machine + server

```sh
hostname
lsof -nP -iTCP:8765 -sTCP:LISTEN
```

Expected: AnemllAgentHost is the process listening.

## 1) Health check

```sh
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  "$ANEMLL_HOST/health"
```

Expected:

```json
{"ok":true,"version":"0.1.2"}
```

If you get `{"error":"unauthorized"}` then the token in the shell does not match the token shown in the app UI (or you are on the wrong Mac).

## 2) Take a screenshot

This writes a PNG to `/tmp/anemll_last.png` and returns metadata JSON.

```sh
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -X POST "$ANEMLL_HOST/screenshot" | python -m json.tool

ls -l /tmp/anemll_last.png
```

By default, screenshots include a small red cursor ring. To disable it:

```sh
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/screenshot" \
  -d '{"cursor":false}' | python -m json.tool
```

Claude workflow: After calling `/screenshot`, read `/tmp/anemll_last.png` and decide the next action based on the UI state.

## 3) Click at coordinates (x,y)

```sh
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/click" \
  -d '{"x":960,"y":540}'
```

Notes:
- Default coordinates are global screen points (origin bottom-left).
- If you are using pixel coordinates from `/screenshot`, pass `"space":"image_pixels"` to convert from image pixels (origin top-left).

Example using screenshot pixel coordinates:

```sh
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/click" \
  -d '{"x":1920,"y":1080,"space":"image_pixels"}'
```

## 4) Type text into the currently focused control

```sh
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/type" \
  -d '{"text":"Hello from Claude Code"}'
```

## 5) Move mouse to coordinates (x,y)

```sh
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/move" \
  -d '{"x":960,"y":540}'
```

If you are moving using screenshot pixel coordinates, add `"space":"image_pixels"` like in the click example above.

## 6) Read current mouse position

```sh
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  "$ANEMLL_HOST/mouse"
```

The response includes screen-point coords and (when available) `image_x`/`image_y` in screenshot pixel space.

---

## Window-Based Commands (Recommended)

**Window-based commands are faster and more precise than full-screen operations.** When controlling specific applications, prefer these commands over full-screen screenshot + click workflows.

### 7) List all windows

Returns all visible windows with their IDs, app names, titles, PIDs, and bounds.

```sh
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  "$ANEMLL_HOST/windows" | python3 -m json.tool
```

To include off-screen windows:

```sh
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  "$ANEMLL_HOST/windows?on_screen=false"
```

Response fields per window:
- `id` - Window ID (use for precise targeting)
- `app` - Application name (e.g., "Safari", "iPhone Mirroring")
- `title` - Window title (may be empty for some windows)
- `pid` - Process ID
- `bounds` - `{x, y, w, h}` in screen points
- `layer` - Window layer (0 = normal app, higher = system UI)
- `alpha` - Opacity
- `on_screen` - Visibility flag

### 8) Capture a specific window

Captures just one window to `/tmp/anemll_window.png`. **Much faster than full-screen capture.**

**Image size limits for Claude Code:**
- **1120 pixels** - Playwright MCP target (~1.15MP) - most reliable
- **2000 pixels** - safe limit for sessions with many images (>20)
- **8000 pixels** - hard limit

Use `max_dimension` to auto-crop large windows (no scaling, preserves pixel accuracy):

```sh
# By app name (partial match, case-insensitive)
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/capture" \
  -d '{"app": "iPhone Mirroring"}' | python3 -m json.tool

# By window title
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/capture" \
  -d '{"title": "Safari"}'

# By window ID (from /windows response)
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/capture" \
  -d '{"window_id": 1138}'

# By PID
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/capture" \
  -d '{"pid": 82416}'

# Combine filters (app + title for precision)
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/capture" \
  -d '{"app": "Xcode", "title": "HostViewModel"}'

# With auto-trimming for Claude Code (recommended for automation)
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/capture" \
  -d '{"app": "Safari", "max_dimension": "safe"}'
```

**`max_dimension` values:**
| Value | Pixels | Use case |
|-------|--------|----------|
| `"playwright"` or `"claudecode"` | 1120 | **Recommended** - matches Playwright MCP |
| `"safe"` | 2000 | Safe for many-image sessions |
| `"max"` | 8000 | Hard API limit |
| `0` (default) | none | No cropping |
| `1500` (int) | 1500 | Custom value |

**Cursor-aware cropping:** When cropping is needed, the image is cropped (NOT scaled) to keep the cursor visible. Coordinates remain pixel-accurate. If cursor is in the top half, bottom is cropped; if in bottom half, top is cropped (same for left/right).

**Response with cropping:**
```json
{
  "ok": true,
  "w": 1120,
  "h": 900,
  "trimmed": true,
  "original_w": 2688,
  "original_h": 900,
  "trim_x": 784,
  "trim_y": 0
}
```

**Important:** Use `trim_x` and `trim_y` to adjust click coordinates when image was cropped. For example, if you identify a button at pixel (500, 200) in the cropped image and `trim_x` was 784, the actual window coordinate is (500 + 784, 200) = (1284, 200).

### 9) Click inside a specific window

Click at a position relative to a window's top-left corner. **No need to calculate global screen coordinates.**

```sh
# Click center of window (default if no offset provided)
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/click_window" \
  -d '{"title": "iPhone Mirroring"}'

# Click at specific offset from window's top-left (in points)
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/click_window" \
  -d '{"title": "iPhone Mirroring", "offset_x": 163, "offset_y": 125}'

# Click using app name + offset
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/click_window" \
  -d '{"app": "Safari", "offset_x": 100, "offset_y": 50}'
```

**Coordinate conversion**: Window capture images are at 2x retina scale. To convert image pixel coordinates to window point offsets, divide by 2.

Example: If you see a button at pixel (326, 250) in the captured image, click at `offset_x: 163, offset_y: 125`.

### 10) Move cursor to position inside a window

Move cursor without clicking. Useful for hover actions or preparing for drag operations.

```sh
# Move to center of window
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/focus" \
  -d '{"app": "Safari"}'

# Move to specific position within window
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/focus" \
  -d '{"title": "iPhone Mirroring", "offset_x": 163, "offset_y": 200}'
```

### 11) Burst capture (rapid image sequences)

Capture multiple frames rapidly for animation analysis, video scrubbing, or detecting UI transitions.

```sh
# Capture 10 frames at 100ms intervals (10 fps) from a window
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/burst" \
  -d '{"app": "iPhone Mirroring", "count": 10, "interval_ms": 100}'

# Full-screen burst capture (no window targeting)
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/burst" \
  -d '{"count": 5, "interval_ms": 200}'

# With auto-cropping for Claude Code
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/burst" \
  -d '{"app": "Safari", "count": 10, "interval_ms": 100, "max_dimension": "playwright"}'
```

**Parameters:**
| Parameter | Default | Description |
|-----------|---------|-------------|
| `count` | 10 | Number of frames (max 100) |
| `interval_ms` | 100 | Milliseconds between frames (min 10) |
| `max_dimension` | 0 | Auto-resize frames (see capture options) |
| `resize_mode` | "crop" | "crop" or "scale" |

**Response:**
```json
{
  "ok": true,
  "count": 10,
  "requested": 10,
  "interval_ms": 100,
  "duration_ms": 923,
  "fps": 9.75,
  "frames": [
    {"frame": 0, "path": "/tmp/anemll_burst_0.png", "w": 1120, "h": 900, "ts": 1738000000000},
    {"frame": 1, "path": "/tmp/anemll_burst_1.png", "w": 1120, "h": 900, "ts": 1738000000100},
    ...
  ]
}
```

---

### Window targeting options

All window commands (`/capture`, `/click_window`, `/focus`) accept these identifiers:

| Parameter | Description | Example |
|-----------|-------------|---------|
| `window_id` | Exact window ID from `/windows` | `{"window_id": 1138}` |
| `pid` | Process ID | `{"pid": 82416}` |
| `app` | App name (partial, case-insensitive) | `{"app": "Safari"}` |
| `title` | Window title (partial, case-insensitive) | `{"title": "iPhone Mirroring"}` |

You can combine filters for precision: `{"app": "Xcode", "title": "HostViewModel"}`

Priority when multiple are provided: `window_id` > `pid` > `app` > `title`

---

### Recommended workflow for window automation

**For controlling a specific app (e.g., iPhone Mirroring):**

```sh
# 1) List windows to find target
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" "$ANEMLL_HOST/windows" | python3 -m json.tool

# 2) Capture target window (faster than full screen)
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/capture" -d '{"title": "iPhone Mirroring"}'

# 3) Analyze /tmp/anemll_window.png to find UI elements

# 4) Click inside window using relative coordinates
# (Image pixels / 2 = window points for retina displays)
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/click_window" -d '{"title": "iPhone Mirroring", "offset_x": 163, "offset_y": 125}'

# 5) Capture again to verify result
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/capture" -d '{"title": "iPhone Mirroring"}'
```

This is faster and more reliable than full-screen workflows because:
- Smaller images to capture and analyze
- No coordinate conversion between screen space and image space
- Window position changes don't break automation
- Works even if window is partially occluded

---

### Suggested automation loop (Claude should follow this pattern)

1) POST /screenshot
2) Inspect /tmp/anemll_last.png
3) Decide next action (click, type, etc.)
4) Repeat until goal state is reached
5) After each action, take another screenshot to confirm

Example loop skeleton:

```sh
# 1) screenshot
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -X POST "$ANEMLL_HOST/screenshot" >/dev/null

# 2) (Claude analyzes /tmp/anemll_last.png)

# 3) action
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/click" -d '{"x":200,"y":150}' >/dev/null

# 4) screenshot again
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -X POST "$ANEMLL_HOST/screenshot" >/dev/null
```

## Troubleshooting

**Connection refused / no reply (curl exit code 7):**
- The AnemllAgentHost app is not running or the server is not started.
- Fix:
  - Look for the AnemllAgentHost icon in the macOS menu bar (top-right of screen).
  - Click the icon and ensure the server shows "Running" (green indicator).
  - If the app is not in the menu bar, launch it from Applications or Xcode.
  - Click "Start" button in the app UI if the server is stopped.

**`{"error":"unauthorized"}` response:**
- The bearer token has changed or doesn't match.
- Tokens rotate when the app restarts or when "Rotate Token" is clicked.
- Fix:
  - Ask the user to provide the current token from the AnemllAgentHost menu bar app UI.
  - The token is displayed under "Bearer Token:" in the app popover.
  - Re-export with the new token:

```sh
export ANEMLL_TOKEN="NEW_TOKEN_FROM_UI"
```

- Confirm process listening:

```sh
lsof -nP -iTCP:8765 -sTCP:LISTEN
```

**`screenCaptureNotAllowed` error:**
- Screen Recording permission not granted to the GUI app.
- Fix:
  - System Settings -> Privacy and Security -> Screen and System Audio Recording -> enable AnemllAgentHost
  - Quit and relaunch app

**Click/type does not do anything:**
- Accessibility permission missing (or target app blocks automation).
- Fix:
  - System Settings -> Privacy and Security -> Accessibility -> enable AnemllAgentHost
  - Quit and relaunch app

## Safety constraints (Claude must follow)

- Only interact with apps/windows you explicitly intend to test.
- Prefer small, reversible actions.
- After any action that changes state, immediately take a screenshot to confirm.
- Do not type secrets into UI fields unless explicitly instructed.

## Optional

If you want, add a small CLI wrapper (e.g., `ui.sh`) so Claude calls `ui shot`, `ui click 100 200`, `ui type "hi"` instead of raw curl.
