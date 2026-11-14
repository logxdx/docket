#!/usr/bin/env bash
# Render Docket's launcher icons from tool/icon/docket.svg: Android's pre-8.0 PNGs (8.0+ uses
# the adaptive vector in res/mipmap-anydpi-v26) and every iOS AppIcon size (opaque, as iOS wants).
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
svg="$here/tool/icon/docket.svg"
for pair in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  rsvg-convert -w "${pair#*:}" -h "${pair#*:}" "$svg" -o "$here/android/app/src/main/res/mipmap-${pair%%:*}/ic_launcher.png"
done
ios="$here/ios/Runner/Assets.xcassets/AppIcon.appiconset"
for f in "$ios"/Icon-App-*.png; do
  name=$(basename "$f" .png)                 # Icon-App-83.5x83.5@2x
  pts=${name#Icon-App-}; pts=${pts%%x*}      # 83.5
  scale=${name##*@}; scale=${scale%x}        # 2
  px=$(python3 -c "print(round($pts*$scale))")
  rsvg-convert -w "$px" -h "$px" -b '#FFFFFF' "$svg" -o "$f"
done
echo "rendered"
