#!/bin/bash
# ==============================================================================
# Script: looper-profiles.sh
# Description: Scheduling profiles for looper.sh. Sourced by looper.sh.
#              Define custom profiles as functions: profile_<name>()
#              Each profile sets: LABELS, FLAGS, LIMIT, SUMMARY
#
# Built-in profiles (overnight, morning, daytime, continuous) are defined
# directly in looper.sh. Add custom profiles here.
# ==============================================================================

# Example custom profile:
# profile_hotfix() {
#     LABELS="ready_for_dev"
#     FLAGS="--auto --hard --worktree"
#     LIMIT=1
#     SUMMARY=""
# }
