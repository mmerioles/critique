#!/bin/bash
# Packages build/Critique.app into build/Critique.dmg with an Applications
# shortcut, so installing is: open the DMG, drag Critique into Applications.
set -euo pipefail
APP=build/Critique.app
DMG=build/Critique.dmg
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname Critique -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
echo "Built $DMG"
