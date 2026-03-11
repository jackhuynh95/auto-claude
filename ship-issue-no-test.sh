#!/bin/bash
# ==============================================================================
# Script: ship-issue-no-test.sh
# Description: Thin wrapper — calls ship-issue.sh with --no-test flag
#              For docs, configs, and trivial changes that don't need tests
#
# Usage:       ./ship-issue-no-test.sh <issue-number> [flags...]
# Example:     ./ship-issue-no-test.sh 42
#              ./ship-issue-no-test.sh 42 --auto
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/ship-issue.sh" "$@" --no-test
