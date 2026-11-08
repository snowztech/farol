#!/usr/bin/env bash
# Records Farol Dev with Instruments while you use it, then opens the recording: where the CPU went, and what froze the window.
# Use Farol as you normally would while it records. PROFILE_SECONDS=60 records longer.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
seconds="${PROFILE_SECONDS:-30}"
app="$root/build/Farol.app"

# A second Farol Dev would fight the first for its socket and its sessions.
if pgrep -f "$app/Contents/MacOS/Farol" >/dev/null; then
  echo "Quit Farol Dev first, then run make profile again."
  exit 1
fi

"$root/scripts/bundle.sh" profile
mkdir -p "$root/build/traces"
trace="$root/build/traces/$(date +%Y-%m-%d-%H%M%S).trace"
echo "Recording for ${seconds}s. Use Farol Dev as you normally would."
# Points of Interest holds the git and other runs Perf marks, next to where the CPU went and every hang.
xcrun xctrace record --template "Time Profiler" --instrument "Hangs" --instrument "Points of Interest" \
  --time-limit "${seconds}s" --output "$trace" --launch -- "$app/Contents/MacOS/Farol"
open "$trace"
