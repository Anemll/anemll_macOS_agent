# AnemllAgentHost — App Review Test Information

No sign-in required. The app runs entirely locally with a self-generated Bearer token.

## How to Test

1. Launch AnemllAgentHost — it appears as a menu bar icon (top-right).
2. Click the icon to open the popover UI.
3. Grant Screen Recording and Accessibility permissions via the onboarding wizard.
4. Click "Check Permissions" after each step (both rows should show green checkmarks).
5. Click "Done" — the server starts automatically on 127.0.0.1:8765.
6. The menu bar icon changes from monochrome to full-color when the server is running.

## Basic Functional Test (Terminal)

```bash
export ANEMLL_TOKEN="PASTE_TOKEN_HERE"   # copy from app UI
export ANEMLL_HOST="http://127.0.0.1:8765"

# Health check
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" "$ANEMLL_HOST/health"

# Screenshot
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" -X POST "$ANEMLL_HOST/screenshot"
open /tmp/anemll_last.png

# List windows
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" "$ANEMLL_HOST/windows"

# Capture a window
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/capture" -d '{"app":"Finder"}'
```

## Skills Test (Claude Code / Cursor)

The app installs skill files for Claude Code and Codex. To test the AI integration:

1. Click "Install Skills" in the popover to copy skills to ~/.claude/skills/ and ~/.codex/skills/.
2. Open a project in Cursor with Claude Code enabled.
3. Ask Claude Code to use the anemll-macos-agent skill (e.g., "take a screenshot", "list windows").
4. Claude Code will call the localhost API using the Bearer token.

Note: We recommend running UI automation tests on a remote/secondary Mac (via SSH) to avoid I/O conflicts between the developer's input and the AI agent's simulated clicks and keystrokes.

## UI Controls

- Start/Stop: toggles server (green dot = running, red dot = stopped)
- Rotate Token: generates new auth token
- Copy token: copies to clipboard
- Cursor Overlay toggle: shows red ring at cursor position in screenshots
- Install Skills: syncs skill files to Claude Code and Codex directories
- Gear menu: Restart App, Reset Permissions, Open Privacy Settings
- Quit: terminates the app

## Security

- Localhost only (127.0.0.1), rejects remote connections
- Bearer token auth on every request
- No outbound network connections, no telemetry, no data collection
- Screenshots written to /tmp/ and overwritten each capture
