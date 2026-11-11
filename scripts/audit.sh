#!/usr/bin/env bash
# make audit: functions too long or too tangled, force unwraps. Seconds, since it only reads the code.
# make unused (scripts/audit.sh unused): code and imports nothing uses. Minutes, since it builds from scratch.
# Each prints a short report and writes the full list to build/audit.md or build/unused.md, ready to hand to an agent. Nothing is changed.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
if ! command -v swiftlint >/dev/null; then
  echo "This needs SwiftLint: brew install swiftlint"
  exit 1
fi
mkdir -p build
found="$(mktemp)"

if [ "${1:-}" = unused ]; then
  # Every file's compile command, tests included so code only they use counts as used. An incremental build would leave some out.
  log="$(mktemp)"
  echo "Building from scratch to find unused code. It takes a few minutes."
  rm -rf .build/audit
  if ! swift build -v --build-tests --build-path .build/audit > "$log" 2>&1; then
    tail -20 "$log"
    exit 1
  fi
  swiftlint analyze --quiet --reporter json --compiler-log-path "$log" > "$found" || true
  python3 scripts/audit-report.py "$root" build/unused.md "$found"
else
  swiftlint lint --quiet --reporter json > "$found" || true
  python3 scripts/audit-report.py "$root" build/audit.md "$found"
fi
