# macOS Agent Host (menu bar UI driver)

[![ANEMLL](https://img.shields.io/badge/ANEMLL-GitHub-blue)](https://github.com/Anemll/anemll_macOS_agent)

This repo contains a minimal macOS menu bar app (AnemllAgentHost) that exposes a localhost HTTP API for UI automation (screenshot, click, type). The instructions below are formatted for Claude Code/Codex to use the service via SSH + curl.

## MCP (Model Context Protocol) endpoint

The same localhost server also exposes an MCP JSON-RPC endpoint (Streamable HTTP style) at:

- `POST http://127.0.0.1:8765/mcp`

Auth is the same as the REST endpoints: `Authorization: Bearer $ANEMLL_TOKEN` (or `?token=...` if your MCP client can’t set headers).

Quick sanity check (list tools):

```bash
curl -s \
  -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/mcp" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

## Base64-first Capture (Recommended)

For fastest agent loops, request **inline base64 images** to avoid extra file reads:

```bash
curl -s -H "Authorization: Bearer $ANEMLL_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$ANEMLL_HOST/capture" \
  -d '{"title":"iPhone Mirroring","return_base64":true,"max_dimension":"playwright"}'
```

## Overview tips
- Use the lowest macOS screen resolution (1344x756) to reduce coordinate drift.
- If testing iPhone UI, use iPhone screen sharing and keep the mirrored iPhone near the top-left of the screen.

## First-Time Setup (Onboarding)

When you first launch the app, an **onboarding wizard** guides you through granting the required macOS permissions:

### Step 1: Screen Recording Permission
1. Click **"Enable"** next to "Screen Recording"
2. macOS will prompt you to open System Settings
3. In **System Settings → Privacy & Security → Screen Recording**, toggle **AnemllAgentHost** ON
4. Return to the app and click **"Check Permissions"**

### Step 2: Accessibility Permission
1. Click **"Enable"** next to "Accessibility"
2. macOS will prompt you to open System Settings
3. In **System Settings → Privacy & Security → Accessibility**, toggle **AnemllAgentHost** ON
4. Return to the app and click **"Check Permissions"**

### Step 3: Complete Setup
1. Once both permissions show green checkmarks, click **"Done"**
2. The server will start automatically
3. Copy the Bearer token to share with your Claude agent

> **Tip**: If permissions don't take effect, use the gear menu (⚙️) and select **"Restart App"**.

## After Reinstall or Recompile

If you reinstall or recompile the app, macOS may cache stale permissions:

1. Open the app and click the **gear menu** (⚙️)
2. Select **"Reset Permissions"** to clear TCC database entries
3. Select **"Restart App"** (or quit and relaunch manually)
4. The onboarding wizard will appear again to re-grant permissions

Alternatively, use **"Reset & Restart"** to do both steps at once.

## Skill Sync

The app includes a bundled skill file for **Claude Code and Codex**. If you see **"Skill update available"**:
1. Click **"Sync"** to copy the latest skill to:
   - `~/.claude/skills/anemll-macos-agent/`
   - `~/.codex/skills/custom/anemll-macos-agent/`
2. This keeps your agent skill definitions in sync with the app version

## Quick Reference

| Action | How |
|--------|-----|
| Start/Stop server | Click "Start" or "Stop" button |
| Rotate token | Click "Rotate Token" |
| Copy token | Click clipboard icon next to token |
| Toggle cursor overlay | Use "Cursor Overlay" toggle |
| Restart app | Gear menu → "Restart App" |
| Reset permissions | Gear menu → "Reset Permissions" |
| Reset + restart | Gear menu → "Reset & Restart" |
| Open Privacy settings | Gear menu → "Open Privacy Settings" |
| Sync skill file | Click "Sync" when update available (Claude + Codex) |

## Context (informational only)

- The Agent runs on a host Mac with Xcode and the app installed (menu bar UI visible).
- Claude runs inside Cursor and connects to that same host via SSH (Cursor server environment).
- Claude and the Agent are therefore on the same host.
- With this setup, Claude can view/control the app, run QC, and perform verification tasks.

## Claude Code/Codex Instructions

See **[CLAUDE_INSTRUCTIONS.md](CLAUDE_INSTRUCTIONS.md)** for detailed API documentation and usage instructions for Claude Code agents.

## License

Apache License 2.0 - See [LICENSE](LICENSE) for the full text.

### Attribution

If you use or redistribute this software, you must retain the [NOTICE](NOTICE) file or include the following attribution in your documentation or legal notices:

> "This product includes software developed by ANEMLL."

Copyright 2026 ANEMLL
