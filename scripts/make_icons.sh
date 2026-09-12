#!/usr/bin/env bash
# Renders img/appicon.svg → app icon PNGs, Resources/AppIcon.icns and img/favicon.ico.
# Needs: rsvg-convert (brew install librsvg), ImageMagick (for the .ico), iconutil (Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."

SVG=img/appicon.svg
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"

for px in 16 32 64 128 256 512 1024; do
  rsvg-convert -w $px -h $px "$SVG" -o "$SET/icon_${px}.png"
done
# iconutil wants the @1x/@2x naming
mv "$SET/icon_16.png"   "$SET/icon_16x16.png"
cp "$SET/icon_32.png"   "$SET/icon_16x16@2x.png"
mv "$SET/icon_32.png"   "$SET/icon_32x32.png"
mv "$SET/icon_64.png"   "$SET/icon_32x32@2x.png"
mv "$SET/icon_128.png"  "$SET/icon_128x128.png"
cp "$SET/icon_256.png"  "$SET/icon_128x128@2x.png"
mv "$SET/icon_256.png"  "$SET/icon_256x256.png"
cp "$SET/icon_512.png"  "$SET/icon_256x256@2x.png"
mv "$SET/icon_512.png"  "$SET/icon_512x512.png"
mv "$SET/icon_1024.png" "$SET/icon_512x512@2x.png"
iconutil -c icns "$SET" -o Resources/AppIcon.icns

rsvg-convert -w 1024 -h 1024 "$SVG" -o img/appicon_1024.png
rsvg-convert -w 512  -h 512  "$SVG" -o img/appicon_512.png
rsvg-convert -w 256  -h 256  "$SVG" -o img/appicon_256.png
rsvg-convert -w 180  -h 180  "$SVG" -o img/apple-touch-icon.png

CONVERT=$(command -v magick || command -v convert || echo /opt/ImageMagick/bin/convert)
"$CONVERT" "$SET/icon_16x16.png" "$SET/icon_32x32.png" "$SET/icon_32x32@2x.png" "$SET/icon_128x128.png" img/favicon.ico
rm -rf "$(dirname "$SET")"
echo "icons: Resources/AppIcon.icns img/appicon_{1024,512,256}.png img/apple-touch-icon.png img/favicon.ico"
