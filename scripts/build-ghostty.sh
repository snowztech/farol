#!/usr/bin/env bash
# Puts GhosttyKit.xcframework for a pinned Ghostty commit into vendor/, prebuilt when possible.
# ghostty.h is internal to Ghostty and can change, so bump GHOSTTY_REV on purpose.
set -euo pipefail

GHOSTTY_REV=b40acce58dcf77df52231c3798ea58e924647c89

root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/.ghostty-src"

# A prebuilt copy lives on the ghostty-<rev> release. FROM_SOURCE=1 skips it.
prebuilt="https://github.com/snowztech/farol/releases/download/ghostty-${GHOSTTY_REV:0:7}/GhosttyKit.zip"
if [ -z "${FROM_SOURCE:-}" ] && curl -fsSL "$prebuilt" -o "$root/.ghostty.zip"; then
  rm -rf "$root/vendor" && mkdir -p "$root/vendor"
  unzip -q "$root/.ghostty.zip" -d "$root/vendor" && rm "$root/.ghostty.zip"
  echo "downloaded vendor/GhosttyKit.xcframework @ $GHOSTTY_REV"
  exit 0
fi
rm -f "$root/.ghostty.zip"
if [ -n "${CI:-}" ] && [ -z "${FROM_SOURCE:-}" ]; then
  echo "no prebuilt libghostty for $GHOSTTY_REV. Run the libghostty workflow first." >&2
  exit 1
fi

# Publishing is once per Ghostty commit, so there is nothing to build if it is already out.
if [ "${1:-}" = "--publish" ] && gh release view "ghostty-${GHOSTTY_REV:0:7}" > /dev/null 2>&1; then
  echo "ghostty-${GHOSTTY_REV:0:7} is already published"
  exit 0
fi

if [ ! -d "$src/.git" ]; then
  git clone https://github.com/ghostty-org/ghostty.git "$src"
fi
git -C "$src" fetch --depth 1 origin "$GHOSTTY_REV"
git -C "$src" checkout -q "$GHOSTTY_REV"
# Fresh CI machines lack it. Locally it is a one time step from the README.
if [ -n "${CI:-}" ]; then xcodebuild -downloadComponent MetalToolchain; fi

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

# Publishes the build for everyone else, once per Ghostty commit.
if [ "${1:-}" = "--publish" ]; then
  tag="ghostty-${GHOSTTY_REV:0:7}"
  mkdir -p "$root/build"
  (cd "$root/vendor" && zip -qry "$root/build/GhosttyKit.zip" GhosttyKit.xcframework ghostty-resources)
  gh release create "$tag" "$root/build/GhosttyKit.zip" --prerelease --target "$(git -C "$root" rev-parse HEAD)" \
    --title "libghostty ${GHOSTTY_REV:0:7}" --notes "Prebuilt libghostty for Farol, built from ghostty-org/ghostty@$GHOSTTY_REV."
fi
