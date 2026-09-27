#!/usr/bin/env bash
# Prints one version's section of CHANGELOG.md, for the GitHub release. Usage: release-notes.sh 0.1.1
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
awk -v version="$1" '
  /^## \[/ { printing = index($0, "## [" version "]") == 1; next }
  /^\[.*\]: / { next }
  printing { print }
' "$root/CHANGELOG.md" | sed -e '/./,$!d'
