#!/usr/bin/env bash
# Makes the AVIF copies the site serves for each screenshot in site/features: one at full size, and one half as wide for phones.
# Run it after adding or retaking a shot.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
even="$(mktemp -d)/even.png"
for png in "$root"/site/features/*.png "$root"/site/screenshot-review.png; do
  base="${png%.png}"
  width=$(sips -g pixelWidth "$png" | awk '/pixelWidth/ { print $2 }')
  height=$(sips -g pixelHeight "$png" | awk '/pixelHeight/ { print $2 }')
  # sips writes a blank AVIF when a side is odd, so an odd side loses its last pixel first.
  sips -c $((height / 2 * 2)) $((width / 2 * 2)) --cropOffset 0 0 "$png" --out "$even" >/dev/null
  sips -s format avif "$even" --out "$base.avif" >/dev/null
  if [ "$width" -ge 2000 ]; then
    sips -s format avif -z $((height / 4 * 2)) $((width / 4 * 2)) "$even" --out "$base-half.avif" >/dev/null
  fi
  echo "${base#"$root"/}: $(du -k "$png" | cut -f1)K png, $(du -k "$base.avif" | cut -f1)K avif"
done
