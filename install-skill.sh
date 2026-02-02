#!/bin/bash
# Install AnemllAgentHost skill to Claude + Codex skills directories
# Usage: ./install-skill.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SRC="$SCRIPT_DIR/.claude/skills/anemll-macos-agent"
CLAUDE_DST="$HOME/.claude/skills/anemll-macos-agent"
CODEX_DST="$HOME/.codex/skills/custom/anemll-macos-agent"

if [ ! -f "$SKILL_SRC/SKILL.md" ]; then
    echo "Error: SKILL.md not found in $SKILL_SRC"
    exit 1
fi

# Create destination directories
mkdir -p "$CLAUDE_DST"
mkdir -p "$CODEX_DST"

# Copy skill file to both
CLAUDE_OK=0
CODEX_OK=0
if cp "$SKILL_SRC/SKILL.md" "$CLAUDE_DST/SKILL.md"; then
    CLAUDE_OK=1
fi
if cp "$SKILL_SRC/SKILL.md" "$CODEX_DST/SKILL.md"; then
    CODEX_OK=1
fi

if [[ "$CLAUDE_OK" -eq 1 && "$CODEX_OK" -eq 1 ]]; then
    echo "Skill installed to:"
    echo "  - $CLAUDE_DST"
    echo "  - $CODEX_DST"
    echo ""
    echo "The skill will be available in Claude Code and Codex sessions."
    echo "Use 'skill: anemll-macos-agent' to invoke it."
else
    echo "Error: Failed to copy skill file to one or more destinations"
    echo "Claude: $CLAUDE_DST"
    echo "Codex:  $CODEX_DST"
    exit 1
fi
