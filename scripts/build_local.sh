#!/bin/zsh
set -euo pipefail

# Builds the direct-distribution variant of MusicLy:
#   - ENABLE_OCR on (Vision OCR fallback included)
#   - ad-hoc code signed with MusicLy.entitlements
#
# Output:
#   .build/release/MusicLy   (raw binary)
#   dist/MusicLy.app         (app bundle)
#   dist/MusicLy.zip         (zipped bundle)

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/MusicLy.app"
BIN_PATH="$BUILD_DIR/release/MusicLy"
ENTITLEMENTS="$ROOT_DIR/MusicLy.entitlements"

mkdir -p "$DIST_DIR"

swift build -c release --package-path "$ROOT_DIR" -Xswiftc -DENABLE_OCR

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/MusicLy"
chmod +x "$APP_DIR/Contents/MacOS/MusicLy"

# Ad-hoc sign so the bundle has a stable structure. A real Developer ID
# certificate (codesign -s "Developer ID Application: NAME (TEAMID)") plus
# `xcrun notarytool` is required for distribution without Gatekeeper warnings.
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP_DIR" 2>/dev/null || \
  echo "warning: ad-hoc codesign failed (non-fatal)"

cd "$DIST_DIR"
rm -f MusicLy.zip
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "MusicLy.app" "MusicLy.zip"

echo "Built app: $APP_DIR"
echo "Built archive: $DIST_DIR/MusicLy.zip"
