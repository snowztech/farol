#!/usr/bin/env bash
# Builds a signed, notarized build/Farol-<version>.dmg and .zip that open on any Mac without warnings.
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

dmg="$root/build/Farol-$version.dmg"

# Locally the key lives in a keychain profile. CI passes the key file instead.
notarize() {
  if [ -n "${NOTARY_KEY_PATH:-}" ]; then
    xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
  else
    xcrun notarytool submit "$1" --keychain-profile "$profile" --wait
  fi
}

# The drag-to-Applications window: the app next to a link to /Applications.
make_dmg() {
  local staging
  staging=$(mktemp -d)
  cp -R "$app" "$staging/"
  ln -s /Applications "$staging/Applications"
  rm -f "$dmg"
  hdiutil create -quiet -volname Farol -srcfolder "$staging" -ov -format UDZO "$dmg"
  rm -rf "$staging"
  codesign --force --timestamp --sign "$identity" "$dmg"
}

if [ "${NOTARIZE:-1}" = "0" ]; then
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
  make_dmg
  echo "built $zip and $dmg (signed, not notarized)"
  exit 0
fi

# The app first, so its ticket is stapled before it goes into the zip and the disk image.
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
notarize "$zip"
xcrun stapler staple "$app"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

make_dmg
notarize "$dmg"
xcrun stapler staple "$dmg"

spctl --assess --type execute --verbose "$app"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
echo "built $zip and $dmg (signed and notarized)"
