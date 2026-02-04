#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
UPDATE_DIR="$BUILD_DIR/updates"
ARCHIVE_PATH="$BUILD_DIR/Lodge.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/Lodge.app"
ZIP_PATH="$UPDATE_DIR/Lodge.app.zip"
DMG_PATH="$BUILD_DIR/Lodge.dmg"

NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEY="${NOTARY_KEY:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-}"

if [ -n "$NOTARY_PROFILE" ]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
else
  : "${NOTARY_KEY:?Set NOTARY_KEY (path to AuthKey.p8)}"
  : "${NOTARY_KEY_ID:?Set NOTARY_KEY_ID}"
  : "${NOTARY_ISSUER_ID:?Set NOTARY_ISSUER_ID}"
  NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi

rm -rf "$BUILD_DIR"
mkdir -p "$UPDATE_DIR"

xcodebuild -scheme Lodge -configuration Release -archivePath "$ARCHIVE_PATH" archive
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportOptionsPlist "$ROOT_DIR/scripts/export-options.plist" -exportPath "$EXPORT_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

xcrun notarytool submit "$ZIP_PATH" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$APP_PATH"

# Re-create ZIP so it contains the stapled app
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

hdiutil create -volname "Lodge" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$DMG_PATH"
