#!/usr/bin/env bash
# Builds "PDF Compressor Ultra.app" (Apple Silicon) into dist/.
#   ./Scripts/build_app.sh            — with JPEGli (needs cmake: brew install cmake)
#   SKIP_JPEGLI=1 ./Scripts/build_app.sh — system JPEG encoder only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-1.0.0}"
ARCH="${ARCH:-arm64}"
APP_NAME="PDF Compressor Ultra"
APP="dist/$APP_NAME.app"

if [[ "${SKIP_JPEGLI:-0}" != "1" ]]; then
  if command -v cmake >/dev/null; then
    ./Scripts/build_jpegli.sh
  else
    echo "⚠️  cmake не найден — JPEGli не будет встроен (brew install cmake)" >&2
  fi
fi

swift build -c release --arch "$ARCH" --product PDFCompressorUltra
swift build -c release --arch "$ARCH" --product pdfcu
BIN="$(swift build -c release --arch "$ARCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PDFCompressorUltra" "$APP/Contents/MacOS/PDFCompressorUltra"
cp "$BIN/pdfcu" "$APP/Contents/MacOS/pdfcu"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>app.pdfcompressorultra</string>
  <key>CFBundleExecutable</key><string>PDFCompressorUltra</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PDF Document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
cp "$BIN/pdfcu" dist/pdfcu
(cd dist && ditto -c -k --keepParent "$APP_NAME.app" "PDF-Compressor-Ultra-$VERSION-arm64.zip")
# DMG with a drag-to-Applications layout
DMG="dist/PDF-Compressor-Ultra-$VERSION-arm64.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "✅ Готово: $ROOT/$APP"
echo "💿 DMG:    $ROOT/$DMG"
