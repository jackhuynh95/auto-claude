#!/bin/bash
# ==============================================================================
# Script: release.sh
# Description: Create a GitHub release for auto-claude
# Usage: ./release.sh [version]
# Example: ./release.sh v1.0.0
# ==============================================================================

set -euo pipefail

VERSION="${1:-v1.0.0}"

echo "Creating release $VERSION..."

# Create tag
git tag "$VERSION" 2>/dev/null || echo "Tag $VERSION already exists"

# Push tag
git push origin "$VERSION"

# Create GitHub release
gh release create "$VERSION" \
    --title "Auto-Claude $VERSION" \
    --notes "$(cat <<EOF
## Auto-Claude $VERSION

End-to-end automation: GitHub Issue → Plan → Code → PR

### Scripts
- \`ship-issue.sh\` - Full workflow: plan → code → PR
- \`fix-issue.sh\` - Bug fix: /fix loop → PR
- \`ship-issues.sh\` - Batch processing
- \`research.sh\` - Research → GitHub issue

### Install
\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/jackhuynh95/auto-claude/main/install.sh | bash
\`\`\`

See [README](https://github.com/jackhuynh95/auto-claude#readme) for full docs.
EOF
)"

echo "Release $VERSION created!"
echo "URL: https://github.com/jackhuynh95/auto-claude/releases/tag/$VERSION"
