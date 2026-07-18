# Changelog

All notable changes to AnemllAgentHost are documented here.

## 0.2.1 - 2026-07-16

### Added

- Added an **Install Skills** target picker for Droid, Pi, Claude, Codex, and Grok.
- Added native MCP configuration for all five clients and automatic `pi-mcp-adapter` installation when Pi is available.
- Added tests for every install path, config preservation, targeted TOML replacement, and malformed-config safety.

### Changed

- Moved Codex skill installation to the current shared `~/.agents/skills` location.
- Skill sync status now covers all detected agent clients.

### Security

- MCP configuration merges preserve unrelated user settings and refuse to overwrite malformed JSON.
- Generated MCP entries reference `ANEMLL_TOKEN` instead of persisting the live bearer token.

## 0.2.0 - 2026-07-16

### Added

- Semantic Accessibility tree inspection, element actions, and condition-based waits.
- Bounded multi-action batches, app activation, paste, hotkeys, and drag input.
- ScreenCaptureKit capture on macOS 14 and newer, with a macOS 13 fallback.
- Retina-, crop-, and resize-aware coordinate conversion and capture timing metrics.
- Swift 6 core tests, macOS CI, live smoke tests, and a no-image model benchmark.

### Changed

- Moved protected endpoints to bearer-header authentication only.
- Reworked HTTP parsing around strict header/body limits and malformed-request rejection.
- Made inline image responses skip disk output by default.
- Reduced cursor-overlay update frequency and disabled the overlay by default.
- Updated the bundled Codex and Claude skills for the v0.2.0 API and security model.

### Security

- Restricted the listener to IPv4 loopback.
- Replaced the static token with a random 256-bit token and constant-time comparison.
- Added exact localhost Origin validation and bounded text, image, tree, batch, and wait inputs.
- Removed query-string token authentication; the debug viewer transfers its token through a URL fragment.
