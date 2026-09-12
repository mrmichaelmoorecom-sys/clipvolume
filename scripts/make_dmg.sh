#!/usr/bin/env bash
# Build a drag-to-Applications .dmg for clipvolume using only native tools
# (hdiutil + AppleScript/Finder for the window layout).
#   scripts/make_dmg.sh [path/to/clipvolume.app] [out.dmg]
# Defaults: build/export/clipvolume.app (from `make app`) → build/clipvolume.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

APP_NAME="clipvolume"
APP="${1:-$ROOT/build/export/$APP_NAME.app}"
DMG_FINAL="${2:-$ROOT/build/$APP_NAME.dmg}"
VOL="clipvolume"
BG_SRC="$ROOT/Resources/dmg-background.tiff"

[[ -d "$APP" ]] || { echo "error: $APP not found — run 'make app' first" >&2; exit 1; }
[[ -f "$BG_SRC" ]] || { echo "error: $BG_SRC not found — run: swift scripts/make_dmg_bg.swift" >&2; exit 1; }

hdiutil detach "/Volumes/$VOL" >/dev/null 2>&1 || true

WORK="$(mktemp -d)"
STAGING="$WORK/stage"
TMP_DMG="$WORK/rw.dmg"
mkdir -p "$STAGING"

echo "==> staging contents"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
mkdir "$STAGING/.background"
cp "$BG_SRC" "$STAGING/.background/background.tiff"
[[ -f "$ROOT/dmg/Read Me.txt" ]] && cp "$ROOT/dmg/Read Me.txt" "$STAGING/Read Me.txt"

SIZE_MB=$(( $(du -sk "$STAGING" | cut -f1) / 1024 + 20 ))

echo "==> creating writable image (${SIZE_MB}m)"
hdiutil create -srcfolder "$STAGING" -volname "$VOL" -fs HFS+ \
    -format UDRW -size "${SIZE_MB}m" -ov "$TMP_DMG" >/dev/null

echo "==> mounting"
hdiutil attach "$TMP_DMG" -noautoopen -mountpoint "/Volumes/$VOL" >/dev/null
sleep 1

echo "==> arranging window (Finder)"
osascript <<APPLESCRIPT || echo "WARN: Finder layout step returned an error (above). Grant Automation→Finder if prompted, then re-run."
tell application "Finder"
  tell disk "$VOL"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {300, 180, 960, 608}
    set theOptions to the icon view options of container window
    set arrangement of theOptions to not arranged
    set icon size of theOptions to 128
    set text size of theOptions to 13
    set background picture of theOptions to file ".background:background.tiff"
    -- Position by name match: the .app extension is hidden, so exact-name lookups miss.
    repeat with anItem in (get items of container window)
      set nm to name of anItem
      if nm contains "$APP_NAME" then
        set position of anItem to {165, 200}
      else if nm is "Applications" then
        set position of anItem to {495, 200}
      else if nm contains "Read" then
        set position of anItem to {330, 560}
      else
        set position of anItem to {1600, 1600}
      end if
    end repeat
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
echo "==> detaching"
hdiutil detach "/Volumes/$VOL" >/dev/null || hdiutil detach "/Volumes/$VOL" -force >/dev/null

echo "==> compressing to read-only $DMG_FINAL"
mkdir -p "$(dirname "$DMG_FINAL")"
rm -f "$DMG_FINAL"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL" >/dev/null

rm -rf "$WORK"
echo "==> done: $DMG_FINAL ($(du -h "$DMG_FINAL" | cut -f1))"
