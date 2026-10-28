#!/bin/bash
# Builds a universal (Apple Silicon + Intel) ClaudeNotch.app into ./build.
#   ./build.sh          build only
#   ./build.sh --run    build and (re)launch
# Optional: SIGN_IDENTITY="Developer ID Application: ..." to sign for distribution.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-$(cat VERSION)}"
APP=build/ClaudeNotch.app

# One build per architecture (plain SwiftPM), merged with lipo. The multi-arch
# `--arch a --arch b` path goes through xcbuild, which breaks on some Xcode versions.
SLICES=()
for ARCH in arm64 x86_64; do
  swift build -c release --arch "$ARCH" --scratch-path ".build/$ARCH"
  SLICES+=(".build/$ARCH/release/ClaudeNotch")
done
mkdir -p build
BIN=build/ClaudeNotch-universal
lipo -create -output "$BIN" "${SLICES[@]}"

# App icon (generated once, cached in Resources/).
if [[ ! -f Resources/AppIcon.icns ]]; then
  mkdir -p Resources build/icon.iconset
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/icon.iconset -o Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeNotch"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClaudeNotch</string>
  <key>CFBundleDisplayName</key><string>Claude Notch</string>
  <key>CFBundleIdentifier</key><string>it.casarella.claudenotch</string>
  <key>CFBundleExecutable</key><string>ClaudeNotch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$APP"
else
  codesign --force -s - "$APP" >/dev/null   # ad-hoc
fi
echo "Built $APP ($VERSION)"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x ClaudeNotch 2>/dev/null || true
  open "$APP"
fi
