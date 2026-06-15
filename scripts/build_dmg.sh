#!/bin/zsh
set -euo pipefail

# Builds dist/MusicLy.app (via build_local.sh) and packages a drag-to-install
# DMG using only hdiutil (no external dependencies).
#
# Output: dist/MusicLy-<version>.dmg

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/MusicLy.app"

"$ROOT_DIR/scripts/build_local.sh"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT_DIR/Info.plist" 2>/dev/null || echo '1.0')"
DMG_PATH="$DIST_DIR/MusicLy-$VERSION.dmg"
STAGING="$DIST_DIR/.dmg_staging"

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/MusicLy.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "MusicLy" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG_PATH"

rm -rf "$STAGING"

echo "Built DMG: $DMG_PATH"
