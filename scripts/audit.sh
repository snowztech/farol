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

lint="$(mktemp)"
swiftlint lint --quiet --reporter json > "$lint" || true

# Unused code needs every file's compile command, so it builds from scratch in a folder of its own.
log="$(mktemp)"
echo "Building from scratch to look for unused code. It takes a few minutes."
rm -rf .build/audit
if ! swift build -v --build-tests --build-path .build/audit > "$log" 2>&1; then
  tail -20 "$log"
  exit 1
fi
unused="$(mktemp)"
swiftlint analyze --quiet --reporter json --compiler-log-path "$log" > "$unused" || true

python3 "$root/scripts/audit-report.py" "$root" "$lint" "$unused"
