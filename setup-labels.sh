#!/bin/bash
# ==============================================================================
# Script: setup-labels.sh
# Description: Create pipeline labels on GitHub for the looper pipeline.
#              Labels act as Kanban columns — no separate board needed.
#              Safe to re-run (--force updates existing labels).
#
# Usage: bash setup-labels.sh
# ==============================================================================

set -euo pipefail

echo "Creating pipeline labels..."

gh label create "ready_for_dev"    --description "Ready for automated fix"       --color "0E8A16" --force
gh label create "ready_for_test"   --description "Fix shipped, needs e2e"        --color "FBCA04" --force
gh label create "shipped"          --description "PR created"                    --color "7057FF" --force
gh label create "verified"         --description "E2e passed"                    --color "1D76DB" --force
gh label create "blocked"          --description "Blocked, skip in pipeline"     --color "D93F0B" --force
gh label create "pipeline"         --description "In automated pipeline"         --color "C5DEF5" --force
gh label create "needs_design_review" --description "Needs manual UI review"     --color "E4E669" --force
gh label create "frontend"            --description "Touches UI — looper auto-adds --frontend-design"   --color "F9A825" --force
gh label create "hard"                --description "Complex issue — looper auto-adds --hard (opus)" --color "B60205" --force

echo "Done. Labels created/updated."
