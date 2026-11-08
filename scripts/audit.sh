#!/usr/bin/env bash
# Lists code that smells: functions too long or too tangled, force unwraps, and code or imports nothing uses. It changes nothing.
# Run it when the code has grown. The limits are in .swiftlint.yml.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
if ! command -v swiftlint >/dev/null; then
  echo "make audit needs SwiftLint: brew install swiftlint"
  exit 1
fi

report="$(mktemp)"
swiftlint lint --quiet > "$report" || true

# Unused code needs every file's compile command, so it builds from scratch in a folder of its own.
log="$(mktemp)"
echo "Building from scratch to look for unused code. It takes a few minutes."
rm -rf .build/audit
if ! swift build -v --build-path .build/audit > "$log" 2>&1; then
  tail -20 "$log"
  exit 1
fi
swiftlint analyze --quiet --compiler-log-path "$log" >> "$report" || true

sed "s|$root/||" "$report"
echo
echo "By rule:"
grep -oE '\(([a-z_]+)\)$' "$report" | tr -d '()' | sort | uniq -c | sort -rn || echo "  nothing found"
