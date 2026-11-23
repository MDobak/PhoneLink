#!/bin/sh
# Packs build/Phone Link.app into build/PhoneLink.dmg, with a link to /Applications. Run ./build.sh first.
set -e
cd "$(dirname "$0")"
APP="build/Phone Link.app"
[ -d "$APP" ] || { echo "$APP not found, run ./build.sh first" >&2; exit 1; }
STAGE=build/dmg
rm -rf "$STAGE" build/PhoneLink.dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Phone Link" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov build/PhoneLink.dmg
rm -rf "$STAGE"
echo "Built build/PhoneLink.dmg"
