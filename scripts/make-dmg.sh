#!/bin/bash
# Builds a styled DMG: scripts/make-dmg.sh <folder with app + Applications link> <out.dmg> [volname]
# Window 660x400, background release/dmg/background(.@2x).png, icon centers (160,214) and (510,214)
# (installationsfenster-final.json). Layout is best effort: if Finder scripting is unavailable
# (headless CI, no GUI session) the DMG is still produced, just unstyled.
set -u
SRC="$1"; OUT="$2"; VOL="${3:-Sequence Studio}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; RW="$TMP/rw.dmg"
trap 'hdiutil detach "/Volumes/$VOL" -quiet -force >/dev/null 2>&1; rm -rf "$TMP"' EXIT

plain() { hdiutil create -quiet -volname "$VOL" -srcfolder "$SRC" -ov -format UDZO "$OUT"; }

SIZE_MB=$(( $(du -sm "$SRC" | cut -f1) + 20 ))
# Never reuse a stale mount of the same name.
hdiutil detach "/Volumes/$VOL" -quiet -force >/dev/null 2>&1
hdiutil create -quiet -volname "$VOL" -srcfolder "$SRC" -ov -format UDRW -size "${SIZE_MB}m" "$RW" || exit 1
hdiutil attach -quiet -readwrite -noverify -noautoopen -mountpoint "/Volumes/$VOL" "$RW" >/dev/null || { plain; exit $?; }

mkdir -p "/Volumes/$VOL/.background"
tiffutil -cathidpicheck "$ROOT/release/dmg/background.png" "$ROOT/release/dmg/background@2x.png" \
  -out "/Volumes/$VOL/.background/background.tiff" 2>/dev/null \
  || cp "$ROOT/release/dmg/background.png" "/Volumes/$VOL/.background/background.tiff"

if ! osascript <<EOF >/dev/null 2>&1
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 120
    set text size of opts to 12
    set background picture of opts to file ".background:background.tiff"
    set position of item "Sequence Studio.app" of container window to {160, 214}
    set position of item "Applications" of container window to {510, 214}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
then
  echo "WARN: Finder layout failed; DMG has no custom background" >&2
fi
sync; sleep 1
hdiutil detach "/Volumes/$VOL" -quiet || hdiutil detach "/Volumes/$VOL" -quiet -force
rm -f "$OUT"
hdiutil convert -quiet "$RW" -format UDZO -o "$OUT" || exit 1
