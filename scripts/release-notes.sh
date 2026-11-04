set -euo pipefail
# Prints one version's section of CHANGELOG.md for the GitHub release (release-notes.sh 0.1.1).
# With "recent", the versions from the 30 days up to it as well, for the update dialog (release-notes.sh 0.1.1 recent).
# People skip releases by time away, not by count, and a cap of 15 keeps a busy month readable.
root="$(cd "$(dirname "$0")/.." && pwd)"
changelog="$root/CHANGELOG.md"
version="$1"
count=1 since=""
if [ "${2:-}" = recent ]; then
  released=$(grep -m1 -F "## [$version] - " "$changelog" | sed 's/.* - //')
  since=$(date -j -v-30d -f %F "$released" +%F)
  count=15
fi
awk -v version="$version" -v count="$count" -v since="$since" '
  /^## \[/ {
    if (!started && index($0, "## [" version "]") == 1) started = 1
    split($0, parts, /[][]/)
    date = $NF
    printing = started && shown < count && (since == "" || shown == 0 || date >= since)
    if (printing) shown++
    if (printing && count > 1) print "## " parts[2]
    next
  }
  /^\[.*\]: / { next }
  printing { print }
' "$changelog" | sed -e '/./,$!d'
