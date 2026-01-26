#!/bin/bash
# ==============================================================================
# Script: install.sh
# Description: Install auto-claude scripts to .auto-claude directory
# Usage: curl -fsSL https://raw.githubusercontent.com/jackhuynh95/auto-claude/main/install.sh | bash
# ==============================================================================

set -euo pipefail

REPO="jackhuynh95/auto-claude"
INSTALL_DIR=".auto-claude"

echo "Installing auto-claude to $INSTALL_DIR..."

# Check if git root
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Error: Not a git repository. Run from your project root."
    exit 1
fi

# Remove existing if present
if [[ -d "$INSTALL_DIR" ]]; then
    echo "Removing existing $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
fi

# Clone (shallow)
git clone --depth 1 "https://github.com/$REPO.git" "$INSTALL_DIR"

# Remove git history (it's now part of your project)
rm -rf "$INSTALL_DIR/.git"
rm -f "$INSTALL_DIR/install.sh"
rm -f "$INSTALL_DIR/release.sh"

# Make scripts executable
chmod +x "$INSTALL_DIR"/*.sh 2>/dev/null || true

# Add to .gitignore if not already
if ! grep -q "^\.auto-claude" .gitignore 2>/dev/null; then
    echo "" >> .gitignore
    echo "# Auto-Claude scripts" >> .gitignore
    echo ".auto-claude/" >> .gitignore
    echo "Added .auto-claude to .gitignore"
fi

echo ""
echo "Installed! Usage:"
echo "  .auto-claude/ship-issue.sh 42        # Ship issue #42"
echo "  .auto-claude/fix-issue.sh 42         # Fix issue #42"
echo "  .auto-claude/fix-issue.sh 42 --hard  # Complex fix"
echo ""
echo "See .auto-claude/README.md for full docs."
