#!/bin/bash
# Install AnemllAgentHost Claude Code skill to user's skills directory
# Usage: ./install-skill.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SRC="$SCRIPT_DIR/.claude/skills/anemll-macos-agent"
SKILL_DST="$HOME/.claude/skills/anemll-macos-agent"

if [ ! -f "$SKILL_SRC/SKILL.md" ]; then
    echo "Error: SKILL.md not found in $SKILL_SRC"
    exit 1
fi

# Create destination directory
mkdir -p "$SKILL_DST"

# Copy skill file
cp "$SKILL_SRC/SKILL.md" "$SKILL_DST/SKILL.md"

if [ $? -eq 0 ]; then
    echo "Skill installed to $SKILL_DST"
    echo ""
    echo "The skill will be available in Claude Code sessions."
    echo "Use 'skill: anemll-macos-agent' to invoke it."
else
    echo "Error: Failed to copy skill file"
    exit 1
fi
