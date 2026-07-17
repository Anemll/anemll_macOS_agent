# Agent client instructions

The canonical, versioned agent guide is [AnemllAgentHost/skills/SKILL.md](AnemllAgentHost/skills/SKILL.md). It is bundled into the app and can be installed with native MCP tools for Droid, Pi, Claude, Codex, and Grok from the menu-bar UI.

This file covers connection and integration essentials. Use the skill for complete endpoint examples, coordinate semantics, limits, Accessibility actions, capture behavior, and troubleshooting.

## Connection contract

- Run commands on the same Mac as AnemllAgentHost.
- Base URL: `http://127.0.0.1:8765`
- Authentication: `Authorization: Bearer TOKEN`
- Never send a token as a URL query parameter.
- REST JSON requests use `Content-Type: application/json`.
- MCP uses one JSON-RPC message per `POST /mcp`.

```bash
export ANEMLL_HOST="http://127.0.0.1:8765"
export ANEMLL_TOKEN="PASTE_TOKEN_FROM_APP"

curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" "$ANEMLL_HOST/health"
```

Expected for this release:

```json
{"ok":true,"version":"0.2.1"}
```

A `401` response means the token is missing, stale, or from another running app instance. Copy the current token and avoid running multiple instances on port 8765.

## Recommended agent loop

1. Call `/accessibility/tree` for compact UI state.
2. Use `/accessibility/action` for an identified element.
3. Use `/accessibility/wait` to confirm the transition.
4. Combine deterministic steps with `/batch` to reduce round trips.
5. Capture only for layout, custom controls, or visual verification.

This ordering is especially important for models configured with `noImageSupport`.

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"TextEdit","max_depth":8,"max_elements":500}' \
  "$ANEMLL_HOST/accessibility/tree"
```

## MCP integration

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -H "MCP-Protocol-Version: 2025-11-25" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
    "protocolVersion":"2025-11-25",
    "capabilities":{},
    "clientInfo":{"name":"local-agent","version":"1"}
  }}' "$ANEMLL_HOST/mcp"

curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -H "MCP-Protocol-Version: 2025-11-25" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  "$ANEMLL_HOST/mcp"
```

The text-first MCP tools are:

- `anemll_windows`
- `anemll_activate`
- `anemll_accessibility_tree`
- `anemll_accessibility_action`
- `anemll_accessibility_wait`
- `anemll_batch`
- Pointer, keyboard, window, capture, OCR, and burst tools

## Safety

- Limit interactions to the intended app and task.
- Prefer exact `pid`, `window_id`, role, or accessibility identifier targeting.
- Keep batches bounded and stop to observe when later actions depend on earlier state.
- Verify consequential UI changes.
- Do not enter secrets unless explicitly requested.
- Do not bypass macOS permission prompts or attempt remote exposure of the listener.

## Debug viewer

The app copies a URL shaped like this:

```text
http://127.0.0.1:8765/debug#token=TOKEN
```

The fragment is consumed by page JavaScript, removed from browser history, and converted to an authorization header for protected image/meta requests. Do not rewrite it as `?token=`.

## Testing model compatibility

The repository includes a no-image OpenAI-compatible benchmark:

```bash
python3 scripts/benchmark_model_harness.py \
  --base-url http://192.168.1.68:8888/v1 \
  --model deepseek-v4-flash-dspark-abliterated \
  --api-key not-needed \
  --harness-token "$ANEMLL_TOKEN" \
  --iterations 6
```

It executes only allowlisted metadata/Accessibility tools and wait-only batches. The JSON report includes model first-content and total latency, retries, action validity, harness execution latency, and transport errors.
