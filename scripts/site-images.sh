#!/usr/bin/env bash
# Makes the AVIF copies the site serves for each screenshot in site/features: one at full size, and one half as wide for phones.
# Run it after adding or retaking a shot.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
for png in "$root"/site/features/*.png "$root"/site/features/themes/*.png "$root"/site/screenshot-review.png; do
  base="${png%.png}"
  width=$(sips -g pixelWidth "$png" | awk '/pixelWidth/ { print $2 }')
  sips -s format avif "$png" --out "$base.avif" >/dev/null
  if [ "$width" -ge 2000 ]; then
    sips -s format avif --resampleWidth $((width / 2)) "$png" --out "$base-half.avif" >/dev/null
  fi
  echo "${base#"$root"/}: $(du -k "$png" | cut -f1)K png, $(du -k "$base.avif" | cut -f1)K avif"
done
