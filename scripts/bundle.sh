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
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app" >/dev/null
echo "built $app"
