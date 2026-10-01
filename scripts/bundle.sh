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
# Not in Contents/MacOS: that folder already holds "Farol", and macOS file names ignore case.
mkdir -p "$app/Contents/Resources/bin"
cp "$root/.build/$config/FarolCLI" "$app/Contents/Resources/bin/farol"
cp -R "$root/vendor/ghostty-resources/." "$app/Contents/Resources/"
# Next to Ghostty's themes, so Ghostty finds Farol's by name too.
cp "$root"/assets/themes/* "$app/Contents/Resources/ghostty/themes/"
cp "$root/assets/Farol.icns" "$app/Contents/Resources/"
mkdir -p "$app/Contents/Resources/icons"
cp "$root"/assets/icons/*.png "$app/Contents/Resources/icons/"

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
  <!-- Shown when a program in a session asks macOS for access. -->
  <key>NSAppleEventsUsageDescription</key><string>A program running in Farol would like to use AppleScript.</string>
  <key>NSCameraUsageDescription</key><string>A program running in Farol would like to use the camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>A program running in Farol would like to use your microphone.</string>
  <key>NSAudioCaptureUsageDescription</key><string>A program running in Farol would like to access your system's audio.</string>
  <key>NSContactsUsageDescription</key><string>A program running in Farol would like to access your Contacts.</string>
  <key>NSCalendarsUsageDescription</key><string>A program running in Farol would like to access your Calendar.</string>
  <key>NSRemindersUsageDescription</key><string>A program running in Farol would like to access your reminders.</string>
  <key>NSPhotoLibraryUsageDescription</key><string>A program running in Farol would like to access your Photo Library.</string>
  <key>NSLocationUsageDescription</key><string>A program running in Farol would like to access your location.</string>
  <key>NSLocalNetworkUsageDescription</key><string>A program running in Farol would like to access the local network.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>A program running in Farol would like to use Bluetooth.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$app" >/dev/null
echo "built $app ($version)"
