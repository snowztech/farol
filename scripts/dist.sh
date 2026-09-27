#!/usr/bin/env bash
# Builds a signed, notarized build/Farol-<version>.zip that opens on any Mac without warnings.
# Needs a Developer ID Application certificate and a notarytool profile named farol (see README).
# NOTARIZE=0 signs without notarizing, and CONFIG=debug signs the debug build.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
config="${CONFIG:-release}"
profile="${NOTARY_PROFILE:-farol}"
identity="${DEVELOPER_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
[ -n "$identity" ] || { echo "No Developer ID Application certificate in the keychain." >&2; exit 1; }

"$root/scripts/bundle.sh" "$config"
app="$root/build/Farol.app"
version=$(defaults read "$app/Contents/Info.plist" FarolVersion)
zip="$root/build/Farol-$version.zip"

# Inside out: the nested tool first, then the app that contains it.
sign() {
  codesign --force --timestamp --options runtime --entitlements "$root/assets/Farol.entitlements" --sign "$identity" "$1"
}
sign "$app/Contents/Resources/bin/farol"
sign "$app"
codesign --verify --strict --deep "$app"
echo "signed with $identity"

rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
if [ "${NOTARIZE:-1}" = "0" ]; then
  echo "built $zip (signed, not notarized)"
  exit 0
fi

xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
# Stapling attaches Apple's approval to the app, so it opens even offline. The zip is rebuilt to include it.
xcrun stapler staple "$app"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
spctl --assess --type execute --verbose "$app"
echo "built $zip (signed and notarized)"
