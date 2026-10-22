#!/bin/bash
# Builds a drag-to-install disk image with a laid-out Finder window.
# Usage: tools/make-dmg.sh <app bundle> <icon.icns> <output.dmg> <signing identity>
set -euo pipefail

app=$1 icns=$2 out=$3 identity=$4
volname="Android USB Tools"
work=$(mktemp -d)
trap 'hdiutil detach -quiet "$work/mnt" 2>/dev/null || true; rm -rf "$work"' EXIT

# Background at 1x and 2x, combined so Finder picks the right one on Retina.
here=$(cd "$(dirname "$0")" && pwd)
swift "$here/make-dmg-background.swift" 1 "$work/bg.png"
swift "$here/make-dmg-background.swift" 2 "$work/bg@2x.png"

mkdir -p "$work/src/.background"
cp -R "$app" "$work/src/"
ln -s /Applications "$work/src/Applications"
tiffutil -cathidpicheck "$work/bg.png" "$work/bg@2x.png" -out "$work/src/.background/background.tiff" 2>/dev/null
cp "$icns" "$work/src/.VolumeIcon.icns"

if [ -d "/Volumes/$volname" ]; then
    echo "error: a volume named $volname is already mounted; eject it first" >&2
    exit 1
fi

hdiutil create -quiet -volname "$volname" -srcfolder "$work/src" -fs HFS+ -format UDRW -ov "$work/rw.dmg"
mkdir "$work/mnt"
hdiutil attach -quiet -readwrite -noverify -noautoopen -mountpoint "/Volumes/$volname" "$work/rw.dmg"
SetFile -a C "/Volumes/$volname"  # use .VolumeIcon.icns

# Finder stores the window layout in the volume's .DS_Store.
osascript <<EOF
tell application "Finder"
    tell disk "$volname"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 548}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "$(basename "$app")" of container window to {160, 180}
        set position of item "Applications" of container window to {440, 180}
        close
        open
        delay 1
        close
    end tell
end tell
EOF

sync
hdiutil detach -quiet "/Volumes/$volname"
rm -f "$out"
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$out"
codesign --force --timestamp=none --sign "$identity" "$out"
