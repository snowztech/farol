set -euo pipefail

# Prints the update feed Sparkle reads for the release `version`, with its zip signed by the key in SPARKLE_KEY_FILE.
# Usage: SPARKLE_KEY_FILE=key scripts/appcast.sh 0.43.0 build/Farol-0.43.0.zip > build/appcast.xml

root="$(cd "$(dirname "$0")/.." && pwd)"
version="$1"
zip="$2"

# The same version as the framework in Package.resolved, checked against its known checksum before it touches the key.
sparkle=2.10.0
checksum=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
tools="$root/.build/sparkle-$sparkle"
if [ ! -x "$tools/bin/sign_update" ]; then
  mkdir -p "$tools"
  curl -fsSL -o "$tools/sparkle.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle/Sparkle-$sparkle.tar.xz"
  echo "$checksum  $tools/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null
  tar -xJf "$tools/sparkle.tar.xz" -C "$tools"
fi

# Like: sparkle:edSignature="…" length="12345"
signature=$("$tools/bin/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$zip")
build=$(defaults read "$root/build/Farol.app/Contents/Info.plist" CFBundleVersion)
date=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Farol</title>
    <item>
      <title>Farol $version</title>
      <pubDate>$date</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/snowztech/farol/releases/download/v$version/Farol.zip" type="application/octet-stream" $signature/>
    </item>
  </channel>
</rss>
XML
