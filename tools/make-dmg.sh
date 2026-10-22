#!/bin/bash
# Builds a plain disk image: the app next to a link to /Applications.
# Usage: tools/make-dmg.sh <app bundle> <icon.icns> <output.dmg> <signing identity>
set -euo pipefail

app=$1 icns=$2 out=$3 identity=$4
volname="Android USB Tools"
work=$(mktemp -d)
trap 'hdiutil detach -quiet "$work/mnt" 2>/dev/null || true; rm -rf "$work"' EXIT

mkdir "$work/src"
cp -R "$app" "$work/src/"
ln -s /Applications "$work/src/Applications"
cp "$icns" "$work/src/.VolumeIcon.icns"

# The volume icon needs the custom-icon flag set on the mounted volume.
hdiutil create -quiet -volname "$volname" -srcfolder "$work/src" -fs HFS+ -format UDRW -ov "$work/rw.dmg"
mkdir "$work/mnt"
hdiutil attach -quiet -readwrite -noverify -noautoopen -nobrowse -mountpoint "$work/mnt" "$work/rw.dmg"
SetFile -a C "$work/mnt"
hdiutil detach -quiet "$work/mnt"

rm -f "$out"
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$out"
codesign --force --timestamp=none --sign "$identity" "$out"
