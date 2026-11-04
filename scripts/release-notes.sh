set -euo pipefail
# Prints one version's section of CHANGELOG.md for the GitHub release (release-notes.sh 0.1.1).
# With a count, that version and the ones before it, each under its number, for the update dialog (release-notes.sh 0.1.1 5).
root="$(cd "$(dirname "$0")/.." && pwd)"
awk -v version="$1" -v count="${2:-1}" '
  /^## \[/ {
    if (!started && index($0, "## [" version "]") == 1) started = 1
    printing = started && shown++ < count
    if (printing && count > 1) { split($0, parts, /[][]/); print "## " parts[2] }
    next
  }
  /^\[.*\]: / { next }
  printing { print }
' "$root/CHANGELOG.md" | sed -e '/./,$!d'
