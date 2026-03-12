#!/bin/bash
# ==============================================================================
# Script: install.sh
# Description: Install auto-claude pipeline to .auto-claude directory
# Usage: curl -fsSL https://raw.githubusercontent.com/jackhuynh95/auto-claude/main/install.sh | bash
# ==============================================================================

set -euo pipefail

REPO="jackhuynh95/auto-claude"
INSTALL_DIR=".auto-claude"

echo "Installing auto-claude to $INSTALL_DIR..."

# Require git root
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Error: Not a git repository. Run from your project root."
    exit 1
fi

# Remove existing install
if [[ -d "$INSTALL_DIR" ]]; then
    echo "Removing existing $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
fi

# Shallow clone
git clone --depth 1 "https://github.com/$REPO.git" "$INSTALL_DIR"

# Strip dev-only artifacts
rm -rf "$INSTALL_DIR/.git"
rm -f  "$INSTALL_DIR/install.sh"
rm -f  "$INSTALL_DIR/release.sh"
rm -f  "$INSTALL_DIR/build-release.js"
rm -rf "$INSTALL_DIR/issues"
rm -rf "$INSTALL_DIR/logs"

# Make all scripts executable
chmod +x "$INSTALL_DIR"/*.sh 2>/dev/null || true

# Install .claude/ (ClaudeKit: agents, commands, skills, hooks, rules, etc.)
if [[ -d "$INSTALL_DIR/.claude" ]]; then
    echo "Installing .claude/ (ClaudeKit)..."
    mkdir -p .claude

    # Auto-claude managed dirs — always overwrite so skills/commands/agents stay up-to-date
    for dir in skills commands agents rules scripts hooks output-styles; do
        if [[ -d "$INSTALL_DIR/.claude/$dir" ]]; then
            cp -r "$INSTALL_DIR/.claude/$dir" .claude/
        fi
    done

    # Misc managed files (statusline helpers, metadata)
    for file in statusline.cjs statusline.ps1 statusline.sh metadata.json; do
        [[ -f "$INSTALL_DIR/.claude/$file" ]] && cp "$INSTALL_DIR/.claude/$file" .claude/
    done

    # settings.json — copy only if not present (user may have customized)
    cp -n "$INSTALL_DIR/.claude/settings.json" .claude/settings.json 2>/dev/null || true

    # settings.local.json is user-specific — never copy
    echo "Installed .claude/ (ClaudeKit)"
fi

# Bootstrap CLAUDE.md if missing
if [[ ! -f "CLAUDE.md" ]] && [[ -f "$INSTALL_DIR/CLAUDE.template.md" ]]; then
    cp "$INSTALL_DIR/CLAUDE.template.md" "CLAUDE.md"
    echo "Created CLAUDE.md from template (customize it for your project)"
fi

# Add to .gitignore if not already
if ! grep -q "^\\.auto-claude" .gitignore 2>/dev/null; then
    printf "\n# Auto-Claude pipeline\n.auto-claude/\n" >> .gitignore
    echo "Added .auto-claude/ to .gitignore"
fi

echo ""
echo "Installed! Next steps:"
echo ""
echo "  1. Customize CLAUDE.md for your project"
echo "  2. Create pipeline labels on GitHub (once):"
echo "       .auto-claude/setup-labels.sh"
echo ""
echo "  3. Queue an issue:"
echo "       gh issue edit 42 --add-label pipeline --add-label ready_for_dev"
echo ""
echo "  4. Run the pipeline:"
echo "       .auto-claude/looper.sh --dry-run     # preview"
echo "       .auto-claude/looper.sh                # process"
echo "       /loop 2h .auto-claude/looper.sh --profile overnight   # automated"
echo ""
echo "See .auto-claude/docs/PIPELINE.md for full reference."
