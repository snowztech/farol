#!/usr/bin/env bash
# Builds GhosttyKit.xcframework from a pinned Ghostty commit into vendor/.
# ghostty.h is internal to Ghostty and can change, so bump GHOSTTY_REV on purpose.
set -euo pipefail

GHOSTTY_REV=b40acce58dcf77df52231c3798ea58e924647c89

root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/.ghostty-src"

if [ ! -d "$src/.git" ]; then
  git clone https://github.com/ghostty-org/ghostty.git "$src"
fi
git -C "$src" fetch --depth 1 origin "$GHOSTTY_REV"
git -C "$src" checkout -q "$GHOSTTY_REV"

(cd "$src" && zig build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native \
  -Di18n=false)

mkdir -p "$root/vendor"
rm -rf "$root/vendor/GhosttyKit.xcframework"
cp -R "$src/macos/GhosttyKit.xcframework" "$root/vendor/"
# Shell integration and the xterm-ghostty terminfo. The app bundle ships these.
rm -rf "$root/vendor/ghostty-resources"
mkdir -p "$root/vendor/ghostty-resources"
cp -R "$src/zig-out/share/terminfo" "$src/zig-out/share/ghostty" "$root/vendor/ghostty-resources/"
echo "built vendor/GhosttyKit.xcframework @ $GHOSTTY_REV"
