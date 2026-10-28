#!/bin/bash
# Packages build/ClaudeNotch.app into a drag-to-install DMG: dist/ClaudeNotch-<version>.dmg
# Optional notarization (needs an Apple Developer account):
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<keychain-profile> scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat VERSION)}"
export VERSION
./build.sh

STAGE=build/dmg
DMG=dist/ClaudeNotch-${VERSION}.dmg
rm -rf "$STAGE" && mkdir -p "$STAGE" dist
cp -R build/ClaudeNotch.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp scripts/LEGGIMI.txt "$STAGE/LEGGIMI.txt"

rm -f "$DMG"
hdiutil create -volname "Claude Notch" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp -s "$SIGN_IDENTITY" "$DMG"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

echo "Installer: $DMG"
