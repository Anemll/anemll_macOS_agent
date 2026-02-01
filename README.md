# macOS Agent Host (menu bar UI driver)

[![ANEMLL](https://img.shields.io/badge/ANEMLL-GitHub-blue)](https://github.com/Anemll/anemll_macOS_agent)

This repo contains a minimal macOS menu bar app (AnemllAgentHost) that exposes a localhost HTTP API for UI automation (screenshot, click, type). The instructions below are formatted for Claude Code/Codex to use the service via SSH + curl.

## Overview tips
- Use the lowest macOS screen resolution (1344x756) to reduce coordinate drift.
- If testing iPhone UI, use iPhone screen sharing and keep the mirrored iPhone near the top-left of the screen.

## Setup (first time or after reinstall)

1. **Grant permissions** - The agent needs two macOS permissions to function:
   - **Screen Recording** - for capturing screenshots
   - **Accessibility** - for mouse/keyboard control

2. **If you reinstalled or recompiled the app**, click "Reset Permissions" in the app UI first to clear stale permissions from the previous build. Then request both permissions again.

3. **Restart the agent** after granting permissions (quit and relaunch from menu bar).

4. **Start the server** - Click "Start" in the app UI. The indicator should turn green.

5. **Provide the Bearer token** to your Claude agent - Copy the token from the app UI and share it with the agent.

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

Copyright 2025 ANEMLL
