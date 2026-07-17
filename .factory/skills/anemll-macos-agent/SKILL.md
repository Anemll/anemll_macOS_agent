---
name: anemll-macos-agent
description: Control and test local macOS application UI through AnemllAgentHost using semantic Accessibility queries, bounded input actions, screenshots, OCR, and localhost REST or MCP APIs. Use for macOS GUI inspection, interaction, or end-to-end testing when the host app is running. Prefer semantic text tools for no-image models and use visual capture only when semantics are insufficient. Do not use for shell or file operations that do not require GUI interaction.
---

# ANEMLL macOS Agent

Compatible with AnemllAgentHost v0.2.1.

Use this skill to automate UI on the same Mac as AnemllAgentHost. The server listens only on `127.0.0.1:8765` and requires a bearer token for every endpoint except the empty `/debug` HTML shell and MCP preflight.

## Preconditions

- AnemllAgentHost is running from the menu bar.
- Accessibility permission is enabled for input and semantic UI actions.
- Screen Recording permission is enabled for screenshots, window capture, and OCR.
- The server indicator is green.
- The current bearer token is available from the app UI.

## Install into agent clients

The app's **Install Skills** button opens a target picker for Droid, Pi, Claude, Codex, and Grok. For each selected client, it installs this skill and safely merges the native MCP server entry without removing unrelated settings.

- Droid: Factory skill and native MCP configuration.
- Pi: Pi skill and MCP configuration; when Pi is installed, the app also runs `pi install npm:pi-mcp-adapter`.
- Claude: Claude skill and user-scoped MCP configuration.
- Codex: shared `~/.agents/skills` skill and native MCP configuration.
- Grok: Grok skill and native MCP configuration.

The generated configurations reference `ANEMLL_TOKEN`; they never store the current token. Export the current value before launching a selected agent client. Re-running the installer refreshes only the ANEMLL skill and its named MCP entry.

Set variables once per shell:

```bash
export ANEMLL_HOST="http://127.0.0.1:8765"
export ANEMLL_TOKEN="PASTE_TOKEN_FROM_APP"
```

Never put the token in a URL query, logs, screenshots, or committed files. Send it only as:

```bash
-H "Authorization: Bearer $ANEMLL_TOKEN"
```

Rotate the token in the app if it is exposed. The debug viewer uses a URL fragment, which browsers do not send to the server:

```text
http://127.0.0.1:8765/debug#token=TOKEN
```

## Operating strategy

For reliability and speed:

1. Check `/health` once.
2. Prefer `/accessibility/tree` to inspect a UI as compact text.
3. Use `/accessibility/action` to press, focus, or set a known element.
4. Use `/accessibility/wait` for state changes instead of fixed sleeps.
5. Use `/batch` for several deterministic actions in one round trip.
6. Use `/capture` or `/screenshot` only when layout, pixels, custom controls, or visual verification matter.
7. Verify consequential UI changes with a semantic query or a fresh capture.

For a no-image model, do not call screenshot tools unless another capable model or a human will inspect the result. Accessibility trees, window metadata, OCR text, and bounded batch results are text-only.

## Health and window discovery

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" "$ANEMLL_HOST/health"

curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  "$ANEMLL_HOST/windows" | python3 -m json.tool
```

Window objects include `id`, `pid`, `app`, `title`, `bounds`, `layer`, and `on_screen`.

## Semantic Accessibility API

Queries accept `pid` or `app`, plus optional `role`, `title`, and `identifier` substring filters. Traversal is bounded by `max_depth` (maximum 20) and `max_elements` (maximum 2000).

Inspect a compact tree:

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"TextEdit","max_depth":8,"max_elements":500}' \
  "$ANEMLL_HOST/accessibility/tree"
```

Find only matching controls:

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"System Settings","role":"AXButton","title":"Allow"}' \
  "$ANEMLL_HOST/accessibility/tree"
```

Press or focus the first match:

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"TextEdit","role":"AXButton","title":"Save","action":"press"}' \
  "$ANEMLL_HOST/accessibility/action"
```

Supported actions are `press`, `click`, `confirm`, `cancel`, `increment`, `decrement`, `show_menu`, `focus`, and `set_value`. `set_value` also requires `value`. Secure text-field values are never returned.

Wait up to five seconds for an element:

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"TextEdit","title":"Save","state":"exists","timeout_ms":5000}' \
  "$ANEMLL_HOST/accessibility/wait"
```

Use `"state":"gone"` to wait for disappearance. Timeouts are bounded to 60 seconds.

## Fast input API

Activate a running app:

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"TextEdit"}' "$ANEMLL_HOST/activate"
```

Paste long text in one operation; the previous plain-text clipboard is restored:

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text":"Fast Unicode text"}' "$ANEMLL_HOST/paste"
```

Use `/type` for short keystroke-like text:

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text":"hello"}' "$ANEMLL_HOST/type"
```

Hotkeys accept an array or plus-separated string:

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"shortcut":"command+shift+p"}' "$ANEMLL_HOST/hotkey"
```

Drag in screen points:

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"from_x":200,"from_y":300,"to_x":600,"to_y":300,"duration_ms":350}' \
  "$ANEMLL_HOST/drag"
```

## Batching

`/batch` executes 1–50 actions sequentially and stops on the first error. Supported types are `click`, `double_click`, `right_click`, `move`, `scroll`, `type`, `paste`, `hotkey`, `drag`, `activate`, `wait`, `accessibility_action`, and `accessibility_wait`.

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"actions":[
    {"type":"activate","app":"TextEdit"},
    {"type":"accessibility_wait","app":"TextEdit","role":"AXTextArea","timeout_ms":3000},
    {"type":"accessibility_action","app":"TextEdit","role":"AXTextArea","action":"focus"},
    {"type":"paste","text":"Hello from ANEMLL"}
  ]}' "$ANEMLL_HOST/batch"
```

Keep batches small and deterministic. Do not batch actions whose next coordinates depend on observing the previous result.

## Coordinates and pointer input

All public screen and window point coordinates use Quartz global coordinates with origin at the top-left of the main display. Image pixels use top-left origin.

- `screen_points` is the default for `/click`, `/move`, `/drag`, and `/scroll` positions.
- `image_pixels` maps through the latest full-screen screenshot, including Retina scale, proportional resize, and crop trim.
- `/click_window` offsets are window points from that window's top-left.
- OCR `click_x` and `click_y` are already window-point offsets for `/click_window`.

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"x":640,"y":400,"space":"screen_points"}' "$ANEMLL_HOST/click"

curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"x":300,"y":240,"space":"image_pixels"}' "$ANEMLL_HOST/double_click"

curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"x":640,"y":400}' "$ANEMLL_HOST/right_click"

curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"dy":-300}' "$ANEMLL_HOST/scroll"
```

Get the current pointer in both spaces after a full-screen capture:

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" "$ANEMLL_HOST/mouse"
```

## Capture and OCR

Modern macOS uses ScreenCaptureKit. Full-screen captures default to proportional scaling with `max_dimension=1120`; window captures default to full resolution and crop mode when a limit is supplied.

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"cursor":false,"max_dimension":1120,"resize_mode":"scale"}' \
  "$ANEMLL_HOST/screenshot"

curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"Safari","max_dimension":"playwright","ocr":true}' \
  "$ANEMLL_HOST/capture"
```

`max_dimension` accepts `0`/`full`, `playwright` (1120), `safe` (2000), `max` (8000), or an integer from 0–8000. `resize_mode` is `scale` or `crop`.

Capture responses include `capture_ms`, `encode_ms`, `total_ms`, dimensions, resize metadata, and optional OCR timing. OCR results contain output-image boxes plus `source_x`, `source_y`, `click_x`, and `click_y`.

Inline images avoid disk I/O:

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"Safari","return_base64":true,"save_to_file":false}' \
  "$ANEMLL_HOST/capture"
```

When `return_base64` is true, `save_to_file` defaults to false. Otherwise captures default to `/tmp/anemll_last.png` or `/tmp/anemll_window.png`. Image encoding is performed once even when both outputs are requested.

Burst capture accepts 1–100 frames and intervals from 10–60000 ms:

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"Safari","count":10,"interval_ms":100,"max_dimension":1120}' \
  "$ANEMLL_HOST/burst"
```

## Window-relative fallback

Use these when Accessibility cannot expose a custom control:

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"Safari","offset_x":200,"offset_y":150}' "$ANEMLL_HOST/focus"

curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"Safari","offset_x":200,"offset_y":150}' "$ANEMLL_HOST/click_window"

curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"Safari","offset_x":200,"offset_y":150,"dy":-500}' \
  "$ANEMLL_HOST/scroll_window"
```

## MCP

Use `POST /mcp` with `Content-Type: application/json`, the bearer header, and optionally `MCP-Protocol-Version: 2025-11-25`. One JSON-RPC message is accepted per POST; batches are rejected. `GET /mcp` returns 405.

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -H "MCP-Protocol-Version: 2025-11-25" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  "$ANEMLL_HOST/mcp"
```

Tools are named `anemll_screenshot`, `anemll_windows`, `anemll_capture`, pointer/input variants, `anemll_activate`, `anemll_accessibility_tree`, `anemll_accessibility_action`, `anemll_accessibility_wait`, `anemll_batch`, and `anemll_burst`.

## Limits and failures

- Request headers: 32 KiB maximum.
- Request body: 2 MiB maximum.
- Text input: 100,000 characters maximum.
- Invalid negative, oversized, chunked, or malformed requests are rejected before automation.
- `401` means missing, stale, or incorrect bearer token.
- `403` means a macOS permission or browser Origin policy denied the operation.
- `404` means an app, window, or accessibility element was not found.
- `409` means the selected accessibility action failed on that element.
- `413` means the request body is too large.

If commands hit the wrong app, list windows and prefer `window_id` or `pid` over a broad title substring. If coordinates drift, take a fresh screenshot before using `image_pixels`; do not reuse image coordinates after a display or resolution change.
