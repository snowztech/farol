#!/usr/bin/env bash
# Builds build/Farol.app.
# Ghostty only enables shell integration when it finds its resources inside the bundle.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
config="${1:-release}"
app="$root/build/Farol.app"
# Debug builds get their own identity, so testing them never touches the installed app's sessions.
if [ "$config" = "debug" ]; then
  bundle_id="dev.farol.Farol.debug"
  name="Farol Dev"
else
  bundle_id="dev.farol.Farol"
  name="Farol"
fi

# Version from the latest v* tag. Builds after a tag read like 0.1.0-3-gabc1234, and -dirty marks uncommitted changes.
described=$(git -C "$root" describe --tags --match 'v[0-9]*' --dirty 2>/dev/null || echo "v0.0.0-dev")
version="${described#v}"
# macOS wants plain numbers in the short version, so the full string gets its own key.
short_version="${version%%-*}"
build_number=$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 0)

swift build --package-path "$root" -c "$config"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/$config/Farol" "$app/Contents/MacOS/Farol"
cp -R "$root/vendor/ghostty-resources/." "$app/Contents/Resources/"
cp "$root/assets/Farol.icns" "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>Farol</string>
  <key>CFBundleIconFile</key><string>Farol</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$short_version</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>FarolVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app" >/dev/null
echo "built $app ($version)"
