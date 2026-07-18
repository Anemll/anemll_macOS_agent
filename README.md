# AnemllAgentHost

[![ANEMLL](https://img.shields.io/badge/ANEMLL-GitHub-blue)](https://github.com/Anemll/anemll_macOS_agent)

AnemllAgentHost v0.2.1 is a local macOS menu-bar automation server for AI agents and test harnesses. It exposes bounded REST and MCP APIs for semantic Accessibility inspection, mouse and keyboard input, ScreenCaptureKit capture, OCR, waits, and low-round-trip action batches.

The fastest path is text-first: inspect an Accessibility tree, act on a matching element, and wait for the resulting state. Screenshots remain available for visual or custom-drawn interfaces, while no-image models can operate entirely through compact text responses.

## Highlights

- Semantic Accessibility tree, actions, and condition-based waits
- Text-only, bounded batch execution for faster agent loops
- App activation, paste, hotkeys, drag, clicks, movement, scrolling, and typing
- Full-screen and per-window capture with OCR and measured timings
- ScreenCaptureKit on macOS 14+, with a macOS 13 compatibility path
- Retina-, resize-, and crop-aware image coordinate conversion
- MCP Streamable HTTP-style JSON-RPC plus REST parity
- One-click skill and MCP setup for Droid, Pi, Claude, Codex, and Grok
- Swift 6 concurrency checks, unit tests, CI, and a model acceptance benchmark

## Security

- The listener is forced to `127.0.0.1:8765`; remote interfaces are not accepted.
- A random 256-bit bearer token is generated at launch and can be rotated.
- Protected requests accept the token only in the `Authorization` header—not in URL queries.
- Browser origins are matched exactly against localhost, `127.0.0.1`, or `::1`.
- Request headers, bodies, text, images, bursts, waits, trees, and batches are bounded.
- Inline base64 capture skips disk output by default; no telemetry is collected.

Do not log or commit the bearer token. The debug viewer uses a URL fragment so the token is not sent in the initial URL request:

```text
http://127.0.0.1:8765/debug#token=TOKEN
```

## Setup

1. Build and launch `AnemllAgentHost.xcodeproj`, or open an installed build.
2. Grant Screen Recording and Accessibility in the onboarding UI.
3. Start the server and copy its bearer token.
4. Click **Install Skills**, select the agent clients you use, and install their skill and MCP tools. Existing client settings are preserved.
5. Export local variables before launching those clients:

```bash
export ANEMLL_HOST="http://127.0.0.1:8765"
export ANEMLL_TOKEN="PASTE_TOKEN_FROM_APP"
```

6. Verify the server:

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" "$ANEMLL_HOST/health"
```

## Semantic-first example

```bash
# Inspect TextEdit as compact text.
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"TextEdit","max_depth":8,"max_elements":500}' \
  "$ANEMLL_HOST/accessibility/tree"

# Focus a matching text area and paste in one server round trip.
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"actions":[
    {"type":"activate","app":"TextEdit"},
    {"type":"accessibility_action","app":"TextEdit","role":"AXTextArea","action":"focus"},
    {"type":"paste","text":"Hello from ANEMLL"}
  ]}' "$ANEMLL_HOST/batch"
```

## Capture example

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"Safari","max_dimension":1120,"resize_mode":"scale","ocr":true}' \
  "$ANEMLL_HOST/capture"
```

Capture responses include `capture_ms`, `encode_ms`, and `total_ms`. Set `return_base64:true` for an inline MCP/JSON image; `save_to_file` then defaults to false to avoid redundant I/O.

## MCP

The same server accepts one JSON-RPC message per `POST /mcp`:

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -H "MCP-Protocol-Version: 2025-11-25" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  "$ANEMLL_HOST/mcp"
```

`GET /mcp` returns 405 and JSON-RPC batches are rejected. Supported protocol versions are `2025-11-25`, `2025-06-18`, and `2025-03-26`.

## Develop and verify

Build without local signing:

```bash
xcodebuild -project AnemllAgentHost.xcodeproj \
  -scheme AnemllAgentHost -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

Run Swift 6 core tests:

```bash
swift test
```

Run non-destructive live API/security smoke tests:

```bash
python3 scripts/smoke_test_harness.py --token "$ANEMLL_TOKEN" --capture
```

Run the configured no-image DeepSeek acceptance benchmark against a live local harness:

```bash
python3 scripts/benchmark_model_harness.py \
  --harness-token "$ANEMLL_TOKEN" \
  --iterations 6
```

The benchmark measures time to first content, total model latency, JSON/tool-selection reliability, harness latency, retries, and transport errors. Its default model is `deepseek-v4-flash-dspark-abliterated` at `http://192.168.1.68:8888/v1`.

The checked-in acceptance baseline is [reports/deepseek-v4-flash-dspark-abliterated.json](reports/deepseek-v4-flash-dspark-abliterated.json).

## Documentation

- [Agent/API instructions](CLAUDE_INSTRUCTIONS.md)
- [Canonical bundled skill](AnemllAgentHost/skills/SKILL.md)
- [App distribution notes](DISTRIBUTION.md)
- [Changelog](CHANGELOG.md)
- [License](LICENSE) and [attribution notice](NOTICE)

Copyright 2026 ANEMLL. Licensed under Apache License 2.0.
