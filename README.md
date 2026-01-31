# macOS Agent Host (menu bar UI driver)

This repo contains a minimal macOS menu bar app (AnemllAgentHost) that exposes a localhost HTTP API for UI automation (screenshot, click, type). The instructions below are formatted for Claude Code/Codex to use the service via SSH + curl.

## Overview tips
- Use the lowest macOS screen resolution (1344x756) to reduce coordinate drift.
- If testing iPhone UI, use iPhone screen sharing and keep the mirrored iPhone near the top-left of the screen.

## Context (informational only, not instructions)
- The Agent runs on a host Mac with Xcode and the app installed (menu bar UI visible).
- Claude runs inside Cursor and connects to that same host via SSH (Cursor server environment).
- Claude and the Agent are therefore on the same host.
- Claude follows the repo instructions below.
- With this setup, Claude can view/control the app, run QC, and perform verification tasks.

## Claude Code/Codex Instructions

### Preconditions
1) The GUI app AnemllAgentHost is running in the logged-in macOS session (menu bar icon visible).
2) In the app UI, both are green:
   - Screen Recording: Allowed
   - Accessibility: Allowed
3) The server is running (UI shows Running) and listening on:
   - http://127.0.0.1:8765
4) You have the Bearer token from the app UI.

Important: The HTTP server is localhost only. Commands must run on the same Mac that is running AnemllAgentHost. If Claude is on another machine, SSH into the target Mac and run curl there.

Optional: Turn on "Show Cursor Overlay" in the menu app UI to draw a small red ring at the current cursor location. This makes the cursor visible in screenshots for alignment/debugging.

### Environment setup (one-time per shell)

```sh
export ANEMLL_HOST="http://127.0.0.1:8765"
export ANEMLL_TOKEN="PASTE_TOKEN_FROM_MENU_APP"

# sanity check
echo "HOST=$ANEMLL_HOST"
echo "TOKEN=[$ANEMLL_TOKEN]"
```

### 0) Verify you are on the right machine + server

```sh
hostname
lsof -nP -iTCP:8765 -sTCP:LISTEN
```

Expected: AnemllAgentHost is the process listening.

### 1) Health check

```sh
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  "$ANEMLL_HOST/health"
```

Expected:

```json
{"ok":true}
```

If you get `{"error":"unauthorized"}` then the token in the shell does not match the token shown in the app UI (or you are on the wrong Mac).

### 2) Take a screenshot

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

### 3) Click at coordinates (x,y)

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

### 4) Type text into the currently focused control

```sh
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/type" \
  -d '{"text":"Hello from Claude Code"}'
```

### 5) Move mouse to coordinates (x,y)

```sh
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/move" \
  -d '{"x":960,"y":540}'
```

If you are moving using screenshot pixel coordinates, add `"space":"image_pixels"` like in the click example above.

### 6) Read current mouse position

```sh
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  "$ANEMLL_HOST/mouse"
```

The response includes screen-point coords and (when available) `image_x`/`image_y` in screenshot pixel space.

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

### Troubleshooting

If `/health` returns unauthorized:
- Token mismatch or wrong machine.
- Fix:
  - Copy the token from the menu app UI.
  - Re-export:

```sh
export ANEMLL_TOKEN="TOKEN_FROM_UI"
```

- Confirm process listening:

```sh
lsof -nP -iTCP:8765 -sTCP:LISTEN
```

If `/screenshot` returns `screenCaptureNotAllowed`:
- Screen Recording permission not granted to the GUI app.
- Fix:
  - System Settings -> Privacy and Security -> Screen and System Audio Recording -> enable AnemllAgentHost
  - Quit and relaunch app

If click/type does not do anything:
- Accessibility permission missing (or target app blocks automation).
- Fix:
  - System Settings -> Privacy and Security -> Accessibility -> enable AnemllAgentHost
  - Quit and relaunch app

### Safety constraints (Claude must follow)
- Only interact with apps/windows you explicitly intend to test.
- Prefer small, reversible actions.
- After any action that changes state, immediately take a screenshot to confirm.
- Do not type secrets into UI fields unless explicitly instructed.

### Optional
If you want, add a small CLI wrapper (e.g., `ui.sh`) so Claude calls `ui shot`, `ui click 100 200`, `ui type "hi"` instead of raw curl.
